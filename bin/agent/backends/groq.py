"""Groq Cloud backend — inherits from OpenAICompatBackend."""
from __future__ import annotations

import sys
from typing import Any, Dict, List, Optional, Tuple

from .openai_compat import OpenAICompatBackend, ToolsNotSupportedError


class GroqBackend(OpenAICompatBackend):
    """
    Groq Cloud via the official ``groq`` Python library.
    Ultra-fast LPU inference. API key: https://console.groq.com/keys

    Uses streaming so token chunks act as heartbeats — the Flutter-side
    inactivity watchdog stays happy even on slow/large responses.
    """

    def __init__(self, api_key: str, model_id: str):
        super().__init__(api_key, model_id, label="Groq")
        from groq import Groq  # noqa: PLC0415
        self._client = Groq(api_key=api_key)

    def _do_request(
        self,
        payload: Dict[str, Any],
        effective_tools: Optional[List[Dict[str, Any]]],
    ) -> Tuple[str, str, List[Any], int]:
        from groq import BadRequestError  # noqa: PLC0415

        chat_kwargs: Dict[str, Any] = {
            "model":                payload["model"],
            "messages":             payload["messages"],
            "stream":               True,
            "temperature":          payload["temperature"],
            "max_completion_tokens": payload["max_tokens"],
        }
        if effective_tools:
            chat_kwargs["tools"] = effective_tools

        try:
            parts: List[str] = []
            finish_reason = ""
            native_calls: List[Any] = []
            chunk_count = 0

            stream = self._client.chat.completions.create(**chat_kwargs)
            for chunk in stream:
                delta = chunk.choices[0].delta if chunk.choices else None
                if delta:
                    if delta.content:
                        parts.append(delta.content)
                    native_calls.extend(getattr(delta, "tool_calls", None) or [])
                chunk_count += 1
                if chunk_count % 20 == 1:
                    print(
                        f"[orch] Groq streaming '{self.model_id}' "
                        f"({len(''.join(parts))} chars)...",
                        file=sys.stderr,
                        flush=True,
                    )
                if chunk.choices and chunk.choices[0].finish_reason:
                    finish_reason = chunk.choices[0].finish_reason

            return "".join(parts).strip(), finish_reason, native_calls, 0

        except BadRequestError as exc:
            err = str(exc).lower()
            if (
                effective_tools
                and "tool" in err
                and ("not supported" in err or "unsupported" in err)
            ):
                raise ToolsNotSupportedError(str(exc)) from exc
            raise RuntimeError(f"Groq bad request: {exc}") from exc

        except Exception as exc:
            raise RuntimeError(f"Groq error: {exc}") from exc
