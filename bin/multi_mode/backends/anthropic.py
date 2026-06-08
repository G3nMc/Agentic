"""Anthropic (Claude) backend for multi_mode -- pure REST.

Talks to ``https://api.anthropic.com/v1/messages`` directly via
``requests``. SSE streaming. No ``anthropic`` SDK import.

Anthropic's chat shape is different from OpenAI:
  - ``system`` is a top-level field (not a role in ``messages``).
  - SSE events are typed (``content_block_delta``, ``message_delta``,
    ``message_stop``) and the text deltas live in
    ``delta.text``.
"""

from __future__ import annotations

import sys
import time
from typing import Any, Dict, List, Optional, Tuple

from bin.common.backends.http_client import (
    HttpError,
    RateLimitError,
    ServerError,
    stream_sse,
)
from multi_mode.backends.base import CompletionResponse, LLMBackend
from multi_mode.config.models import ModelConfig


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


_ANTHROPIC_VERSION = "2023-06-01"


class AnthropicBackend(LLMBackend):
    """Anthropic Messages API over plain REST."""

    DEFAULT_BASE_URL = "https://api.anthropic.com/v1"

    def __init__(self, config: ModelConfig):
        super().__init__(config)
        if not config.api_key:
            raise RuntimeError("AnthropicBackend requires config.api_key.")
        if not config.model:
            raise RuntimeError("AnthropicBackend requires config.model.")
        self._base_url = (config.base_url or self.DEFAULT_BASE_URL).rstrip("/")
        _log(
            f"[Anthropic:init] model={config.model} base_url={self._base_url} "
            f"role={getattr(config, 'role', '?')}"
        )

    def _endpoint(self) -> str:
        return f"{self._base_url}/messages"

    def _auth_headers(self) -> Dict[str, str]:
        return {
            "x-api-key": self.config.api_key,
            "anthropic-version": _ANTHROPIC_VERSION,
        }

    @staticmethod
    def _split_system(messages: List[Dict[str, Any]]) -> Tuple[str, List[Dict[str, Any]]]:
        """Anthropic wants ``system`` as a top-level string + a
        ``messages`` array containing only ``user``/``assistant``."""
        system_parts: List[str] = []
        body: List[Dict[str, Any]] = []
        for msg in messages or []:
            if not isinstance(msg, dict):
                continue
            role = (msg.get("role") or "").lower()
            content = msg.get("content") or ""
            if not isinstance(content, str):
                content = str(content)
            if not content.strip():
                continue
            if role == "system":
                system_parts.append(content)
            elif role in ("user", "assistant"):
                body.append({"role": role, "content": content})
            else:
                body.append({"role": "user", "content": content})
        return "\n\n".join(system_parts), body

    def complete(
        self,
        messages: List[Dict[str, Any]],
        tools: Optional[List[Dict[str, Any]]] = None,
        **kwargs,
    ) -> CompletionResponse:
        # [native-tools-removed] We never forward tools.
        _ = tools

        system, body = self._split_system(messages)
        payload: Dict[str, Any] = {
            "model": self.config.model,
            "messages": body,
            "max_tokens": kwargs.get("max_tokens", self.config.max_tokens),
            "temperature": kwargs.get("temperature", self.config.temperature),
            "stream": True,
        }
        if system:
            payload["system"] = system
        stop = kwargs.get("stop")
        if stop:
            payload["stop_sequences"] = list(stop)

        _log(
            f"[Anthropic:complete] model={self.config.model} msgs={len(body)} "
            f"system={bool(system)} max_tokens={payload['max_tokens']} "
            f"stop={payload.get('stop_sequences')}"
        )

        parts: List[str] = []
        finish_reason = "stop"
        chunk_count = 0
        last_heartbeat = time.time()

        try:
            for chunk in stream_sse(
                self._endpoint(),
                payload,
                headers=self._auth_headers(),
                label="Anthropic",
            ):
                chunk_count += 1
                ctype = chunk.get("type")
                if ctype == "content_block_delta":
                    delta = chunk.get("delta") or {}
                    text_piece = delta.get("text")
                    if text_piece:
                        parts.append(text_piece)
                elif ctype == "message_delta":
                    delta = chunk.get("delta") or {}
                    fr = delta.get("stop_reason")
                    if fr:
                        # end_turn / max_tokens / stop_sequence -> OpenAI-ish
                        finish_reason = {
                            "end_turn": "stop",
                            "stop_sequence": "stop",
                            "max_tokens": "length",
                            "tool_use": "tool_calls",
                        }.get(fr, fr)
                now = time.time()
                if now - last_heartbeat >= 5.0:
                    _log(
                        f"[Anthropic:streaming] model={self.config.model} "
                        f"chunks={chunk_count} chars={sum(len(p) for p in parts)}"
                    )
                    last_heartbeat = now
        except RateLimitError as e:
            raise RuntimeError(f"Anthropic rate limit: {e}") from e
        except (ServerError, HttpError) as e:
            raise RuntimeError(f"Anthropic HTTP error: {e}") from e

        content = "".join(parts)
        _log(
            f"[Anthropic:done] model={self.config.model} content_len={len(content)} "
            f"finish_reason={finish_reason!r} chunks={chunk_count}"
        )
        return CompletionResponse(
            content=content if content else None,
            tool_calls=[],
            finish_reason=finish_reason,
            usage={},
        )

    def count_tokens(self, text: str) -> int:
        return max(1, len(text) // 4)

    def supports_native_tools(self) -> bool:
        return False

    def get_tool_format(self) -> str:
        return "anthropic"
