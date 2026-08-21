"""Base class for OpenAI-compatible chat/completions backends.

Every provider that speaks the OpenAI wire format (OpenAI itself,
Groq, OpenRouter, GitHub Models, HuggingFace Inference, DeepSeek,
Mistral, x.AI, Perplexity, ...) inherits from this class. The only
thing subclasses customize is the request URL and the auth header --
everything else (payload shape, SSE streaming, retries, error
handling) is shared.

NOTE on the design:
  - No provider SDK is imported. Every request goes through
    :mod:`common.backends.http_client` which only depends on
    ``requests``.
  - **Native function calling is NOT used**. The orchestrator's tool
    protocol is purely textual: tool definitions live in the system
    prompt and the model emits ``<tool>{...}</tool>`` tags in plain
    text. ``stop=["</tool>"]`` (see ``run_loop._call_model``) ensures
    the model halts right after a single tool call. The legacy
    ``tools=[...]`` payload field is therefore never sent, even when
    the provider advertises support.
"""

from __future__ import annotations

import sys
from typing import Any, Dict, List, Optional, Tuple

from .backend_base import ModelBackend
from .http_client import (
    HttpError,
    RateLimitError,
    ServerError,
    assemble_openai_chat_stream,
    stream_sse,
)


# Re-exported for backwards compatibility with callers that imported
# these names from this module (``agent.backends.__init__`` still
# does). ``ToolsNotSupportedError`` is now obsolete -- we never send
# native tools -- but keeping the symbol avoids breaking imports.
__all__ = [
    "OpenAICompatBackend",
    "RateLimitError",
    "ToolsNotSupportedError",
]


class ToolsNotSupportedError(Exception):
    """DEPRECATED. Kept so existing imports continue to resolve."""


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


class OpenAICompatBackend(ModelBackend):
    """OpenAI-compatible chat/completions over plain HTTP."""

    # Subclasses MUST set DEFAULT_BASE_URL.
    DEFAULT_BASE_URL: str = ""

    def __init__(
        self,
        api_key: str,
        model_id: str,
        base_url: str = "",
        label: str = "",
    ):
        if not api_key:
            raise RuntimeError(f"{self.__class__.__name__} requires an API key.")
        if not model_id:
            raise RuntimeError(f"{self.__class__.__name__} requires a model ID.")
        self.api_key = api_key
        self.model_id = model_id
        self.base_url = (base_url or self.DEFAULT_BASE_URL).rstrip("/")
        if not self.base_url:
            raise RuntimeError(
                f"{self.__class__.__name__} requires a base_url "
                "(neither passed in nor set on the class)."
            )
        self._label = label or self.__class__.__name__
        self.last_usage_tokens: int = 0
        _log(f"[{self._label}:init] model={model_id} base_url={self.base_url}")

    # ------------------------------------------------------------------
    # Hooks subclasses may override
    # ------------------------------------------------------------------

    def _endpoint(self) -> str:
        """URL of the chat completions endpoint."""
        return f"{self.base_url}/chat/completions"

    def _auth_headers(self) -> Dict[str, str]:
        """Headers for the request. Default is bearer ``api_key``."""
        return {"Authorization": f"Bearer {self.api_key}"}

    # ------------------------------------------------------------------
    # ModelBackend.chat
    # ------------------------------------------------------------------

    def chat(
        self,
        conversation,
        max_tokens: int,
        temperature: float,
        tools: Optional[List[Dict[str, Any]]] = None,  # ignored on purpose
        stop: Optional[List[str]] = None,
        thinking: bool = False,
        effort: Optional[str] = None,
    ) -> Tuple[str, str]:
        # [native-tools-removed] We never forward ``tools`` to the API.
        # The agent uses text protocol exclusively (<tool>...</tool>).
        # If you need to roll back, search ``[native-tools-removed]``.
        _ = tools

        # Centralized sanitization in the ConversationHistory.
        conversation.sanitize()
        messages = conversation.to_messages()

        payload: Dict[str, Any] = {
            "model": self.model_id,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "stream": False,
        }
        if stop:
            payload["stop"] = list(stop)[:4]
        # Thinking + Effort: when thinking is ON, map effort to
        # OpenAI reasoning_effort ("max" -> "high", OpenAI's highest).
        if thinking and effort:
            effort_str = str(effort).lower()
            if effort_str == "max":
                effort_str = "high"
            payload["reasoning_effort"] = effort_str

        _log(
            f"[{self._label}:chat] model={self.model_id} "
            f"msgs={len(messages)} max_tokens={max_tokens} "
            f"temperature={temperature} stop={payload.get('stop')}"
        )

        try:
            chunks = stream_sse(
                self._endpoint(),
                payload,
                headers=self._auth_headers(),
                label=self._label,
            )
            content, finish_reason = assemble_openai_chat_stream(chunks, label=self._label)
        except RateLimitError as e:
            raise RuntimeError(f"{self._label} rate limit: {e}") from e
        except (ServerError, HttpError) as e:
            raise RuntimeError(f"{self._label} HTTP error: {e}") from e

        _log(
            f"[{self._label}:done] content_len={len(content)} "
            f"finish_reason={finish_reason!r}"
        )
        return content, finish_reason

    # ------------------------------------------------------------------
    # Health check (used by orchestrator.py startup probe for some backends)
    # ------------------------------------------------------------------

    def health_check(self) -> None:
        """Best-effort connectivity check. Default is a no-op."""
        return None
