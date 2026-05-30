"""OpenRouter backend — inherits from OpenAICompatBackend."""

from __future__ import annotations

import sys
from typing import Any, Dict, List, Optional, Tuple

from .openai_compat import OpenAICompatBackend, RateLimitError, ToolsNotSupportedError


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


class OpenRouterBackend(OpenAICompatBackend):
    """
    OpenRouter via the OpenAI-compatible REST API (stdlib urllib, no extra dep).

    Routes to dozens of providers using a single endpoint.
    Model IDs: ``openai/gpt-4o``, ``anthropic/claude-3.5-sonnet``, etc.
    Key: https://openrouter.ai/keys
    """

    DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"

    def __init__(
        self,
        api_key: str,
        model_id: str,
        base_url: str = DEFAULT_BASE_URL,
    ):
        super().__init__(api_key, model_id, base_url=base_url, label="OpenRouter")

    def _do_request(
        self,
        payload: Dict[str, Any],
        effective_tools: Optional[List[Dict[str, Any]]],
    ) -> Tuple[str, str, List[Any], int]:
        import json
        import urllib.error as _err
        import urllib.request as _req

        n_tools = len(effective_tools) if effective_tools else 0
        url = f"{self.base_url}/chat/completions"
        _log(
            f"[OpenRouter:request] POST {url} "
            f"model={payload['model']} msgs={len(payload['messages'])} "
            f"tools={n_tools} max_tokens={payload.get('max_tokens')} "
            f"temperature={payload.get('temperature')}"
        )

        raw = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode(
            "utf-8", errors="ignore"
        )
        request = _req.Request(
            url,
            data=raw,
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "HTTP-Referer": "https://github.com/chat-flutter",
                "X-Title": "Chat Flutter Orchestrator",
            },
            method="POST",
        )

        try:
            with _req.urlopen(request, timeout=120) as resp:
                body = resp.read().decode("utf-8", errors="replace")
            _log(f"[OpenRouter:http_ok] response_len={len(body)}")
        except _err.HTTPError as exc:
            body_err = ""
            try:
                body_err = exc.read().decode("utf-8", errors="replace")
            except Exception:
                pass
            _log(f"[OpenRouter:http_error] status={exc.code} body={body_err[:400]!r}")
            if exc.code == 429:
                ra = exc.headers.get("Retry-After", "")
                retry_after = float(ra) if ra.strip().isdigit() else 0.0
                _log(f"[OpenRouter:rate_limit] retry_after={retry_after:.0f}s")
                raise RateLimitError(
                    f"OpenRouter 429",
                    retry_after=retry_after,
                ) from exc
            if exc.code == 400 and effective_tools and "tool" in body_err.lower():
                _log(f"[OpenRouter:tools_unsupported] raising ToolsNotSupportedError")
                raise ToolsNotSupportedError(body_err) from exc
            raise RuntimeError(f"OpenRouter HTTP {exc.code}: {body_err[:400]}") from exc
        except Exception as exc:
            _log(f"[OpenRouter:error] {type(exc).__name__}: {exc}")
            raise RuntimeError(f"OpenRouter error: {exc}") from exc

        try:
            data = json.loads(body)
        except json.JSONDecodeError as exc:
            _log(f"[OpenRouter:json_error] failed to parse response: {body[:200]!r}")
            raise RuntimeError(
                f"OpenRouter: invalid JSON response: {body[:200]}"
            ) from exc

        choices = data.get("choices") or []
        if not choices:
            error = data.get("error") or {}
            err_msg = error.get("message") or str(data)[:400]
            _log(f"[OpenRouter:no_choices] error={err_msg!r}")
            raise RuntimeError(f"OpenRouter returned no choices: {err_msg}")

        choice = choices[0]
        message = choice.get("message") or {}
        finish_reason = choice.get("finish_reason") or ""
        tool_calls = message.get("tool_calls") or []
        content = message.get("content") or ""
        usage = int((data.get("usage") or {}).get("total_tokens") or 0)

        _log(
            f"[OpenRouter:parsed] finish_reason={finish_reason!r} "
            f"content_len={len(content)} tool_calls={len(tool_calls)} "
            f"usage_tokens={usage}"
        )
        return content, finish_reason, tool_calls, usage
