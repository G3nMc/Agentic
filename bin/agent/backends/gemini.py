"""Google Gemini backend (single-agent mode) -- pure REST.

Talks to ``https://generativelanguage.googleapis.com/v1beta`` directly
via HTTP POST. SSE streaming (``alt=sse``) so every chunk acts as a
heartbeat for the Flutter inactivity watchdog.

No ``google-genai`` / ``google-generativeai`` SDK imports.

Tool protocol is text-only (``<tool>...</tool>`` in the system prompt),
so we never send ``tools=[...]`` to ``generateContent``. See
``[native-tools-removed]`` in ``openai_compat.py`` for the rationale.
"""

from __future__ import annotations

import sys
import time
from typing import Any, Dict, List, Optional, Tuple

from bin.common.backends.backend_base import ModelBackend
from bin.common.backends.http_client import (
    HttpError,
    RateLimitError,
    ServerError,
    stream_sse,
)
from bin.common.utils.text import sanitize_for_agent


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


class GeminiBackend(ModelBackend):
    """Google AI Studio / Gemini Cloud over plain REST."""

    DEFAULT_MODEL = "gemini-2.5-flash"
    DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

    def __init__(self, api_key: str, model_id: str = "", base_url: str = ""):
        if not api_key:
            raise RuntimeError("GeminiBackend requires an api_key.")
        self.api_key = api_key
        self.model_id = model_id or self.DEFAULT_MODEL
        self.base_url = (base_url or self.DEFAULT_BASE_URL).rstrip("/")
        self.last_usage_tokens: int = 0
        _log(f"[Gemini:init] model={self.model_id} base_url={self.base_url}")

    # ------------------------------------------------------------------
    # Message conversion: OpenAI-style chat -> Gemini contents/system
    # ------------------------------------------------------------------

    @staticmethod
    def _to_contents(
        messages: List[Dict[str, Any]],
    ) -> Tuple[str, List[Dict[str, Any]]]:
        """Return ``(system_instruction, contents)``.

        Gemini does NOT have an "assistant" role: it expects ``user`` and
        ``model``. System prompts are passed separately via
        ``systemInstruction``. Tool / function roles are mapped to
        ``user`` parts so context isn't lost.
        """
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
            contents.append(
                {"role": gemini_role, "parts": [{"text": content}]}
            )
        return "\n\n".join(system_parts), contents

    # ------------------------------------------------------------------
    # ModelBackend.chat
    # ------------------------------------------------------------------

    def chat(
        self,
        messages: List[Dict[str, Any]],
        max_tokens: int,
        temperature: float,
        tools: Optional[List[Dict[str, Any]]] = None,
        stop: Optional[List[str]] = None,
        thinking: bool = False,
        effort: Optional[str] = None,
    ) -> Tuple[str, str]:
        # [native-tools-removed] We never forward function declarations.
        _ = tools

        messages = sanitize_for_agent(messages)
        system_instruction, contents = self._to_contents(messages)

        generation_config: Dict[str, Any] = {
            "temperature": temperature,
            "maxOutputTokens": max_tokens,
        }
        if stop:
            generation_config["stopSequences"] = list(stop)

        payload: Dict[str, Any] = {
            "contents": contents,
            "generationConfig": generation_config,
        }
        # Thinking + Effort: when thinking is ON, map effort to
        # Gemini thinkingConfig.thinkingBudget.
        if thinking and effort:
            effort_str = str(effort).lower()
            budget_map = {
                "minimal": 512,
                "low": 1024,
                "medium": 2048,
                "high": 4096,
                "max": 8192,
            }
            budget = budget_map.get(effort_str, 8192)
            payload["thinkingConfig"] = {"thinkingBudget": budget}
        if system_instruction:
            payload["systemInstruction"] = {
                "parts": [{"text": system_instruction}]
            }

        url = (
            f"{self.base_url}/models/{self.model_id}:streamGenerateContent"
            f"?alt=sse&key={self.api_key}"
        )

        _log(
            f"[Gemini:chat] POST {self.base_url}/models/{self.model_id}:streamGenerateContent "
            f"msgs={len(contents)} system={bool(system_instruction)} "
            f"max_tokens={max_tokens} temperature={temperature} stop={generation_config.get('stopSequences')}"
        )

        parts: List[str] = []
        finish_reason = "stop"
        chunk_count = 0
        last_heartbeat = time.time()
        prompt_tokens = 0
        candidates_tokens = 0

        try:
            for chunk in stream_sse(
                url,
                payload,
                label="Gemini",
                timeout=(15.0, 600.0),
            ):
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
                        # Map Gemini's enum to OpenAI-style finish reasons.
                        finish_reason = {
                            "STOP": "stop",
                            "MAX_TOKENS": "length",
                            "SAFETY": "content_filter",
                            "RECITATION": "content_filter",
                            "OTHER": "stop",
                        }.get(fr, str(fr).lower())
                usage = chunk.get("usageMetadata") or {}
                if usage:
                    prompt_tokens = int(usage.get("promptTokenCount", 0) or 0)
                    candidates_tokens = int(usage.get("candidatesTokenCount", 0) or 0)
                now = time.time()
                if now - last_heartbeat >= 5.0:
                    _log(
                        f"[Gemini:streaming] model={self.model_id} "
                        f"chunks={chunk_count} chars={sum(len(p) for p in parts)}"
                    )
                    last_heartbeat = now
        except RateLimitError as e:
            raise RuntimeError(f"Gemini rate limit: {e}") from e
        except (ServerError, HttpError) as e:
            raise RuntimeError(f"Gemini HTTP error: {e}") from e

        content = "".join(parts).strip()
        self.last_usage_tokens = prompt_tokens + candidates_tokens
        _log(
            f"[Gemini:done] model={self.model_id} content_len={len(content)} "
            f"finish_reason={finish_reason!r} chunks={chunk_count} "
            f"usage_tokens={self.last_usage_tokens}"
        )
        return content, finish_reason
