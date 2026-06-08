"""Ollama backend for multi_mode -- pure REST.

Talks to ``/api/chat`` (chat-formatted messages) via NDJSON streaming
through :mod:`common.backends.http_client`. No SDK import.
"""

from __future__ import annotations

import sys
import time
from typing import Any, Dict, List, Optional

from .base import CompletionResponse, LLMBackend
from bin.common.backends.http_client import (
    HttpError,
    RateLimitError,
    ServerError,
    stream_ndjson,
)
from ..config.models import ModelConfig


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


class OllamaBackend(LLMBackend):
    """Ollama ``/api/chat`` over plain REST + NDJSON streaming."""

    DEFAULT_BASE_URL = "http://localhost:11434"

    def __init__(self, config: ModelConfig):
        super().__init__(config)
        if not config.model:
            raise RuntimeError("OllamaBackend requires config.model.")
        self._base_url = (config.base_url or self.DEFAULT_BASE_URL).rstrip("/")
        _log(
            f"[Ollama:init] model={config.model} base_url={self._base_url} "
            f"role={getattr(config, 'role', '?')}"
        )

    def _auth_headers(self) -> Dict[str, str]:
        if self.config.api_key:
            return {"Authorization": f"Bearer {self.config.api_key}"}
        return {}

    def complete(
            self,
            messages: List[Dict[str, Any]],
            tools: Optional[List[Dict[str, Any]]] = None,
            **kwargs,
    ) -> CompletionResponse:
        # [native-tools-removed] We never forward tools.
        _ = tools

        options: Dict[str, Any] = {
            "temperature": kwargs.get("temperature", self.config.temperature),
            "num_predict": kwargs.get("max_tokens", self.config.max_tokens),
        }
        stop = kwargs.get("stop")
        if stop:
            options["stop"] = list(stop)

        payload: Dict[str, Any] = {
            "model": self.config.model,
            "messages": messages,
            "stream": True,
            "options": options,
        }

        _log(
            f"[Ollama:complete] POST {self._base_url}/api/chat model={self.config.model} "
            f"msgs={len(messages)} max_tokens={options['num_predict']} stop={options.get('stop')}"
        )

        parts: List[str] = []
        finish_reason = "stop"
        chunk_count = 0
        last_heartbeat = time.time()
        usage_tokens = 0

        try:
            for chunk in stream_ndjson(
                    f"{self._base_url}/api/chat",
                    payload,
                    headers=self._auth_headers(),
                    label="Ollama",
                    timeout=(15.0, 600.0),
            ):
                chunk_count += 1
                msg = chunk.get("message") or {}
                piece = msg.get("content") or ""
                if piece:
                    parts.append(piece)
                if chunk.get("done"):
                    finish_reason = chunk.get("done_reason") or "stop"
                    usage_tokens = int(
                        chunk.get("prompt_eval_count", 0)
                        + chunk.get("eval_count", 0)
                    )
                now = time.time()
                if now - last_heartbeat >= 5.0:
                    _log(
                        f"[Ollama:streaming] model={self.config.model} "
                        f"chunks={chunk_count} chars={sum(len(p) for p in parts)}"
                    )
                    last_heartbeat = now
        except RateLimitError as e:
            raise RuntimeError(f"Ollama rate limit: {e}") from e
        except (ServerError, HttpError) as e:
            raise RuntimeError(f"Ollama HTTP error: {e}") from e

        content = "".join(parts)
        _log(
            f"[Ollama:done] model={self.config.model} content_len={len(content)} "
            f"finish_reason={finish_reason!r} chunks={chunk_count} usage={usage_tokens}"
        )
        return CompletionResponse(
            content=content if content else None,
            tool_calls=[],
            finish_reason=finish_reason,
            usage={"total_tokens": usage_tokens} if usage_tokens else {},
        )

    def count_tokens(self, text: str) -> int:
        return max(1, len(text) // 4)

    def supports_native_tools(self) -> bool:
        return False

    def get_tool_format(self) -> str:
        return "openai"
