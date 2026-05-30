"""GitHub Models backend — inherits from OpenAICompatBackend."""

from __future__ import annotations

import sys
import threading
from typing import Any, Dict, List, Optional, Tuple

from .openai_compat import OpenAICompatBackend, RateLimitError, ToolsNotSupportedError


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


class GitHubModelsBackend(OpenAICompatBackend):
    """
    GitHub Models via the OpenAI-compatible REST API (stdlib urllib, no extra dep).

    Endpoint: https://models.github.ai/inference/chat/completions
    Auth: fine-grained PAT with ``models:read`` scope.
    Model IDs: ``openai/gpt-4o``, ``meta/Llama-3.3-70B-Instruct``, etc.
    PAT: https://github.com/settings/personal-access-tokens/new

    A heartbeat thread ticks to stderr every 20 s so the Flutter-side
    inactivity watchdog stays happy while reasoning models think.
    429 backoff is handled by the base class.
    """

    DEFAULT_BASE_URL = "https://models.github.ai"
    API_VERSION = "2026-03-10"

    def __init__(
        self,
        api_key: str,
        model_id: str,
        base_url: str = DEFAULT_BASE_URL,
    ):
        super().__init__(api_key, model_id, base_url=base_url, label="GitHub Models")

    def _do_request(
        self,
        payload: Dict[str, Any],
        effective_tools: Optional[List[Dict[str, Any]]],
    ) -> Tuple[str, str, List[Any], int]:
        import json
        import urllib.error as _err
        import urllib.request as _req

        n_tools = len(effective_tools) if effective_tools else 0
        url = f"{self.base_url}/inference/chat/completions"
        _log(
            f"[GitHub Models:request] POST {url} "
            f"model={payload['model']} msgs={len(payload['messages'])} "
            f"tools={n_tools} max_tokens={payload.get('max_tokens')} "
            f"temperature={payload.get('temperature')} timeout=600s"
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
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": self.API_VERSION,
            },
            method="POST",
        )

        heartbeat_stop = threading.Event()

        def _heartbeat() -> None:
            ticks = 0
            while not heartbeat_stop.wait(20):
                ticks += 1
                _log(
                    f"[GitHub Models:heartbeat] waiting "
                    f"({ticks * 20}s elapsed, model={self.model_id})..."
                )

        hb = threading.Thread(target=_heartbeat, daemon=True)
        hb.start()

        try:
            with _req.urlopen(request, timeout=600) as resp:
                body = resp.read().decode("utf-8", errors="replace")
            heartbeat_stop.set()
            _log(f"[GitHub Models:http_ok] response_len={len(body)}")
        except _err.HTTPError as exc:
            heartbeat_stop.set()
            body_err = ""
            try:
                body_err = exc.read().decode("utf-8", errors="replace")
            except Exception:
                pass
            _log(
                f"[GitHub Models:http_error] status={exc.code} body={body_err[:400]!r}"
            )
            if exc.code == 429:
                ra = exc.headers.get("Retry-After", "")
                retry_after = float(ra) if ra.strip().isdigit() else 0.0
                _log(f"[GitHub Models:rate_limit] retry_after={retry_after:.0f}s")
                raise RateLimitError(
                    "GitHub Models 429",
                    retry_after=retry_after,
                ) from exc
            if exc.code == 400 and effective_tools and "tool" in body_err.lower():
                _log(
                    f"[GitHub Models:tools_unsupported] raising ToolsNotSupportedError"
                )
                raise ToolsNotSupportedError(body_err) from exc
            raise RuntimeError(
                f"GitHub Models HTTP {exc.code}: {body_err[:400]}"
            ) from exc
        except Exception as exc:
            heartbeat_stop.set()
            hint = (
                f" — request exceeded 600 s. Try lower max_tokens or a faster model."
                if "timed out" in str(exc).lower()
                else ""
            )
            _log(f"[GitHub Models:error] {type(exc).__name__}: {exc}{hint}")
            raise RuntimeError(f"GitHub Models error: {exc}{hint}") from exc

        try:
            data = json.loads(body)
        except json.JSONDecodeError as exc:
            _log(f"[GitHub Models:json_error] failed to parse response: {body[:200]!r}")
            raise RuntimeError(
                f"GitHub Models: invalid JSON response: {body[:200]}"
            ) from exc

        choices = data.get("choices") or []
        if not choices:
            error = data.get("error") or {}
            err_msg = error.get("message") or str(data)[:400]
            _log(f"[GitHub Models:no_choices] error={err_msg!r}")
            raise RuntimeError(f"GitHub Models returned no choices: {err_msg}")

        choice = choices[0]
        message = choice.get("message") or {}
        finish_reason = choice.get("finish_reason") or ""
        tool_calls = message.get("tool_calls") or []
        content = message.get("content") or ""
        usage = int((data.get("usage") or {}).get("total_tokens") or 0)

        _log(
            f"[GitHub Models:parsed] finish_reason={finish_reason!r} "
            f"content_len={len(content)} tool_calls={len(tool_calls)} "
            f"usage_tokens={usage}"
        )
        return content, finish_reason, tool_calls, usage
