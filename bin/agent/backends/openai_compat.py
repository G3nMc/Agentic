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
    "RateLimitError"
]

import re

def _clean_protocol_content(content: str) -> str:
    if not content:
        return ""

    # Remove Markdown code fences used around protocol blocks.
    content = re.sub(r"```(?:html|xml|text)?\s*", "", content, flags=re.IGNORECASE)
    content = re.sub(r"\s*```", "", content)

    return content.strip()


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)



class OpenAICompatBackend(ModelBackend):
    """OpenAI-compatible chat/completions over plain HTTP."""

    # Subclasses MUST set DEFAULT_BASE_URL.
    DEFAULT_BASE_URL: str = ""
    last_prompt_eval_count = 0

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
            tools: Optional[List[Dict[str, Any]]] = None,
            stop: Optional[List[str]] = None,
            thinking: bool = False,
            effort: Optional[str] = None,
            stream: bool = False,
            on_thinking=None,
    ) -> Tuple[str, str]:
        # OpenRouter uses the OpenAI chat-completions format.
        # Native tools are intentionally not forwarded; the agent uses text protocol.
        _ = tools

        conversation.sanitize()
        messages = conversation.to_messages()
        msg_count = len(conversation.turns)

        payload: Dict[str, Any] = {
            "model": self.model_id,
            "messages": messages,
            "max_completion_tokens": max_tokens,
            "temperature": temperature,
            "stop": list(stop) if stop else None,
            "stream": stream,
        }

        if thinking and effort:
            effort_str = str(effort).lower()
            payload["reasoning_effort"] = effort_str

        _log(
            f"[{self._label}:chat] model={self.model_id} "
            f"stream={stream} turns={msg_count} max_tokens={max_tokens} "
            f"temperature={temperature} stop={payload.get('stop')} "
            f"reasoning_effort={payload.get('reasoning_effort')}"
        )

        try:
            if stream:
                chunks = stream_sse(
                    self._endpoint(),
                    payload,
                    headers=self._auth_headers(),
                    label=self._label,
                )

                content, finish_reason = assemble_openai_chat_stream(
                    chunks,
                    label=self._label,
                    on_thinking=on_thinking,
                )

                content = _clean_protocol_content(content)

                _log(
                    f"[{self._label}:done] stream={stream} "
                    f"content_len={len(content)} "
                    f"finish_reason={finish_reason!r}"
                )

            else:
                import requests

                response = requests.post(
                    self._endpoint(),
                    json=payload,
                    headers=self._auth_headers(),
                    timeout=(15.0, 600.0),
                )

                if response.status_code == 429:
                    raise RateLimitError(
                        f"HTTP 429: {response.text[:1000]}"
                    )

                if response.status_code >= 400:
                    raise HttpError(
                        f"HTTP {response.status_code}: {response.text[:2000]}"
                    )

                data = response.json()

                choices = data.get("choices") or []
                if not choices:
                    raise RuntimeError(
                        f"{self._label}: OpenRouter returned no choices: {data}"
                    )

                choice = choices[0] or {}
                message = choice.get("message") or {}

                content = message.get("content") or ""
                content = _clean_protocol_content(content)

                reasoning = message.get("reasoning_content") or message.get("reasoning")
                if reasoning and on_thinking is not None:
                    on_thinking(reasoning)

                finish_reason = choice.get("finish_reason") or "stop"

                usage = data.get("usage") or {}

                self.last_prompt_eval_count = int(
                    usage.get("prompt_tokens", 0) or 0
                )

                self.last_usage_tokens = int(
                    usage.get("total_tokens", 0) or 0
                )

                _log(
                    f"[{self._label}:non-stream] "
                    f"content_len={len(content)} "
                    f"finish_reason={finish_reason!r} "
                    f"prompt_tokens={usage.get('prompt_tokens')} "
                    f"completion_tokens={usage.get('completion_tokens')} "
                    f"total_tokens={usage.get('total_tokens')}"
                )

        except RateLimitError as e:
            raise RuntimeError(f"{self._label} rate limit: {e}") from e
        except (ServerError, HttpError) as e:
            raise RuntimeError(f"{self._label} HTTP error: {e}") from e
        except ValueError as e:
            raise RuntimeError(
                f"{self._label} invalid JSON response: {e}"
            ) from e

        return content, finish_reason


