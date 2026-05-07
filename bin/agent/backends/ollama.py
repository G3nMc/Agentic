"""Local / cloud Ollama backend via the official `ollama` Python library."""
from __future__ import annotations

# import json
import os
import sys
from typing import Any, Dict, List
from urllib.parse import urlparse

from .backend_base import ModelBackend
from ..utils.text import sanitize_for_agent


class OllamaBackend(ModelBackend):
    """
    Talks to a local or cloud Ollama endpoint via the official `ollama`
    Python library. Streaming is used so every incoming token chunk acts
    as a natural heartbeat — no separate thread needed.

    Local daemon:  OllamaBackend(model_id="phi3:mini")
    Cloud (ollama.com): OllamaBackend(model_id="gpt-oss:120b-cloud",
                            api_key="<your key>")
        — base_url auto-promotes to https://ollama.com when the model tag
        ends with '-cloud' and the URL is left at the local default.
    """

    # Context window cap. Small models (phi3:mini, llama3.2) ship Modelfiles
    # with num_ctx=128K which blows KV-cache RAM to tens of GiB. 8192 is a
    # safe default that fits the system prompt + several read_file results
    # and gives repo-analysis conversations enough headroom to avoid the
    # malformed-tool-call spiral that 4096 triggered on small models. Drop
    # to 4096 via --ollama-num-ctx if running a phi3:mini-class model on a
    # tight RAM budget; raise to 16384/32768 for 7B+ on >=16 GB or for
    # cloud-hosted backends where local KV cost is irrelevant.
    DEFAULT_NUM_CTX = 32768
    DEFAULT_LOCAL_URL = "http://localhost:11434"
    CLOUD_URL = "https://ollama.com"

    @staticmethod
    def _is_cloud_model_id(model_id: str) -> bool:
        model = (model_id or "").strip().lower()
        if not model:
            return False

        # Cloud tags can be either `<model>:cloud` or `<model>:<size>-cloud`.
        if ":" in model:
            tag = model.rsplit(":", 1)[1]
            if tag == "cloud" or tag.endswith("-cloud"):
                return True

        # Backward compatibility for model IDs ending in `-cloud` without
        # a conventional `:tag` suffix.
        return model.endswith("-cloud")

    @staticmethod
    def _hostname_for(url: str) -> str:
        if not url:
            return ""
        try:
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

        # Auto-route ':cloud' / '-cloud' tagged models to ollama.com when the
        # caller didn't override the URL. Saves users from having to pass
        # --ollama-base-url separately just because the model name says cloud.
        is_cloud_model = self._is_cloud_model_id(model_id)
        if is_cloud_model and base_url == self.DEFAULT_LOCAL_URL:
            base_url = self.CLOUD_URL
            print(
                f"[orch] '{model_id}' is a cloud-tagged model; "
                f"routing to {base_url}.",
                file=sys.stderr,
                flush=True,
            )

        self.base_url = base_url
        self.num_ctx = num_ctx
        self.api_key = api_key.strip() or os.environ.get("OLLAMA_API_KEY", "").strip()

        if self._is_cloud_host(self.base_url) and not self.api_key:
            raise RuntimeError(
                "Ollama cloud endpoint requires an API key. Pass "
                "--ollama-api-key or set OLLAMA_API_KEY in the environment."
            )
        if self._is_cloud_host(self.base_url) and self.api_key.lower().startswith("ssh-"):
            raise RuntimeError(
                "The configured Ollama API key looks like an SSH public key "
                "(starts with 'ssh-'). Use an API key from "
                "https://ollama.com/settings/keys for direct ollama.com access."
            )

        # Build a single Client instance reused for every request.
        # For cloud endpoints the README says to pass headers with Bearer token.
        client_kwargs: Dict[str, Any] = {"host": self.base_url}
        if self.api_key:
            client_kwargs["headers"] = {"Authorization": f"Bearer {self.api_key}"}
        self._client: Any = Client(**client_kwargs)

        # Set to True after the first 400 "does not support tools" error so
        # all subsequent calls skip the tools= parameter automatically.
        # Same pattern as GroqBackend._tools_unsupported.
        self._tools_unsupported: bool = False

    @property
    def context_limit(self) -> int:
        # Ollama runs the model with whatever num_ctx we passed in — that
        # IS the effective limit, regardless of what the model could handle
        # at a different num_ctx setting.
        return int(self.num_ctx)

    def health_check(self) -> None:
        """Raise RuntimeError with a clear message if the endpoint or model
        is unreachable. Called once at startup for fast-fail feedback."""
        from ollama import ResponseError  # noqa: PLC0415
        try:
            result = self._client.list()
        except ResponseError as e:
            raise RuntimeError(
                f"Ollama returned error {e.status_code} for {self.base_url}: "
                f"{e.error}. Check your API key or server address."
            ) from e
        except Exception as e:
            raise RuntimeError(
                f"Cannot reach Ollama at {self.base_url}: {e}. "
                f"Start the daemon from Settings -> Ollama, or run "
                f"`ollama serve` in a terminal."
            ) from e

        # For cloud endpoints list() may return cloud-hosted models that
        # haven't been "pulled" locally — skip the model-presence check when
        # we're clearly not talking to localhost.
        is_cloud = not self._is_local_host(self.base_url)
        if is_cloud:
            return

        models = getattr(result, "models", []) or []
        names = set()
        for m in models:
            name = getattr(m, "model", None) or getattr(m, "name", None)
            if name:
                names.add(name)

        # Match exact tag or base name (phi3 matches phi3:latest).
        bare = self.model_id.split(":", 1)[0]
        if self.model_id not in names and not any(
                (n or "").split(":", 1)[0] == bare for n in names
        ):
            installed = ", ".join(sorted(n for n in names if n)) or "(none)"
            raise RuntimeError(
                f"Ollama does not have model '{self.model_id}' installed. "
                f"Installed: {installed}. Pull it with "
                f"`ollama pull {self.model_id}` or pick an installed tag."
            )

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

    def chat(self, messages, max_tokens, temperature, tools=None):
        return self._chat_with_heartbeats_impl(messages, max_tokens, temperature, tools)



    def _chat_with_heartbeats_impl(self, messages, max_tokens, temperature, tools=None):
        from ollama import ResponseError  # noqa: PLC0415
        import sys
        import json
        effective_tools = None

        try:
            parts: List[str] = []
            finish_reason = ""
            chunk_count = 0
            native_calls: List[Any] = []


            messages = sanitize_for_agent(messages)
            tools = sanitize_for_agent(tools)

            effective_tools = None if self._tools_unsupported else tools

            is_cloud_model = (
                self._is_cloud_model_id(self.model_id)
                or self._is_cloud_host(self.base_url)
            )

            if is_cloud_model:
                chat_options: Dict[str, Any] = {"temperature": temperature}
            else:
                chat_options = {
                    "temperature": temperature,
                    "num_predict": max_tokens,
                    "num_ctx": self.num_ctx,
                }

            chat_kwargs: Dict[str, Any] = dict(
                model=self.model_id,
                messages=messages,
                stream=True,
                options=chat_options,
            )

            if effective_tools:
                chat_kwargs["tools"] = effective_tools

            stream = self._client.chat(**chat_kwargs)

            for chunk in stream:
                content = chunk.message.content or ""

                # Note: Output content is NOT sanitized here to preserve markdown
                # formatting (emojis, icons, etc.) for the UI.

                if content:
                    parts.append(content)

                tcs = getattr(chunk.message, "tool_calls", None) or []
                native_calls.extend(sanitize_for_agent(tcs))

                chunk_count += 1

                if chunk_count % 20 == 1:
                    so_far = len("".join(parts))
                    current_output = "".join(parts)
                    display_output = current_output[-100:] if len(current_output) > 100 else current_output

                    print(
                        f"[orch] Streaming '{self.model_id}' "
                        f"({so_far} chars so far)... Last output: {display_output!r}",
                        file=sys.stderr,
                        flush=True,
                    )
                else:
                    sys.stderr.write("\n")
                    sys.stderr.flush()

                if getattr(chunk, "done", False):
                    finish_reason = getattr(chunk, "done_reason", "") or ""

            # Native tool calls → safe <tool> format
            if native_calls:
                tag_lines: List[str] = []

                for tc in native_calls:
                    fn = getattr(tc, "function", tc)
                    name = getattr(fn, "name", None)
                    args = getattr(fn, "arguments", {}) or {}


                    args = sanitize_for_agent(args)

                    if isinstance(args, str):
                        try:
                            args = json.loads(args)
                        except json.JSONDecodeError:
                            args = {}

                    if not name:
                        continue

                    tag_lines.append(
                        f'<tool>{json.dumps({"tool": name, "parameters": args}, ensure_ascii=False)}</tool>'
                    )

                    print(
                        f"[orch] Native tool_call -> {name}({args})",
                        file=sys.stderr,
                        flush=True,
                    )

                if tag_lines:
                    return "\n".join(tag_lines), finish_reason

            return "".join(parts).strip(), finish_reason

        except ResponseError as e:
            err_str = str(getattr(e, "error", e))
            status = getattr(e, "status_code", 0)
            low = err_str.lower()

            is_cloud_model = (
                self._is_cloud_model_id(self.model_id)
                or self._is_cloud_host(self.base_url)
            )

            # 400: server explicitly says tools aren't supported.
            # 500 + cloud + tools attached: the cloud endpoint silently
            # rejects the tools= payload with a generic Internal Server
            # Error instead of a helpful 400. We can't distinguish this
            # from a real 500 server failure, but retrying once without
            # tools is cheap — if the retry also fails we surface the
            # real error to the user.
            tools_likely_unsupported = (
                effective_tools
                and (
                    (status == 400 and "does not support tools" in low)
                    or (is_cloud_model
                        and "internal server error" in low)
                )
            )

            if tools_likely_unsupported:
                reason = (
                    "explicitly unsupported"
                    if status == 400
                    else "500 from cloud endpoint — likely tools-incompatible"
                )
                print(
                    f"[orch] '{self.model_id}' tools rejected ({reason}); "
                    "retrying without tools, falling back to text-based "
                    "<tool> protocol.",
                    file=sys.stderr,
                    flush=True,
                )
                self._tools_unsupported = True

                return self._chat_with_heartbeats_impl(
                    messages, max_tokens, temperature, tools=tools
                )

            hint = self._build_hint_for(err_str)
            raise RuntimeError(f"Ollama error {status}: {err_str}{hint}") from e

        except Exception as e:
            raise RuntimeError(f"Ollama error: {e}") from e

    # def _chat_with_heartbeats_impl(self, messages, max_tokens, temperature, tools=None):
    #     """Stream the response token-by-token. Each chunk resets the Dart-side
    #     inactivity watchdog via the stderr line it emits.
    #
    #     Passes `tools` to the API so models with native tool-calling (GLM,
    #     Qwen, Llama 3.x, etc.) can respond with structured `tool_calls`
    #     instead of — or in addition to — text. When native tool_calls are
    #     present we serialise them as `<tool>…</tool>` text so the
    #     orchestrator's existing text-based parser handles them uniformly.
    #
    #     If the model returns a 400 "does not support tools" error (e.g.
    #     phi3:mini), `_tools_unsupported` is set to True and the call is
    #     retried without the tools= parameter — identical to GroqBackend.
    #     """
    #     from ollama import ResponseError  # noqa: PLC0415
    #     try:
    #         parts: List[str] = []
    #         finish_reason = ""
    #         chunk_count = 0
    #         # Accumulated native tool calls (list of ollama ToolCall objects).
    #         native_calls: List[Any] = []
    #
    #         # Skip tools= for models that are known not to support it.
    #         effective_tools = None if self._tools_unsupported else tools
    #
    #         # Ollama Cloud models (tagged ':<size>-cloud', e.g.
    #         # 'mistral-large-3:675b-cloud') are served by Ollama's hosted
    #         # inference and reject the local-only `options` payload with
    #         # a bare HTTP 500. For those, only pass `temperature` and skip
    #         # num_ctx/num_predict entirely.
    #         is_cloud_model = self.model_id.endswith("-cloud") or "-cloud:" in self.model_id
    #         if is_cloud_model:
    #             chat_options: Dict[str, Any] = {"temperature": temperature}
    #         else:
    #             chat_options = {
    #                 "temperature": temperature,
    #                 "num_predict": max_tokens,
    #                 "num_ctx": self.num_ctx,
    #             }
    #
    #         chat_kwargs: Dict[str, Any] = dict(
    #             model=self.model_id,
    #             messages=messages,
    #             stream=True,
    #             options=chat_options,
    #         )
    #         if effective_tools:
    #             chat_kwargs["tools"] = effective_tools
    #
    #         stream = self._client.chat(**chat_kwargs)
    #         for chunk in stream:
    #             content = chunk.message.content or ""
    #             if content:
    #                 parts.append(content)
    #
    #             # Native tool calls: accumulate across chunks.
    #             tcs = getattr(chunk.message, "tool_calls", None) or []
    #             native_calls.extend(tcs)
    #
    #             chunk_count += 1
    #             if chunk_count % 20 == 1:
    #                 so_far = len("".join(parts))
    #                 current_output = "".join(parts)
    #                 # Show last 100 chars of agent output for brevity
    #                 display_output = current_output[-100:] if len(current_output) > 100 else current_output
    #                 print(
    #                     f"[orch] Streaming '{self.model_id}' "
    #                     f"({so_far} chars so far)... Last output: {display_output!r}",
    #                     file=sys.stderr,
    #                     flush=True,
    #                 )
    #             else:
    #                 # Bare newline = silent heartbeat: resets the Dart-side
    #                 # inactivity watchdog without cluttering the log panel.
    #                 # Critical for slow local models where 20 chunks can take
    #                 # several minutes to arrive.
    #                 sys.stderr.write("\n")
    #                 sys.stderr.flush()
    #             if getattr(chunk, "done", False):
    #                 finish_reason = getattr(chunk, "done_reason", "") or ""
    #
    #         # If the model used its native tool-calling API, convert each call
    #         # to the <tool> tag format the orchestrator already understands.
    #         # This lets GLM-4, Qwen, Llama 3.x, etc. work without any changes
    #         # to the orchestrator loop.
    #         if native_calls:
    #             tag_lines: List[str] = []
    #             for tc in native_calls:
    #                 fn = getattr(tc, "function", tc)
    #                 name = getattr(fn, "name", None)
    #                 args = getattr(fn, "arguments", {}) or {}
    #                 if not name:
    #                     continue
    #                 tag_lines.append(
    #                     f'<tool>{json.dumps({"tool": name, "parameters": args})}</tool>'
    #                 )
    #                 print(
    #                     f"[orch] Native tool_call -> {name}({args})",
    #                     file=sys.stderr,
    #                     flush=True,
    #                 )
    #             if tag_lines:
    #                 return "\n".join(tag_lines), finish_reason
    #
    #         return "".join(parts), finish_reason
    #
    #     except ResponseError as e:
    #         err_str = str(getattr(e, "error", e))
    #         status = getattr(e, "status_code", 0)
    #         # 400 "does not support tools" — disable tool-calling for this
    #         # model and retry once without the tools= parameter.
    #         if (
    #                 status == 400
    #                 and effective_tools
    #                 and "does not support tools" in err_str.lower()
    #         ):
    #             print(
    #                 f"[orch] '{self.model_id}' does not support native "
    #                 "tool-calling; switching to text-based tool parsing.",
    #                 file=sys.stderr,
    #                 flush=True,
    #             )
    #             self._tools_unsupported = True
    #             return self._chat_with_heartbeats_impl(
    #                 messages, max_tokens, temperature, tools=tools
    #             )
    #         hint = self._build_hint_for(err_str)
    #         raise RuntimeError(
    #             f"Ollama error {status}: {err_str}{hint}"
    #         ) from e
    #     except Exception as e:
    #         raise RuntimeError(f"Ollama error: {e}") from e
