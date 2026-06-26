"""Ollama backend for multi_mode -- pure REST.

Talks to ``/api/chat`` (chat-formatted messages) via NDJSON streaming
through :mod:`common.backends.http_client`. No SDK import.
"""

from __future__ import annotations

import re
import sys
import time
from collections import Counter
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


# Minimum phrase length and max allowed repetitions before we cut off
# streaming. Catches the "Let me check..." degenerate loop that small
# models (glm-5.x, qwen, etc.) fall into when confused.
_REP_MIN_PHRASE = 25
_REP_MAX_ALLOWED = 5
_REP_CHECK_INTERVAL = 1500  # check every N chars of accumulated text

# Regex that splits on sentence boundaries (period/exclamation/question
# followed by optional whitespace). Handles missing spaces too.
_SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s*")


def _detect_repetition(text: str) -> bool:
    """Return True when the accumulated text contains a phrase repeated
    more than ``_REP_MAX_ALLOWED`` times -- a clear sign the model is
    stuck in a generation loop (e.g. "Let me check..." x200)."""
    if len(text) < _REP_MIN_PHRASE * _REP_MAX_ALLOWED:
        return False
    sentences = _SENTENCE_SPLIT_RE.split(text)
    long = [s.strip() for s in sentences if len(s.strip()) >= _REP_MIN_PHRASE]
    if len(long) < _REP_MAX_ALLOWED:
        return False
    most_common_count = Counter(long).most_common(1)[0][1]
    return most_common_count >= _REP_MAX_ALLOWED


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
        # Ollama has no native reasoning parameter — reasoning_level is
        # silently ignored here (the field exists on ModelConfig for
        # cross-provider uniformity but has no effect on Ollama).

        _log(
            f"[Ollama:complete] POST {self._base_url}/api/chat model={self.config.model} "
            f"msgs={len(messages)} max_tokens={options['num_predict']} stop={options.get('stop')}"
        )

        parts: List[str] = []
        finish_reason = "stop"
        chunk_count = 0
        last_heartbeat = time.time()
        usage_tokens = 0
        total_chars = 0
        last_rep_check = 0  # char count at last repetition check
        repetition_detected = False

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
                    total_chars += len(piece)
                if chunk.get("done"):
                    finish_reason = chunk.get("done_reason") or "stop"
                    usage_tokens = int(
                        chunk.get("prompt_eval_count", 0)
                        + chunk.get("eval_count", 0)
                    )

                # Periodic repetition check: detect models stuck in a
                # generation loop ("Let me check..." x200). Checking
                # every _REP_CHECK_INTERVAL chars keeps overhead low.
                if (
                    total_chars - last_rep_check >= _REP_CHECK_INTERVAL
                    and total_chars >= _REP_MIN_PHRASE * _REP_MAX_ALLOWED
                ):
                    last_rep_check = total_chars
                    accumulated = "".join(parts)
                    if _detect_repetition(accumulated):
                        _log(
                            f"[Ollama:repetition] model={self.config.model} "
                            f"repetitive output detected at {total_chars} chars; "
                            f"stopping stream early."
                        )
                        repetition_detected = True
                        break

                now = time.time()
                if now - last_heartbeat >= 5.0:
                    _log(
                        f"[Ollama:streaming] model={self.config.model} "
                        f"chunks={chunk_count} chars={total_chars}"
                    )
                    last_heartbeat = now
        except RateLimitError as e:
            raise RuntimeError(f"Ollama rate limit: {e}") from e
        except (ServerError, HttpError) as e:
            raise RuntimeError(f"Ollama HTTP error: {e}") from e

        content = "".join(parts)

        # When repetition was detected, deduplicate: keep only the first
        # occurrence of the repeated phrase so downstream consumers get a
        # clean (short) output instead of the degenerate 38K blob.
        if repetition_detected and content:
            content = self._dedup_repetitive_content(content)
            finish_reason = "repetition_stopped"

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

    @staticmethod
    def _dedup_repetitive_content(text: str) -> str:
        """Strip repeated phrases from degenerate output.

        Keeps the first occurrence of each unique sentence and drops all
        subsequent duplicates, so "A.B.A.A.B." becomes "A.B.".
        """
        sentences = _SENTENCE_SPLIT_RE.split(text)
        seen: set = set()
        unique: List[str] = []
        for s in sentences:
            s_stripped = s.strip()
            if not s_stripped:
                continue
            if s_stripped in seen:
                continue
            seen.add(s_stripped)
            unique.append(s_stripped)
        result = ". ".join(unique)
        if result and not result.endswith("."):
            result += "."
        return result

    def count_tokens(self, text: str) -> int:
        return max(1, len(text) // 4)

    def supports_native_tools(self) -> bool:
        return False

    def get_tool_format(self) -> str:
        return "openai"
