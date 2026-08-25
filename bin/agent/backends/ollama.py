"""Ollama backend (single-agent mode) -- pure REST.

Talks to a local Ollama daemon (``http://localhost:11434`` by default)
or to the Ollama cloud endpoint (``https://ollama.com``, auto-promoted
when the model tag ends with ``-cloud``) via plain HTTP POST to
``/api/generate``. NDJSON streaming so every chunk acts as a heartbeat.

No ``ollama`` SDK import: only :mod:`common.backends.http_client` +
``requests`` under the hood.

The orchestrator's tool protocol is purely textual (``<tool>...</tool>``
tags in the system prompt and model reply), so we never pass
``tools=[...]`` to ``/api/generate`` -- that's only supported by
``/api/chat`` anyway. See ``[native-tools-removed]`` in
``openai_compat.py`` for the design rationale.
"""

from __future__ import annotations

import sys
from typing import Any, Dict, List, Optional, Tuple

import requests
from agent.backends.backend_base import ModelBackend
from agent.backends.http_client import (
    HttpError,
    RateLimitError,
    ServerError,
    stream_ndjson,
)


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


class OllamaBackend(ModelBackend):
    """Ollama via plain REST POST to ``/api/generate``."""

    # Modelfiles often advertise num_ctx=128K which blows KV-cache RAM
    # into double-digit GiB. 32K is a safe headroom for typical
    # repo-analysis sessions.
    DEFAULT_NUM_CTX = 32768
    DEFAULT_LOCAL_URL = "http://localhost:11434"
    CLOUD_URL = "https://ollama.com"

    # ------------------------------------------------------------------
    # Construction
    # ------------------------------------------------------------------

    def __init__(
            self,
            model_id: str,
            base_url: str = "",
            api_key: str = "",
            num_ctx: int = DEFAULT_NUM_CTX,
    ):
        if not model_id:
            raise RuntimeError("OllamaBackend requires a model_id.")
        self.model_id = model_id
        self.api_key = (api_key or "").strip()
        self.num_ctx = int(num_ctx)
        # Auto-promote to the cloud endpoint when the user asked for a
        # *-cloud model but left base_url at the local default (or empty).
        url_in = (base_url or "").strip()
        if not url_in or url_in == self.DEFAULT_LOCAL_URL:
            if self._is_cloud_model_id(model_id):
                url_in = self.CLOUD_URL
            else:
                url_in = self.DEFAULT_LOCAL_URL
        self.base_url = url_in.rstrip("/")
        self.last_usage_tokens: int = 0
        # Raw prompt_eval_count from the most recent /api/generate response.
        # This is the actual number of input tokens the model processed —
        # the real context window used. Exposed so the orchestrator can
        # dynamically clamp its self budget to match reality when
        # --auto-num-ctx is active.
        self.last_prompt_eval_count: int = 0
        _log(
            f"[Ollama:init] model={self.model_id} base_url={self.base_url} "
            f"num_ctx={self.num_ctx}"
        )

    # ------------------------------------------------------------------
    # Context window
    # ------------------------------------------------------------------

    @property
    def context_limit(self) -> int:
        """Return the actual context window configured for this Ollama
        backend (``num_ctx``).

        The ``ModelBackend`` base falls back to a model-id lookup table
        when this is not overridden, which only knows a fixed catalog
        (Llama / Gemma / Qwen / Claude / GPT-* / ...) and returns 8192
        for unknown models like ``nemotron-3-ultra``. That undersizes
        the orchestrator's self budget to ~7K tokens on what is
        actually a 256K context window and triggers spurious self
        trimming on the very first turn. Returning ``num_ctx`` here
        gives the orchestrator the real number.
        """
        return int(self.num_ctx)

    @staticmethod
    def _is_cloud_model_id(model_id: str) -> bool:
        m = (model_id or "").strip().lower()
        if not m:
            return False
        if ":" in m:
            tag = m.rsplit(":", 1)[1]
            if tag == "cloud" or tag.endswith("-cloud"):
                return True
        return m.endswith("-cloud")

    def _is_cloud_host(self) -> bool:
        return self.base_url.startswith(self.CLOUD_URL)

    @staticmethod
    def _map_thinking_to_think(thinking: bool, effort: Optional[str]) -> Optional[Any]:
        """Map the generic ``thinking`` + ``effort`` knobs to Ollama's
        ``think`` parameter.

        Ollama thinking models accept either a boolean or one of
        ``low`` / ``medium`` / ``high`` / ``max``. GPT-OSS ignores
        booleans and requires a level.

        * thinking=False  -> ``None`` (omit the field; many cloud models
          silently fail when ``think: false`` is sent explicitly).
        * thinking=True   -> use ``effort`` if provided, else ``True``.
        * effort values are normalised to the supported level set.
        """
        if not thinking:
            return None
        if effort:
            level = str(effort).lower()
            if level in {"minimal", "low", "medium", "high", "max"}:
                # "minimal" is not a documented Ollama level; collapse it to low.
                return "low" if level == "minimal" else level
        return True

    @staticmethod
    def _is_thinking_capable_model(model_id: str) -> bool:
        """Heuristic: some models are known to require/expect a think level."""
        m = (model_id or "").lower()
        return any(k in m for k in (
            "gpt-oss", "deepseek-r1", "deepseek-v3.1", "qwen3", "qwq",
            "kimi", "k2.7",
        ))

    def _maybe_add_think(
            self, payload: Dict[str, Any], thinking: bool, effort: Optional[str]
    ) -> None:
        """Set Ollama's ``think`` field so it always matches the caller's
        ``thinking`` parameter.

        ``thinking=True``  -> add ``think`` to the payload.
        ``thinking=False`` -> remove ``think`` from the payload so a stale
        or model-side default cannot turn thinking back on.

        This used to omit the field for ``thinking=False`` to avoid cloud
        endpoints that reject ``think: false``.  That is wrong: leaving
        the key out lets a hardcoded default (or a model-side default)
        enable thinking even when the caller explicitly asked for a
        plain-text call.  The synthesis path in particular passes
        ``thinking=False`` and must not run chain-of-thought.
        """
        if not thinking:
            payload.pop("think", None)
            return

        think_value = self._map_thinking_to_think(thinking, effort)
        if think_value is not None:
            payload["think"] = think_value

    def _auth_headers(self) -> Dict[str, str]:
        if self.api_key:
            return {"Authorization": f"Bearer {self.api_key}"}
        return {}

    # ------------------------------------------------------------------
    # Health probe (used by orchestrator startup for the local daemon)
    # ------------------------------------------------------------------

    def health_check(self) -> None:
        """Best-effort GET ``/api/tags`` to confirm the daemon answers."""
        try:
            resp = requests.get(
                f"{self.base_url}/api/tags",
                headers=self._auth_headers(),
                timeout=(5.0, 5.0),
            )
            resp.raise_for_status()
        except requests.RequestException as e:
            raise RuntimeError(f"Ollama health check failed at {self.base_url}: {e}") from e

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
            on_thinking=None,
    ) -> Tuple[str, str]:
        # [native-tools-removed] tools=... never forwarded.
        # Ollama supports a `think` field on /api/generate for thinking-capable
        # models (Qwen 3, GPT-OSS, DeepSeek-v3.1, DeepSeek R1, etc.). Most
        # models accept booleans (true/false) or levels (low/medium/high/max).
        # GPT-OSS only accepts levels. We map the frontend `thinking` master
        # switch and `effort` string to that field.
        _ = tools

        # Centralized sanitization: ConversationHistory.sanitize() strips
        # null bytes and lone surrogates in-place. No per-backend
        # sanitize_for_agent() call needed.
        conversation.sanitize()

        # Build the prompt + system from the ConversationHistory directly.
        # The history object owns the system/turns separation, so there's
        # no need to re-parse a flat message list.
        prompt = conversation.to_prompt()
        system = conversation.system_text()
        msg_count = len(conversation.turns)

        # _log(f"prompt={prompt} ")
        # _log(f"system={system} ")

        options: Dict[str, Any] = {
            "temperature": temperature,
            "num_predict": max_tokens,
            "num_ctx": self.num_ctx,
            "stop" : list(stop) if stop else None
        }

        # if stop:
        #     options["stop"] = list(stop)

        payload: Dict[str, Any] = {
            "model": self.model_id,
            "prompt": prompt,
            "keep_alive": "20m",
            "options": options,
            "system": system if system else None,
            "stream": False,
        }

        # if system:
        #     payload["system"] = system

        # Map thinking/effort to Ollama's `think` field safely.
        # Do NOT hardcode "think": True in the payload above — that
        # would survive _maybe_add_think when thinking=False (the
        # synthesis path), because _maybe_add_think only OVERWRITES
        # the key when think_value is not None, never removes it.
        # The hardcoded True caused the synthesis call to run with
        # thinking enabled, which ate the token budget on CoT and
        # produced a fragmentary tool call as the "final answer."
        self._maybe_add_think(payload, thinking, effort)

        _log(
            f"[Ollama:generate] POST {self.base_url}/api/generate model={self.model_id} "
            f"turns={msg_count} max_tokens={max_tokens} num_ctx={self.num_ctx} "
            f"temperature={temperature} "
            f"cloud={self._is_cloud_host()} stop={options.get('stop')} "
            f"think={payload.get('think')}"
        )

        # chunk_count = 0
        # last_heartbeat = time.time()

        parts: List[str] = []
        finish_reason = "stop"

        try:
            for chunk in stream_ndjson(
                    f"{self.base_url}/api/generate",
                    payload,
                    headers=self._auth_headers(),
                    label="Ollama",
                    timeout=(15.0, 600.0),
            ):
                # chunk_count += 1
                piece = chunk.get("response") or ""
                thinking = chunk.get("thinking") or ""

                if thinking:
                    _log(f"[Ollama:streaming] \nmodel={self.model_id} \nthinking={thinking}  \npiece={piece} ")
                    # Deepseek-style models emit ":"-only chunks between
                    # reasoning phases and prefix real reasoning with a lone
                    # colon. Drop pure-noise chunks and strip the leading
                    # colon so the UI keeps showing the last real thinking.
                    cleaned = thinking.strip()
                    if cleaned and cleaned != ":":
                        if cleaned.startswith(":"):
                            cleaned = cleaned[1:].strip()
                        if cleaned and on_thinking is not None:
                            on_thinking(cleaned)
                if piece:
                    parts.append(piece)
                if chunk.get("done"):
                    finish_reason = chunk.get("done_reason") or "stop"
                    # Best-effort usage accounting.
                    self.last_usage_tokens = int(
                        chunk.get("prompt_eval_count", 0) + chunk.get("eval_count", 0)
                    )
                    # Capture the raw input token count so the orchestrator
                    # can auto-calibrate its self budget (--auto-num-ctx).
                    self.last_prompt_eval_count = int(
                        chunk.get("prompt_eval_count", 0)
                    )
                # now = time.time()
                # if now - last_heartbeat >= 5.0:
                #     _log(
                #         f"[Ollama:streaming] model={self.model_id} "
                #         f"chunks={chunk_count} chars={sum(len(p) for p in parts)}"
                #     )
                #     last_heartbeat = now

        except RateLimitError as e:
            raise RuntimeError(f"Ollama rate limit: {e}") from e
        except (ServerError, HttpError) as e:
            raise RuntimeError(f"Ollama HTTP error: {e}") from e

        content = "".join(parts)

        _log(f"[Ollama:done]  finish_reason={finish_reason!r}")

        return content, finish_reason
