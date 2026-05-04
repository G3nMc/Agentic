"""GitHub Models backend via the OpenAI-compatible REST API (stdlib only)."""
from __future__ import annotations

from typing import Any, Dict, List

from .backend_base import ModelBackend
from ..utils.text import sanitize_for_agent


class GitHubModelsBackend(ModelBackend):
    """
    GitHub Models backend via the OpenAI-compatible REST API.

    Endpoint: POST https://models.github.ai/inference/chat/completions
    Catalog:  GET  https://models.github.ai/catalog/models
    Auth:     fine-grained PAT with `models:read` scope.

    Model IDs follow the publisher/name convention, e.g. 'openai/gpt-4o',
    'meta/Llama-3.3-70B-Instruct', 'mistral-ai/Mistral-Large-2411'.

    No extra pip dependency — uses only stdlib urllib.

    Docs: https://docs.github.com/en/rest/models/inference?apiVersion=2026-03-10
    PAT:  https://github.com/settings/personal-access-tokens/new
    """

    DEFAULT_BASE_URL = "https://models.github.ai"
    API_VERSION = "2026-03-10"

    def __init__(self, api_key: str, model_id: str,
                 base_url: str = DEFAULT_BASE_URL):
        if not api_key:
            raise RuntimeError(
                "GitHub Models backend requires --github-api-key. "
                "Create a fine-grained PAT with `models:read` scope at "
                "https://github.com/settings/personal-access-tokens/new."
            )
        if not model_id:
            raise RuntimeError(
                "GitHub Models backend requires --model "
                "(e.g. 'openai/gpt-4o-mini' or 'meta/Llama-3.3-70B-Instruct')."
            )
        self.api_key = api_key
        self.model_id = model_id
        self.base_url = base_url.rstrip("/")

    def chat(self, messages, max_tokens, temperature, tools=None):
        import urllib.request as _req
        import urllib.error as _err
        import json
        import sys
        import threading
        import time

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

        raw = json.dumps(
            payload,
            ensure_ascii=False,
            allow_nan=False
        ).encode("utf-8", errors="ignore")

        request = _req.Request(
            f"{self.base_url}/inference/chat/completions",
            data=raw,
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": self.API_VERSION,
            },
            method="POST",
        )

        print(
            f"[orch] GitHub Models request '{self.model_id}' "
            f"({len(messages)} msgs, tools={bool(tools)})...",
            file=sys.stderr,
            flush=True,
        )

        max_attempts = 4
        body = ""
        request_timeout = 600

        for attempt in range(max_attempts):
            heartbeat_stop = threading.Event()

            def _heartbeat():
                ticks = 0
                while not heartbeat_stop.wait(20):
                    ticks += 1
                    print(
                        f"[orch] GitHub Models waiting "
                        f"({ticks * 20}s elapsed, model={self.model_id})...",
                        file=sys.stderr,
                        flush=True,
                    )

            hb = threading.Thread(target=_heartbeat, daemon=True)
            hb.start()

            try:
                with _req.urlopen(request, timeout=request_timeout) as resp:
                    body = resp.read().decode("utf-8", errors="replace")

                heartbeat_stop.set()
                break

            except _err.HTTPError as e:
                heartbeat_stop.set()

                if e.code == 429 and attempt < max_attempts - 1:
                    retry_after = e.headers.get("Retry-After")

                    if retry_after and retry_after.strip().isdigit():
                        wait_s = float(retry_after)
                    else:
                        wait_s = 5.0 * (2 ** attempt) + 5.0

                    print(
                        f"[orch] GitHub Models 429 — sleeping {wait_s:.0f}s...",
                        file=sys.stderr,
                        flush=True,
                    )

                    time.sleep(wait_s)
                    continue

                body_err = e.read().decode("utf-8", errors="replace")

                raise RuntimeError(
                    f"GitHub Models HTTP {e.code}: {body_err[:400]}"
                ) from e

            except Exception as e:
                heartbeat_stop.set()

                hint = ""
                if "timed out" in str(e).lower():
                    hint = (
                        f" — request exceeded {request_timeout}s."
                        " Try lower tokens or a faster model."
                    )

                raise RuntimeError(
                    f"GitHub Models error: {e}{hint}"
                ) from e

        try:
            data = json.loads(body)
        except json.JSONDecodeError as exc:
            raise RuntimeError(
                f"GitHub Models: invalid JSON response: {body[:200]}"
            ) from exc

        choices = data.get("choices") or []
        if not choices:
            error = data.get("error") or {}
            msg = error.get("message") or str(data)
            raise RuntimeError(
                f"GitHub Models returned no choices: {msg[:400]}"
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

                args = sanitize_for_agent(args)

                if isinstance(args, str):
                    try:
                        args = json.loads(args)
                    except json.JSONDecodeError:
                        args = {}

                if not name:
                    continue

                tag_lines.append(
                    f'<tool>{json.dumps({"tool": name, "parameters": args}, ensure_ascii=False)}</tool>'
                )

                print(
                    f"[orch] GitHub Models tool_call -> {name}({args})",
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
    #     # GitHub Models supports OpenAI function-calling format on capable models.
    #     if tools:
    #         payload["tools"] = tools
    #
    #     raw = json.dumps(payload).encode("utf-8")
    #     request = _req.Request(
    #         f"{self.base_url}/inference/chat/completions",
    #         data=raw,
    #         headers={
    #             "Authorization": f"Bearer {self.api_key}",
    #             "Content-Type": "application/json",
    #             "Accept": "application/vnd.github+json",
    #             "X-GitHub-Api-Version": self.API_VERSION,
    #         },
    #         method="POST",
    #     )
    #
    #     print(
    #         f"[orch] GitHub Models request '{self.model_id}' "
    #         f"({len(messages)} msgs, tools={bool(tools)})...",
    #         file=sys.stderr,
    #         flush=True,
    #     )
    #
    #     # Retry on 429 with exponential backoff, honouring the
    #     # `Retry-After` and GitHub's `x-ratelimit-reset` / `x-ratelimit-timeremaining`
    #     # headers when present. GitHub Models rate limits are very strict
    #     # (free `low` tier: 15 req/min, 150 req/day; `high` tier: 10/min, 50/day),
    #     # and the orchestrator's tool-loop emits multiple requests per turn,
    #     # so transient 429s are expected on consecutive prompts.
    #     # Reasoning models (phi-4, DeepSeek-R1, the o-series) routinely
    #     # think for several minutes before emitting a single token, so we
    #     # need a long socket timeout. We also tick a heartbeat to stderr
    #     # every 20s so the Flutter-side inactivity watchdog (10 min) stays
    #     # happy while urllib is blocked on the read.
    #     max_attempts = 4
    #     body = ""
    #     # 10 min per attempt — long-thinking reasoning models need it.
    #     request_timeout = 600
    #     for attempt in range(max_attempts):
    #         heartbeat_stop = threading.Event()
    #
    #         def _heartbeat():
    #             ticks = 0
    #             while not heartbeat_stop.wait(20):
    #                 ticks += 1
    #                 print(
    #                     f"[orch] GitHub Models still waiting "
    #                     f"({ticks * 20}s elapsed, model={self.model_id})...",
    #                     file=sys.stderr,
    #                     flush=True,
    #                 )
    #
    #         hb = threading.Thread(target=_heartbeat, daemon=True)
    #         hb.start()
    #         try:
    #             with _req.urlopen(request, timeout=request_timeout) as resp:
    #                 body = resp.read().decode("utf-8")
    #             heartbeat_stop.set()
    #             break
    #         except _err.HTTPError as e:
    #             heartbeat_stop.set()
    #             if e.code == 429 and attempt < max_attempts - 1:
    #                 retry_after = e.headers.get("Retry-After")
    #                 wait_s: float
    #                 if retry_after and retry_after.strip().isdigit():
    #                     wait_s = float(retry_after)
    #                 else:
    #                     # Exponential backoff: 5s, 15s, 35s.
    #                     wait_s = 5.0 * (2 ** attempt) + 5.0
    #                 print(
    #                     f"[orch] GitHub Models 429 — sleeping {wait_s:.0f}s "
    #                     f"(attempt {attempt + 1}/{max_attempts})...",
    #                     file=sys.stderr,
    #                     flush=True,
    #                 )
    #                 time.sleep(wait_s)
    #                 continue
    #             body_err = e.read().decode("utf-8", errors="replace")
    #             hint = ""
    #             if e.code == 429:
    #                 hint = (
    #                     " — GitHub Models rate limit hit. Free tiers are "
    #                     "15 req/min (`low`) or 10 req/min (`high`) and "
    #                     "150/50 per day. Wait ~60s, switch to a `low`-tier "
    #                     "model, or set a TPM/RPM limit in Settings."
    #                 )
    #             raise RuntimeError(
    #                 f"GitHub Models HTTP {e.code}: {body_err[:400]}{hint}"
    #             ) from e
    #         except Exception as e:
    #             heartbeat_stop.set()
    #             # Surface a clearer hint when the long socket timeout fires —
    #             # it usually means the model is generating a very long reply
    #             # or is heavily loaded. Encourage the user to lower max_tokens
    #             # or pick a smaller / non-reasoning model.
    #             hint = ""
    #             if "timed out" in str(e).lower():
    #                 hint = (
    #                     f" — request exceeded {request_timeout}s. "
    #                     "Reasoning models (phi-4, DeepSeek-R1, o-series) "
    #                     "can take this long; try lowering Max tokens, "
    #                     "shortening the prompt, or picking a faster model."
    #                 )
    #             raise RuntimeError(f"GitHub Models error: {e}{hint}") from e
    #
    #     try:
    #         data = json.loads(body)
    #     except json.JSONDecodeError as exc:
    #         raise RuntimeError(
    #             f"GitHub Models: invalid JSON response: {body[:200]}"
    #         ) from exc
    #
    #     choices = data.get("choices") or []
    #     if not choices:
    #         error = data.get("error") or {}
    #         msg = error.get("message") or str(data)
    #         raise RuntimeError(f"GitHub Models returned no choices: {msg[:400]}")
    #
    #     choice = choices[0]
    #     message = choice.get("message") or {}
    #     finish_reason = choice.get("finish_reason") or ""
    #
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
    #                 f"[orch] GitHub Models native tool_call -> {name}({args})",
    #                 file=sys.stderr,
    #                 flush=True,
    #             )
    #         if tag_lines:
    #             return "\n".join(tag_lines), finish_reason
    #
    #     content = message.get("content") or ""
    #     return content.strip(), finish_reason
