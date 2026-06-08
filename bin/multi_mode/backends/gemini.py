"""Google Gemini backend for multi_mode -- pure REST.

Same wire format as :mod:`agent.backends.gemini` (single-agent mode):
SSE stream of ``streamGenerateContent``. No SDK import.
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


class GeminiBackend(LLMBackend):
    """Google AI Studio / Gemini Cloud over plain REST."""

    DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

    def __init__(self, config: ModelConfig):
        super().__init__(config)
        if not config.api_key:
            raise RuntimeError("GeminiBackend requires config.api_key.")
        if not config.model:
            raise RuntimeError("GeminiBackend requires config.model.")
        self._base_url = (config.base_url or self.DEFAULT_BASE_URL).rstrip("/")
        _log(
            f"[Gemini:init] model={config.model} base_url={self._base_url} "
            f"role={getattr(config, 'role', '?')}"
        )

    @staticmethod
    def _to_contents(
        messages: List[Dict[str, Any]],
    ) -> Tuple[str, List[Dict[str, Any]]]:
        system_parts: List[str] = []
        contents: List[Dict[str, Any]] = []
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
                continue
            gemini_role = "model" if role == "assistant" else "user"
            contents.append({"role": gemini_role, "parts": [{"text": content}]})
        return "\n\n".join(system_parts), contents

    def complete(
        self,
        messages: List[Dict[str, Any]],
        tools: Optional[List[Dict[str, Any]]] = None,
        **kwargs,
    ) -> CompletionResponse:
        # [native-tools-removed]
        _ = tools

        system_instruction, contents = self._to_contents(messages)

        generation_config: Dict[str, Any] = {
            "temperature": kwargs.get("temperature", self.config.temperature),
            "maxOutputTokens": kwargs.get("max_tokens", self.config.max_tokens),
        }
        stop = kwargs.get("stop")
        if stop:
            generation_config["stopSequences"] = list(stop)

        payload: Dict[str, Any] = {
            "contents": contents,
            "generationConfig": generation_config,
        }
        if system_instruction:
            payload["systemInstruction"] = {"parts": [{"text": system_instruction}]}

        url = (
            f"{self._base_url}/models/{self.config.model}:streamGenerateContent"
            f"?alt=sse&key={self.config.api_key}"
        )

        _log(
            f"[Gemini:complete] model={self.config.model} msgs={len(contents)} "
            f"system={bool(system_instruction)} "
            f"max_tokens={generation_config['maxOutputTokens']} "
            f"stop={generation_config.get('stopSequences')}"
        )

        parts: List[str] = []
        finish_reason = "stop"
        chunk_count = 0
        last_heartbeat = time.time()
        usage_tokens = 0

        try:
            for chunk in stream_sse(url, payload, label="Gemini"):
                chunk_count += 1
                candidates = chunk.get("candidates") or []
                if candidates:
                    cand0 = candidates[0] or {}
                    content_obj = cand0.get("content") or {}
                    for part in content_obj.get("parts") or []:
                        text_piece = part.get("text")
                        if text_piece:
                            parts.append(text_piece)
                    fr = cand0.get("finishReason")
                    if fr:
                        finish_reason = {
                            "STOP": "stop",
                            "MAX_TOKENS": "length",
                            "SAFETY": "content_filter",
                            "RECITATION": "content_filter",
                            "OTHER": "stop",
                        }.get(fr, str(fr).lower())
                usage = chunk.get("usageMetadata") or {}
                if usage:
                    usage_tokens = int(
                        usage.get("promptTokenCount", 0)
                        + usage.get("candidatesTokenCount", 0)
                    )
                now = time.time()
                if now - last_heartbeat >= 5.0:
                    _log(
                        f"[Gemini:streaming] model={self.config.model} "
                        f"chunks={chunk_count} chars={sum(len(p) for p in parts)}"
                    )
                    last_heartbeat = now
        except RateLimitError as e:
            raise RuntimeError(f"Gemini rate limit: {e}") from e
        except (ServerError, HttpError) as e:
            raise RuntimeError(f"Gemini HTTP error: {e}") from e

        content = "".join(parts).strip()
        _log(
            f"[Gemini:done] model={self.config.model} content_len={len(content)} "
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
        return "gemini"
