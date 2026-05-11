"""OpenRouter backend — inherits from OpenAICompatBackend."""
from __future__ import annotations

from typing import Any, Dict, List, Optional, Tuple

from .openai_compat import OpenAICompatBackend, RateLimitError, ToolsNotSupportedError


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

        raw = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode(
            "utf-8", errors="ignore"
        )
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

        try:
            with _req.urlopen(request, timeout=120) as resp:
                body = resp.read().decode("utf-8", errors="replace")
        except _err.HTTPError as exc:
            if exc.code == 429:
                ra = exc.headers.get("Retry-After", "")
                raise RateLimitError(
                    f"OpenRouter 429",
                    retry_after=float(ra) if ra.strip().isdigit() else 0.0,
                ) from exc
            body_err = exc.read().decode("utf-8", errors="replace")
            if exc.code == 400 and effective_tools and "tool" in body_err.lower():
                raise ToolsNotSupportedError(body_err) from exc
            raise RuntimeError(f"OpenRouter HTTP {exc.code}: {body_err[:400]}") from exc
        except Exception as exc:
            raise RuntimeError(f"OpenRouter error: {exc}") from exc

        try:
            data = json.loads(body)
        except json.JSONDecodeError as exc:
            raise RuntimeError(
                f"OpenRouter: invalid JSON response: {body[:200]}"
            ) from exc

        choices = data.get("choices") or []
        if not choices:
            error = data.get("error") or {}
            raise RuntimeError(
                f"OpenRouter returned no choices: "
                f"{error.get('message') or str(data)[:400]}"
            )

        choice = choices[0]
        message = choice.get("message") or {}
        finish_reason = choice.get("finish_reason") or ""
        tool_calls = message.get("tool_calls") or []
        content = message.get("content") or ""
        usage = int((data.get("usage") or {}).get("total_tokens") or 0)

        return content, finish_reason, tool_calls, usage
