"""Local / cloud Ollama backend via the official `ollama` Python library.

Uses `/api/generate` (not `/api/chat`) so the same endpoint works for
both raw-completion and chat-formatted requests.  The `messages` list is
converted into a single `prompt` string + optional `system` field.
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any, Dict, List, Optional

from .backend_base import ModelBackend
from ..utils.text import sanitize_for_agent


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


class OllamaBackend(ModelBackend):
    """
    Talks to a local or cloud Ollama endpoint via the official `ollama`
    Python library.  Streaming is used so every incoming token chunk acts
    as a natural heartbeat — no separate thread needed.

    Local daemon:  OllamaBackend(model_id="phi3:mini")
    Cloud (ollama.com): OllamaBackend(model_id="gpt-oss:120b-cloud",
                            api_key="<your key>")
        — base_url auto-promotes to https://ollama.com when the model tag
        ends with '-cloud' and the URL is left at the local default.
    """

    # Context window cap. Small models (phi3:mini, llama3.2) ship Modelfiles
    # with num_ctx=128K which blows KV-cache RAM to tens of GiB.  32768 is a
    # safe default that fits the system prompt + several read_file results
    # and gives repo-analysis conversations enough headroom.
    DEFAULT_NUM_CTX = 32768
    DEFAULT_LOCAL_URL = "http://localhost:11434"
    CLOUD_URL = "https://ollama.com"

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _is_cloud_model_id(model_id: str) -> bool:
        model = (model_id or "").strip().lower()
        if not model:
            return False
        if ":" in model:
            tag = model.rsplit(":", 1)[1]
            if tag == "cloud" or tag.endswith("-cloud"):
                return True
        return model.endswith("-cloud")

    @staticmethod
    def _hostname_for(url: str) -> str:
        if not url:
            return ""
        try:
            from urllib.parse import urlparse

            parsed = urlparse(url if "://" in url else f"http://{url}")
            return (parsed.hostname or "").lower()
        except Exception:
            return ""

    @classmethod
    def _is_local_host(cls, url: str) -> bool:
        return cls._hostname_for(url) in {"localhost", "127.0.0.1", "::1"}

    @classmethod
    def _is_cloud_host(cls, url: str) -> bool:
        host = cls._hostname_for(url)
        return host == "ollama.com" or host.endswith(".ollama.com")

    # ------------------------------------------------------------------
    # Init
    # ------------------------------------------------------------------

    def __init__(
        self,
        model_id: str,
        base_url: str = DEFAULT_LOCAL_URL,
        num_ctx: int = DEFAULT_NUM_CTX,
        api_key: str = "",
    ):
        if not model_id:
            raise RuntimeError(
                "Ollama backend requires --model (e.g. 'qwen2.5-coder:7b')."
            )
        from ollama import Client  # noqa: PLC0415

        self.model_id = model_id
        base_url = base_url.rstrip("/")

        is_cloud_model = self._is_cloud_model_id(model_id)
        if is_cloud_model and base_url == self.DEFAULT_LOCAL_URL:
            base_url = self.CLOUD_URL
            _log(
                f"[Ollama:init] '{model_id}' is a cloud-tagged model; "
                f"routing to {base_url}."
            )

        self.base_url = base_url
        self.num_ctx = num_ctx
        self.api_key = api_key.strip() or os.environ.get("OLLAMA_API_KEY", "").strip()

        if self._is_cloud_host(self.base_url) and not self.api_key:
            raise RuntimeError(
                "Ollama cloud endpoint requires an API key. Pass "
                "--ollama-api-key or set OLLAMA_API_KEY in the environment."
            )
        if self._is_cloud_host(self.base_url) and self.api_key.lower().startswith(
            "ssh-"
        ):
            raise RuntimeError(
                "The configured Ollama API key looks like an SSH public key "
                "(starts with 'ssh-'). Use an API key from "
                "https://ollama.com/settings/keys for direct ollama.com access."
            )

        client_kwargs: Dict[str, Any] = {"host": self.base_url}
        if self.api_key:
            client_kwargs["headers"] = {"Authorization": f"Bearer {self.api_key}"}
        self._client: Any = Client(**client_kwargs)

        self._tools_unsupported: bool = False

        _log(
            f"[Ollama:init] model={model_id} base_url={self.base_url} "
            f"num_ctx={num_ctx} cloud_model={is_cloud_model} "
            f"has_api_key={bool(self.api_key)}"
        )

    @property
    def context_limit(self) -> int:
        return int(self.num_ctx)

    # ------------------------------------------------------------------
    # Health check
    # ------------------------------------------------------------------

    def health_check(self) -> None:
        """Raise RuntimeError with a clear message if the endpoint or model
        is unreachable. Called once at startup for fast-fail feedback."""
        from ollama import ResponseError  # noqa: PLC0415

        _log(
            f"[Ollama:health_check] checking {self.base_url} for model={self.model_id}"
        )
        try:
            result = self._client.list()
        except ResponseError as e:
            _log(
                f"[Ollama:health_check_error] ResponseError status={e.status_code} error={e.error}"
            )
            raise RuntimeError(
                f"Ollama returned error {e.status_code} for {self.base_url}: "
                f"{e.error}. Check your API key or server address."
            ) from e
        except Exception as e:
            _log(f"[Ollama:health_check_error] {type(e).__name__}: {e}")
            raise RuntimeError(
                f"Cannot reach Ollama at {self.base_url}: {e}. "
                f"Start the daemon from Settings -> Ollama, or run "
                f"`ollama serve` in a terminal."
            ) from e

        is_cloud = not self._is_local_host(self.base_url)
        if is_cloud:
            _log(
                f"[Ollama:health_check_ok] cloud endpoint — skipping model presence check"
            )
            return

        models = getattr(result, "models", []) or []
        names = set()
        for m in models:
            name = getattr(m, "model", None) or getattr(m, "name", None)
            if name:
                names.add(name)

        bare = self.model_id.split(":", 1)[0]
        if self.model_id not in names and not any(
            (n or "").split(":", 1)[0] == bare for n in names
        ):
            installed = ", ".join(sorted(n for n in names if n)) or "(none)"
            _log(
                f"[Ollama:health_check_missing] model={self.model_id!r} "
                f"not in installed={installed}"
            )
            raise RuntimeError(
                f"Ollama does not have model '{self.model_id}' installed. "
                f"Installed: {installed}. Pull it with "
                f"`ollama pull {self.model_id}` or pick an installed tag."
            )

        _log(f"[Ollama:health_check_ok] model={self.model_id!r} found locally")

    # ------------------------------------------------------------------
    # Hint builder
    # ------------------------------------------------------------------

    @staticmethod
    def _build_hint_for(err_msg: str) -> str:
        """Turn a cryptic Ollama error body into user-actionable advice."""
        low = (err_msg or "").lower()
        if "not found" in low or "try pulling" in low or "no such model" in low:
            return (
                "\n-> Model is not installed. Pull it from Settings -> Ollama "
                "or run `ollama pull <model>`."
            )
        if "memory" in low and ("gib" in low or "gb" in low):
            return (
                "\n-> Model needs more RAM than is free. Pick a smaller tag "
                "(e.g. phi3:mini, llama3.2:3b, qwen2.5:1.5b), lower "
                "--ollama-num-ctx, or close other apps."
            )
        if "unauthorized" in low or "401" in low:
            return (
                "\n-> Direct ollama.com API access requires a valid API key "
                "from https://ollama.com/settings/keys "
                "(not an SSH public key). "
                "Alternative: use http://localhost:11434 and authenticate via "
                "`ollama signin`."
            )
        if "context" in low and ("too large" in low or "exceed" in low):
            return (
                "\n-> Prompt exceeded the model's context window. "
                "Start a new chat to clear history."
            )
        if "internal server error" in low:
            return (
                "\n-> Ollama returned a generic 500. For cloud-tagged models "
                "(':cloud' or ':<size>-cloud') make sure you're signed in via "
                "`ollama signin`, and that the model supports the features "
                "being requested (some cloud models don't accept tools or "
                "custom num_ctx)."
            )
        return ""

    # ------------------------------------------------------------------
    # Prompt builder  (messages → prompt + system)
    # ------------------------------------------------------------------

    @staticmethod
    def _build_prompt_and_system(
        messages: List[Dict[str, Any]],
    ) -> tuple[str, str]:
        """Convert a chat `messages` list into a single `prompt` string
        and an optional `system` string suitable for `/api/generate`."""
        system_parts: List[str] = []
        prompt_parts: List[str] = []

        for m in messages:
            role = (m.get("role") or "").strip().lower()
            content = m.get("content", "") or ""
            if role == "system":
                system_parts.append(content)
            elif role == "user":
                prompt_parts.append(f"User: {content}")
            elif role == "assistant":
                prompt_parts.append(f"Assistant: {content}")
            else:
                # Unknown role — treat as user.
                prompt_parts.append(f"User: {content}")

        system = "\n\n".join(system_parts)
        prompt = "\n".join(prompt_parts)
        if prompt_parts:
            prompt += "\nAssistant:"
        return prompt, system

    # ------------------------------------------------------------------
    # Chat  (via /api/generate)
    # ------------------------------------------------------------------

    def chat(
        self,
        messages: List[Dict[str, Any]],
        max_tokens: int,
        temperature: float,
        tools: Optional[List[Dict[str, Any]]] = None,
    ) -> tuple[str, str]:
        return self._chat_impl(messages, max_tokens, temperature, tools)

    def _chat_impl(
        self,
        messages: List[Dict[str, Any]],
        max_tokens: int,
        temperature: float,
        tools: Optional[List[Dict[str, Any]]] = None,
    ) -> tuple[str, str]:
        from ollama import ResponseError  # noqa: PLC0415

        messages = sanitize_for_agent(messages)
        tools = sanitize_for_agent(tools)

        effective_tools = None if self._tools_unsupported else tools
        n_tools = len(effective_tools) if effective_tools else 0

        is_cloud_model = self._is_cloud_model_id(self.model_id) or self._is_cloud_host(
            self.base_url
        )

        prompt, system = self._build_prompt_and_system(messages)

        _log(
            f"[Ollama:chat] POST {self.base_url}/api/generate model={self.model_id} msgs={len(messages)} "
            f"tools={n_tools} max_tokens={max_tokens} temperature={temperature} "
            f"cloud={is_cloud_model} tools_unsupported={self._tools_unsupported} "
            f"prompt={prompt[:200]!r}"
            + (" [sending without tools]" if self._tools_unsupported and tools else "")
        )

        if is_cloud_model:
            generate_options: Dict[str, Any] = {
                "temperature": temperature,
                "num_predict": max_tokens,
            }
        else:
            generate_options = {
                "temperature": temperature,
                "num_predict": max_tokens,
                "num_ctx": self.num_ctx,
            }

        generate_kwargs: Dict[str, Any] = dict(
            model=self.model_id,
            prompt=prompt,
            stream=True,
            options=generate_options,
        )
        if system:
            generate_kwargs["system"] = system
        # The ollama Python library's generate() does NOT accept a 'tools'
        # kwarg (only chat() does).  When tools are requested we must use
        # the text protocol — tool definitions are already in the system
        # prompt, so the model can emit <tool>...</tool> tags directly.
        if effective_tools:
            _log(
                "[Ollama:tools_via_text] generate() does not support native "
                "tools; relying on text protocol (<tool> tags in prompt)"
            )
            self._tools_unsupported = True
            effective_tools = None

        try:
            parts: List[str] = []
            finish_reason = ""
            chunk_count = 0
            native_calls: List[Any] = []

            stream = self._client.generate(**generate_kwargs)

            for chunk in stream:
                content = chunk.response or ""
                if content:
                    parts.append(content)

                tcs = getattr(chunk, "tool_calls", None) or []
                native_calls.extend(sanitize_for_agent(tcs))

                chunk_count += 1
                if chunk_count % 20 == 1:
                    so_far = len("".join(parts))
                    tail = "".join(parts)[-80:]
                    if so_far > 0:
                        _log(
                            f"[Ollama:streaming] model={self.model_id} "
                            f"chunks={chunk_count} chars={so_far} tail={tail!r}"
                        )
                    else:
                        # Show progress dots when waiting for first content
                        dots = "." * (chunk_count // 20)
                        _log(
                            f"[Ollama:streaming] model={self.model_id} "
                            f"chunks={chunk_count} waiting{dots}"
                        )
                # else: no output for non-milestone chunks to avoid log spam

                if getattr(chunk, "done", False):
                    finish_reason = getattr(chunk, "done_reason", "") or ""

            _log(
                f"[Ollama:stream_done] model={self.model_id} "
                f"total_chunks={chunk_count} content_len={len(''.join(parts))} "
                f"tool_calls={len(native_calls)} finish_reason={finish_reason!r}"
            )

            if native_calls:
                _log(
                    f"[Ollama:tool_calls] converting {len(native_calls)} native call(s) to <tool> tags"
                )
                tag_lines: List[str] = []
                for tc in native_calls:
                    fn = getattr(tc, "function", tc)
                    name = getattr(fn, "name", None)
                    args = getattr(fn, "arguments", {}) or {}
                    args = sanitize_for_agent(args)
                    if isinstance(args, str):
                        try:
                            args = json.loads(args)
                        except json.JSONDecodeError as exc:
                            _log(
                                f"[Ollama:tool_call_parse_error] args JSON decode failed: {exc} raw={args!r:.80}"
                            )
                            args = {}
                    if not name:
                        _log(
                            f"[Ollama:tool_call_skip] tool call has no name — skipping"
                        )
                        continue
                    tag_lines.append(
                        f"<tool>{json.dumps({'tool': name, 'parameters': args}, ensure_ascii=False)}</tool>"
                    )
                    _log(
                        f"[Ollama:tool_call] {name}({json.dumps(args, ensure_ascii=False)[:200]})"
                    )

                if tag_lines:
                    return "\n".join(tag_lines), finish_reason

            result = "".join(parts).strip()
            _log(
                f"[Ollama:done] returning content ({len(result)} chars) finish_reason={finish_reason!r}"
            )
            return result, finish_reason

        except ResponseError as e:
            err_str = str(getattr(e, "error", e))
            status = getattr(e, "status_code", 0)
            low = err_str.lower()

            _log(
                f"[Ollama:response_error] model={self.model_id} status={status} "
                f"error={err_str!r} tools_attached={bool(effective_tools)}"
            )

            is_cloud = self._is_cloud_model_id(self.model_id) or self._is_cloud_host(
                self.base_url
            )
            tools_likely_unsupported = effective_tools and (
                (status == 400 and "does not support tools" in low)
                or (is_cloud and "internal server error" in low)
            )

            if tools_likely_unsupported:
                reason = (
                    "explicitly unsupported (400)"
                    if status == 400
                    else "500 from cloud endpoint — likely tools-incompatible"
                )
                _log(
                    f"[Ollama:tools_unsupported] model={self.model_id} reason={reason} "
                    f"— disabling native tools, retrying with text protocol"
                )
                self._tools_unsupported = True
                return self._chat_impl(messages, max_tokens, temperature, tools=tools)

            hint = self._build_hint_for(err_str)
            raise RuntimeError(f"Ollama error {status}: {err_str}{hint}") from e

        except Exception as e:
            _log(f"[Ollama:error] model={self.model_id} {type(e).__name__}: {e}")
            raise RuntimeError(f"Ollama error: {e}") from e
