"""OpenAI (and OpenAI-compatible) backend for multi_mode -- pure REST.

No ``openai`` SDK. All requests go through
:mod:`common.backends.http_client` which only depends on ``requests``.

Native function calling is intentionally disabled: the orchestrator's
tool protocol is text-only (``<tool>...</tool>``). See
``[native-tools-removed]`` in ``common/backends/openai_compat.py``.
"""

from __future__ import annotations

import sys
from typing import Any, Dict, List, Optional

from bin.common.backends.http_client import (
    HttpError,
    RateLimitError,
    ServerError,
    assemble_openai_chat_stream,
    stream_sse,
)
from ..config.models import ModelConfig
from .base import LLMBackend, CompletionResponse


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


class OpenAIBackend(LLMBackend):
    """OpenAI-compatible chat/completions over plain HTTP."""

    DEFAULT_BASE_URL = "https://api.openai.com/v1"

    def __init__(self, config: ModelConfig):
        super().__init__(config)
        if not config.api_key:
            raise RuntimeError("OpenAIBackend requires config.api_key.")
        if not config.model:
            raise RuntimeError("OpenAIBackend requires config.model.")
        self._base_url = (config.base_url or self.DEFAULT_BASE_URL).rstrip("/")
        _log(
            f"[OpenAI:init] model={config.model} base_url={self._base_url} "
            f"role={getattr(config, 'role', '?')}"
        )

    def _endpoint(self) -> str:
        return f"{self._base_url}/chat/completions"

    def _auth_headers(self) -> Dict[str, str]:
        return {"Authorization": f"Bearer {self.config.api_key}"}

    def complete(
        self,
        messages: List[Dict[str, Any]],
        tools: Optional[List[Dict[str, Any]]] = None,
        **kwargs,
    ) -> CompletionResponse:
        # [native-tools-removed] We never forward tools to the API.
        _ = tools

        payload: Dict[str, Any] = {
            "model": self.config.model,
            "messages": messages,
            "temperature": kwargs.get("temperature", self.config.temperature),
            "max_tokens": kwargs.get("max_tokens", self.config.max_tokens),
            "stream": True,
        }
        # Reasoning effort: "max" maps to "high" (OpenAI's highest level)
        rl = kwargs.get("reasoning_level")
        if rl is not None:
            rl_str = str(rl).lower()
            if rl_str == "max":
                rl_str = "high"
            payload["reasoning_effort"] = rl_str
        stop = kwargs.get("stop")
        if stop:
            payload["stop"] = list(stop)[:4]

        _log(
            f"[OpenAI:complete] model={self.config.model} msgs={len(messages)} "
            f"max_tokens={payload['max_tokens']} stop={payload.get('stop')}"
        )

        try:
            chunks = stream_sse(
                self._endpoint(),
                payload,
                headers=self._auth_headers(),
                label="OpenAI",
            )
            content, finish_reason = assemble_openai_chat_stream(chunks, label="OpenAI")
        except RateLimitError as e:
            raise RuntimeError(f"OpenAI rate limit: {e}") from e
        except (ServerError, HttpError) as e:
            raise RuntimeError(f"OpenAI HTTP error: {e}") from e

        _log(
            f"[OpenAI:done] model={self.config.model} content_len={len(content)} "
            f"finish_reason={finish_reason!r}"
        )
        return CompletionResponse(
            content=content if content else None,
            tool_calls=[],
            finish_reason=finish_reason,
            usage={},
        )

    def count_tokens(self, text: str) -> int:
        """Rough estimate: ~4 chars per token for English."""
        return max(1, len(text) // 4)

    def supports_native_tools(self) -> bool:
        # Even though the OpenAI API supports native tools, we
        # deliberately don't use them -- see [native-tools-removed].
        return False

    def get_tool_format(self) -> str:
        return "openai"
