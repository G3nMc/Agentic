"""OpenRouter backend via the OpenAI-compatible REST API (stdlib only)."""
from __future__ import annotations

# import json
# import sys
# from typing import Any, Dict, List

from .backend_base import ModelBackend
from ..utils.text import sanitize_for_agent


class OpenRouterBackend(ModelBackend):
    """
    OpenRouter backend via the OpenAI-compatible REST API.

    OpenRouter routes requests to dozens of providers (OpenAI, Anthropic,
    Google, Meta, Mistral, …) using a single unified API endpoint. The model
    ID follows the provider/name convention, e.g. 'openai/gpt-4o',
    'anthropic/claude-3.5-sonnet', 'meta-llama/llama-3.1-70b-instruct'.

    No extra pip dependency — the implementation uses only stdlib urllib so
    it works out of the box on any Python 3.8+ installation.

    API docs:  https://openrouter.ai/docs
    Key:       https://openrouter.ai/keys
    """

    DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"

    def __init__(self, api_key: str, model_id: str,
                 base_url: str = DEFAULT_BASE_URL):
        if not api_key:
            raise RuntimeError(
                "OpenRouter backend requires --openrouter-api-key. "
                "Get one free at https://openrouter.ai/keys."
            )
        if not model_id:
            raise RuntimeError(
                "OpenRouter backend requires --model "
                "(e.g. 'openai/gpt-4o' or 'meta-llama/llama-3.1-70b-instruct')."
            )
        self.api_key = api_key
        self.model_id = model_id
        self.base_url = base_url.rstrip("/")

    def chat(self, messages, max_tokens, temperature, tools=None):
        import urllib.request as _req
        import urllib.error as _err
        import json
        import sys
        from typing import Dict, Any, List

        # 🔥 CRITICAL FIX: sanitize EVERYTHING before JSON encoding
        messages = sanitize_for_agent(messages)
        tools = sanitize_for_agent(tools)

        payload: Dict[str, Any] = {
            "model": self.model_id,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": temperature,
        }

        if tools:
            payload["tools"] = tools

        # SAFE JSON ENCODING (prevents surrogate crash)
        raw = json.dumps(
            payload,
            ensure_ascii=False,
            allow_nan=False
        ).encode("utf-8", errors="ignore")

        request = _req.Request(
            f"{self.base_url}/chat/completions",
            data=raw,
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "HTTP-Referer": "https://github.com/chat-flutter",
                "X-Title": "Chat Flutter Orchestrator",
            },
            method="POST",
        )

        print(
            f"[orch] OpenRouter request '{self.model_id}' "
            f"({len(messages)} msgs, tools={bool(tools)})...",
            file=sys.stderr,
            flush=True,
        )

        try:
            with _req.urlopen(request, timeout=120) as resp:
                body = resp.read().decode("utf-8", errors="replace")

        except _err.HTTPError as e:
            body_err = e.read().decode("utf-8", errors="replace")
            raise RuntimeError(
                f"OpenRouter HTTP {e.code}: {body_err[:400]}"
            ) from e

        except Exception as e:
            raise RuntimeError(f"OpenRouter error: {e}") from e

        try:
            data = json.loads(body)
        except json.JSONDecodeError as exc:
            raise RuntimeError(
                f"OpenRouter: invalid JSON response: {body[:200]}"
            ) from exc

        choices = data.get("choices") or []
        if not choices:
            error = data.get("error") or {}
            msg = error.get("message") or str(data)
            raise RuntimeError(
                f"OpenRouter returned no choices: {msg[:400]}"
            )

        choice = choices[0]
        message = choice.get("message") or {}
        finish_reason = choice.get("finish_reason") or ""

        tool_calls = message.get("tool_calls") or []
        if tool_calls:
            tag_lines: List[str] = []

            for tc in tool_calls:
                fn = tc.get("function") or {}
                name = fn.get("name")
                args = fn.get("arguments") or "{}"

                if isinstance(args, str):
                    try:
                        args = json.loads(args)
                    except json.JSONDecodeError:
                        args = {}

                if not name:
                    continue

                tag_lines.append(
                    f'<tool>{json.dumps({"tool": name, "parameters": args})}</tool>'
                )

                print(
                    f"[orch] OpenRouter native tool_call -> {name}({args})",
                    file=sys.stderr,
                    flush=True,
                )

            if tag_lines:
                return "\n".join(tag_lines), finish_reason

        content = message.get("content") or ""
        return content.strip(), finish_reason
    # def chat(self, messages, max_tokens, temperature, tools=None):
    #     import urllib.request as _req
    #     import urllib.error as _err
    #
    #     payload: Dict[str, Any] = {
    #         "model": self.model_id,
    #         "messages": messages,
    #         "max_tokens": max_tokens,
    #         "temperature": temperature,
    #     }
    #     # OpenRouter supports native tool calling (OpenAI function-calling format).
    #     if tools:
    #         payload["tools"] = tools
    #
    #     raw = json.dumps(payload).encode("utf-8")
    #     request = _req.Request(
    #         f"{self.base_url}/chat/completions",
    #         data=raw,
    #         headers={
    #             "Authorization": f"Bearer {self.api_key}",
    #             "Content-Type": "application/json",
    #             # Recommended by OpenRouter for usage tracking / leaderboard.
    #             "HTTP-Referer": "https://github.com/chat-flutter",
    #             "X-Title": "Chat Flutter Orchestrator",
    #         },
    #         method="POST",
    #     )
    #
    #     print(
    #         f"[orch] OpenRouter request '{self.model_id}' "
    #         f"({len(messages)} msgs, tools={bool(tools)})...",
    #         file=sys.stderr,
    #         flush=True,
    #     )
    #
    #     try:
    #         with _req.urlopen(request, timeout=120) as resp:
    #             body = resp.read().decode("utf-8")
    #     except _err.HTTPError as e:
    #         body_err = e.read().decode("utf-8", errors="replace")
    #         raise RuntimeError(
    #             f"OpenRouter HTTP {e.code}: {body_err[:400]}"
    #         ) from e
    #     except Exception as e:
    #         raise RuntimeError(f"OpenRouter error: {e}") from e
    #
    #     try:
    #         data = json.loads(body)
    #     except json.JSONDecodeError as exc:
    #         raise RuntimeError(
    #             f"OpenRouter: invalid JSON response: {body[:200]}"
    #         ) from exc
    #
    #     choices = data.get("choices") or []
    #     if not choices:
    #         # Surface OpenRouter-level error messages (quota, bad model, etc.)
    #         error = data.get("error") or {}
    #         msg = error.get("message") or str(data)
    #         raise RuntimeError(f"OpenRouter returned no choices: {msg[:400]}")
    #
    #     choice = choices[0]
    #     message = choice.get("message") or {}
    #     finish_reason = choice.get("finish_reason") or ""
    #
    #     # Native tool calls (OpenAI function-calling format) -> <tool> tags.
    #     tool_calls = message.get("tool_calls") or []
    #     if tool_calls:
    #         tag_lines: List[str] = []
    #         for tc in tool_calls:
    #             fn = tc.get("function") or {}
    #             name = fn.get("name")
    #             args = fn.get("arguments") or "{}"
    #             if isinstance(args, str):
    #                 try:
    #                     args = json.loads(args)
    #                 except json.JSONDecodeError:
    #                     args = {}
    #             if not name:
    #                 continue
    #             tag_lines.append(
    #                 f'<tool>{json.dumps({"tool": name, "parameters": args})}</tool>'
    #             )
    #             print(
    #                 f"[orch] OpenRouter native tool_call -> {name}({args})",
    #                 file=sys.stderr,
    #                 flush=True,
    #             )
    #         if tag_lines:
    #             return "\n".join(tag_lines), finish_reason
    #
    #     content = message.get("content") or ""
    #     return content.strip(), finish_reason
