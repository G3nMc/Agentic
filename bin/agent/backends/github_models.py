"""GitHub Models backend — inherits from OpenAICompatBackend."""
from __future__ import annotations

import sys
import threading
from typing import Any, Dict, List, Optional, Tuple

from .openai_compat import OpenAICompatBackend, RateLimitError, ToolsNotSupportedError


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

        raw = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode(
            "utf-8", errors="ignore"
        )
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

        heartbeat_stop = threading.Event()

        def _heartbeat() -> None:
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
            with _req.urlopen(request, timeout=600) as resp:
                body = resp.read().decode("utf-8", errors="replace")
            heartbeat_stop.set()
        except _err.HTTPError as exc:
            heartbeat_stop.set()
            if exc.code == 429:
                ra = exc.headers.get("Retry-After", "")
                raise RateLimitError(
                    "GitHub Models 429",
                    retry_after=float(ra) if ra.strip().isdigit() else 0.0,
                ) from exc
            body_err = exc.read().decode("utf-8", errors="replace")
            if exc.code == 400 and effective_tools and "tool" in body_err.lower():
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
            raise RuntimeError(f"GitHub Models error: {exc}{hint}") from exc

        try:
            data = json.loads(body)
        except json.JSONDecodeError as exc:
            raise RuntimeError(
                f"GitHub Models: invalid JSON response: {body[:200]}"
            ) from exc

        choices = data.get("choices") or []
        if not choices:
            error = data.get("error") or {}
            raise RuntimeError(
                f"GitHub Models returned no choices: "
                f"{error.get('message') or str(data)[:400]}"
            )

        choice = choices[0]
        message = choice.get("message") or {}
        finish_reason = choice.get("finish_reason") or ""
        tool_calls = message.get("tool_calls") or []
        content = message.get("content") or ""
        usage = int((data.get("usage") or {}).get("total_tokens") or 0)

        return content, finish_reason, tool_calls, usage
