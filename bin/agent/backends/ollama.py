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
import time
from typing import Any, Dict, List, Optional, Tuple

import requests

from bin.common.backends.backend_base import ModelBackend
from bin.common.backends.http_client import (
    HttpError,
    RateLimitError,
    ServerError,
    stream_ndjson,
)
from bin.common.utils.text import sanitize_for_agent


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
        _log(
            f"[Ollama:init] model={self.model_id} base_url={self.base_url} "
            f"num_ctx={self.num_ctx}"
        )

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
    # Prompt assembly: messages -> single prompt + system string
    # ------------------------------------------------------------------

    @staticmethod
    def _build_prompt_and_system(
        messages: List[Dict[str, Any]],
    ) -> Tuple[str, str]:
        """Render OpenAI-style chat messages into the prompt + system
        pair expected by ``/api/generate``.
        """
        system_chunks: List[str] = []
        body: List[str] = []
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
                system_chunks.append(content)
            elif role == "user":
                body.append(f"User: {content}")
            elif role == "assistant":
                body.append(f"Assistant: {content}")
            else:
                # tool, function, etc. -- pass through as user context.
                body.append(f"[{role}] {content}")
        # Final cue so the model continues as the assistant.
        body.append("Assistant:")
        return "\n\n".join(body), "\n\n".join(system_chunks)

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
    ) -> Tuple[str, str]:
        # [native-tools-removed] tools=... never forwarded.
        _ = tools

        messages = sanitize_for_agent(messages)
        prompt, system = self._build_prompt_and_system(messages)

        options: Dict[str, Any] = {
            "temperature": temperature,
            "num_predict": max_tokens,
        }
        if not self._is_cloud_host():
            options["num_ctx"] = self.num_ctx
        if stop:
            options["stop"] = list(stop)

        payload: Dict[str, Any] = {
            "model": self.model_id,
            "prompt": prompt,
            "stream": True,
            "options": options,
        }
        if system:
            payload["system"] = system

        _log(
            f"[Ollama:chat] POST {self.base_url}/api/generate model={self.model_id} "
            f"msgs={len(messages)} max_tokens={max_tokens} temperature={temperature} "
            f"cloud={self._is_cloud_host()} stop={options.get('stop')}"
        )

        parts: List[str] = []
        finish_reason = "stop"
        chunk_count = 0
        last_heartbeat = time.time()

        try:
            for chunk in stream_ndjson(
                f"{self.base_url}/api/generate",
                payload,
                headers=self._auth_headers(),
                label="Ollama",
                timeout=(15.0, 600.0),
            ):
                chunk_count += 1
                piece = chunk.get("response") or ""
                if piece:
                    parts.append(piece)
                if chunk.get("done"):
                    finish_reason = chunk.get("done_reason") or "stop"
                    # Best-effort usage accounting.
                    self.last_usage_tokens = int(
                        chunk.get("prompt_eval_count", 0) + chunk.get("eval_count", 0)
                    )
                now = time.time()
                if now - last_heartbeat >= 5.0:
                    _log(
                        f"[Ollama:streaming] model={self.model_id} "
                        f"chunks={chunk_count} chars={sum(len(p) for p in parts)}"
                    )
                    last_heartbeat = now
        except RateLimitError as e:
            raise RuntimeError(f"Ollama rate limit: {e}") from e
        except (ServerError, HttpError) as e:
            raise RuntimeError(f"Ollama HTTP error: {e}") from e

        content = "".join(parts)
        _log(
            f"[Ollama:done] model={self.model_id} content_len={len(content)} "
            f"finish_reason={finish_reason!r} chunks={chunk_count}"
        )
        return content, finish_reason
