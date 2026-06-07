"""Groq Cloud backend — inherits from OpenAICompatBackend."""

from __future__ import annotations

import sys
from typing import Any, Dict, List, Optional, Tuple

from .openai_compat import OpenAICompatBackend, ToolsNotSupportedError


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


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
        _log(f"[Groq:init] Groq SDK client created for model={model_id}")

    def _do_request(
        self,
        payload: Dict[str, Any],
        effective_tools: Optional[List[Dict[str, Any]]],
    ) -> Tuple[str, str, List[Any], int]:
        from groq import BadRequestError  # noqa: PLC0415

        n_tools = len(effective_tools) if effective_tools else 0
        _log(
            f"[Groq:stream_start] model={payload['model']} "
            f"msgs={len(payload['messages'])} tools={n_tools} "
            f"max_tokens={payload.get('max_completion_tokens') or payload.get('max_tokens')} "
            f"temperature={payload.get('temperature')}"
        )

        chat_kwargs: Dict[str, Any] = {
            "model": payload["model"],
            "messages": payload["messages"],
            "stream": True,
            "temperature": payload["temperature"],
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
                    _log(
                        f"[Groq:streaming] model={self.model_id} "
                        f"chunks={chunk_count} chars={len(''.join(parts))}"
                    )
                if chunk.choices and chunk.choices[0].finish_reason:
                    finish_reason = chunk.choices[0].finish_reason

            _log(
                f"[Groq:stream_done] model={self.model_id} "
                f"total_chunks={chunk_count} "
                f"content_len={len(''.join(parts))} "
                f"tool_calls={len(native_calls)} "
                f"finish_reason={finish_reason!r}"
            )
            return "".join(parts).strip(), finish_reason, native_calls, 0

        except BadRequestError as exc:
            err = str(exc).lower()
            _log(
                f"[Groq:bad_request] model={self.model_id} "
                f"tools_attached={bool(effective_tools)} error={exc}"
            )
            if (
                effective_tools
                and "tool" in err
                and ("not supported" in err or "unsupported" in err)
            ):
                _log(f"[Groq:tools_unsupported] raising ToolsNotSupportedError")
                raise ToolsNotSupportedError(str(exc)) from exc
            raise RuntimeError(f"Groq bad request: {exc}") from exc

        except Exception as exc:
            _log(f"[Groq:error] model={self.model_id} {type(exc).__name__}: {exc}")
            raise RuntimeError(f"Groq error: {exc}") from exc
