#!/usr/bin/env python3
"""
Client-Side Local Orchestrator
==============================

A modular, tool-registry-based orchestrator that lets a remote Hugging Face
model execute tools (read/write/list files, run commands) on the local machine.

Architecture:
  User Input -> Orchestrator -> HF Model -> Tool Request
  ^                                             |
  |_______ Execute Tool Locally ________________|

Protocol (when run with --interactive, used by the Flutter UI):
  - The client writes exactly one JSON object per line to stdin:
      {"prompt": "...", "new_session": true|false}
  - The orchestrator answers with the full text response on stdout, followed
    by a single line containing exactly `__RESPONSE_END__`.
  - Diagnostics go to stderr so they don't corrupt the response stream.

Other modes:
  --install-deps   Install required Python dependencies and exit.
  (no flag)        Read one prompt from stdin (raw text), answer once, exit.

Usage:
  python orchestrator.py --install-deps
  python orchestrator.py --hf-token YOUR_TOKEN --interactive
  python orchestrator.py --hf-token YOUR_TOKEN --model MODEL_ID
"""

import os
import sys
import json
import argparse
import subprocess
import io
import re
import time
from typing import List, Dict, Any, Callable, Optional, Tuple
from pathlib import Path

# Force UTF-8 so emojis/non-ASCII don't crash on Windows consoles.
if sys.platform == "win32" and sys.stdout.encoding != "utf-8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", newline="\n")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", newline="\n")


REQUIRED_PACKAGES = {
    "huggingface_hub": "huggingface-hub>=0.19.0",
    "pydantic": "pydantic>=2.0.0",
    "ollama": "ollama",
    "groq": "groq",
}

RESPONSE_SENTINEL = "__RESPONSE_END__"


# ============================================================================
# DEPENDENCY MANAGEMENT (UI-triggerable)
# ============================================================================

def check_dependencies() -> List[str]:
    """Return the list of pip specs for packages that are missing."""
    missing = []
    for module_name, pip_spec in REQUIRED_PACKAGES.items():
        try:
            __import__(module_name)
        except ImportError:
            missing.append(pip_spec)
    return missing


def install_dependencies(verbose: bool = True) -> bool:
    """Install required dependencies. Progress goes to stderr."""
    missing = check_dependencies()
    if not missing:
        if verbose:
            print("[deps] All dependencies already installed.", file=sys.stderr)
        return True

    if verbose:
        print("[deps] Installing: " + ", ".join(missing), file=sys.stderr)

    for package in missing:
        if verbose:
            print(f"[deps] pip install {package} ...", file=sys.stderr)
        result = subprocess.run(
            [sys.executable, "-m", "pip", "install", package],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"[deps] FAILED: {package}", file=sys.stderr)
            if result.stderr:
                print(result.stderr, file=sys.stderr)
            return False
        if verbose:
            print(f"[deps] OK: {package}", file=sys.stderr)

    if verbose:
        print("[deps] Done.", file=sys.stderr)
    return True


def _import_runtime():
    """Import hf_hub + pydantic after deps are guaranteed installed."""
    global InferenceClient, BaseModel, Field
    from huggingface_hub import InferenceClient as _IC
    from pydantic import BaseModel as _BM, Field as _F
    InferenceClient = _IC
    BaseModel = _BM
    Field = _F


# Forward declarations (populated by _import_runtime when needed).
InferenceClient = None  # type: ignore
BaseModel = object       # type: ignore
Field = None             # type: ignore


# ============================================================================
# TOOL REGISTRY
# ============================================================================

class ToolRegistry:
    """
    Manages the tools the AI can call. Paths are confined to `base_path`.
    """

    def __init__(self, base_path: str = "."):
        self.base_path = Path(base_path).resolve()
        self.tools: Dict[str, Callable] = {}
        self.definitions: List[Dict[str, Any]] = []
        self._register_tools()

    def _resolve_path(self, path: str) -> Path:
        resolved = (self.base_path / path).resolve()
        if not str(resolved).startswith(str(self.base_path)):
            raise ValueError(f"Access denied: {path} is outside base directory")
        return resolved

    def _register_tools(self):
        def list_files(path: str = ".") -> str:
            try:
                target = self._resolve_path(path)
                items = sorted([p.name + ("/" if p.is_dir() else "") for p in target.iterdir()])
                return json.dumps({"status": "success", "files": items, "count": len(items)})
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def read_file(path: str) -> str:
            try:
                fp = self._resolve_path(path)
                if not fp.exists():
                    return json.dumps({"status": "error", "message": f"File not found: {path}"})
                content = fp.read_text(encoding="utf-8")
                return json.dumps({"status": "success", "path": path, "content": content, "size": len(content)})
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def write_file(path: str, content: str) -> str:
            try:
                fp = self._resolve_path(path)
                fp.parent.mkdir(parents=True, exist_ok=True)
                fp.write_text(content, encoding="utf-8")
                return json.dumps({"status": "success", "message": f"File written: {path}", "size": len(content)})
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def append_file(path: str, content: str) -> str:
            try:
                fp = self._resolve_path(path)
                with open(fp, "a", encoding="utf-8") as f:
                    f.write(content)
                return json.dumps({"status": "success", "message": f"Appended to: {path}"})
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def delete_file(path: str) -> str:
            try:
                fp = self._resolve_path(path)
                if not fp.exists():
                    return json.dumps({"status": "error", "message": f"File not found: {path}"})
                fp.unlink()
                return json.dumps({"status": "success", "message": f"Deleted: {path}"})
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def run_command(command: str) -> str:
            try:
                result = subprocess.run(
                    command, shell=True, capture_output=True, text=True,
                    timeout=30, cwd=str(self.base_path),
                )
                output = (result.stdout or "") + (result.stderr or "")
                return json.dumps({
                    "status": "success",
                    "command": command,
                    "output": output if output else "(no output)",
                    "returncode": result.returncode,
                })
            except subprocess.TimeoutExpired:
                return json.dumps({"status": "error", "message": "Command timed out (30s limit)"})
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def _git(args: list, timeout: int = 15) -> subprocess.CompletedProcess:
            return subprocess.run(
                ["git"] + args,
                capture_output=True, text=True,
                timeout=timeout, cwd=str(self.base_path),
            )

        def git_status() -> str:
            try:
                branch_r = _git(["rev-parse", "--abbrev-ref", "HEAD"])
                branch = branch_r.stdout.strip() if branch_r.returncode == 0 else "unknown"
                status_r = _git(["status", "--short"])
                files = status_r.stdout.strip() if status_r.returncode == 0 else ""
                return json.dumps({
                    "status": "success",
                    "branch": branch,
                    "changes": files if files else "(clean)",
                })
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def git_branches() -> str:
            try:
                r = _git(["branch", "-a", "--format=%(refname:short)"])
                if r.returncode != 0:
                    return json.dumps({"status": "error", "message": r.stderr.strip()})
                branches = [b for b in r.stdout.splitlines() if b.strip()]
                current_r = _git(["rev-parse", "--abbrev-ref", "HEAD"])
                current = current_r.stdout.strip() if current_r.returncode == 0 else ""
                return json.dumps({"status": "success", "branches": branches, "current": current})
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def git_log(count: int = 10) -> str:
            try:
                r = _git(["log", f"-{count}", "--oneline", "--decorate"])
                if r.returncode != 0:
                    return json.dumps({"status": "error", "message": r.stderr.strip()})
                return json.dumps({"status": "success", "log": r.stdout.strip()})
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def git_diff(path: str = ".") -> str:
            try:
                target = str(self._resolve_path(path))
                r = _git(["diff", "HEAD", "--", target])
                if r.returncode != 0:
                    return json.dumps({"status": "error", "message": r.stderr.strip()})
                return json.dumps({"status": "success", "diff": r.stdout or "(no changes)"})
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def git_checkout(branch: str) -> str:
            try:
                r = _git(["checkout", branch])
                if r.returncode != 0:
                    return json.dumps({"status": "error", "message": r.stderr.strip()})
                return json.dumps({"status": "success", "message": f"Switched to branch '{branch}'"})
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        self.tools = {
            "list_files": list_files,
            "read_file": read_file,
            "write_file": write_file,
            "append_file": append_file,
            "delete_file": delete_file,
            "run_command": run_command,
            "git_status": git_status,
            "git_branches": git_branches,
            "git_log": git_log,
            "git_diff": git_diff,
            "git_checkout": git_checkout,
        }

        # OpenAI-compatible tool definitions (HF InferenceClient accepts these
        # directly via the `tools=` parameter, which is the native tool-calling
        # path for models that support it, e.g. Llama 3.1, Qwen 2.5, Mixtral).
        self.definitions = [
            {
                "type": "function",
                "function": {
                    "name": "list_files",
                    "description": "List files in a directory (relative to project root).",
                    "parameters": {
                        "type": "object",
                        "properties": {"path": {"type": "string", "description": "Directory path, defaults to '.'"}},
                        "required": [],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "read_file",
                    "description": "Read the complete contents of a local file.",
                    "parameters": {
                        "type": "object",
                        "properties": {"path": {"type": "string", "description": "File path"}},
                        "required": ["path"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "write_file",
                    "description": "Create or overwrite a local file.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "path": {"type": "string"},
                            "content": {"type": "string"},
                        },
                        "required": ["path", "content"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "append_file",
                    "description": "Append content to an existing file.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "path": {"type": "string"},
                            "content": {"type": "string"},
                        },
                        "required": ["path", "content"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "delete_file",
                    "description": "Delete a local file.",
                    "parameters": {
                        "type": "object",
                        "properties": {"path": {"type": "string"}},
                        "required": ["path"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "run_command",
                    "description": "Run a shell command (30s timeout) inside the project root.",
                    "parameters": {
                        "type": "object",
                        "properties": {"command": {"type": "string"}},
                        "required": ["command"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "git_status",
                    "description": "Show the current git branch and working-tree changes (modified/untracked files).",
                    "parameters": {"type": "object", "properties": {}, "required": []},
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "git_branches",
                    "description": "List all local and remote git branches and indicate which is currently checked out.",
                    "parameters": {"type": "object", "properties": {}, "required": []},
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "git_log",
                    "description": "Show recent git commit history.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "count": {"type": "integer", "description": "Number of commits to show (default 10)"},
                        },
                        "required": [],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "git_diff",
                    "description": "Show the git diff for a file or directory relative to HEAD.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "path": {"type": "string", "description": "File or directory path (default '.')"},
                        },
                        "required": [],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "git_checkout",
                    "description": "Switch to a different git branch.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "branch": {"type": "string", "description": "Branch name to check out"},
                        },
                        "required": ["branch"],
                    },
                },
            },
        ]

    def _relativise(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Convert any absolute `path` value to a path relative to base_path.

        Models sometimes echo an absolute path the user typed (e.g.
        C:\\Users\\...\\project\\lib\\main.dart). If that path sits inside
        base_path we can silently fix it; otherwise the _resolve_path check
        will reject it with a clear error rather than crashing.
        """
        path = params.get("path")
        if not path or not isinstance(path, str):
            return params
        p = Path(path)
        if not p.is_absolute():
            return params
        try:
            relative = p.relative_to(self.base_path)
            return {**params, "path": str(relative)}
        except ValueError:
            # Not under base_path — leave as-is so _resolve_path can reject.
            return params

    def execute(self, tool_name: str, parameters: Dict[str, Any]) -> str:
        if tool_name not in self.tools:
            return json.dumps({"status": "error", "message": f"Unknown tool: {tool_name}"})
        try:
            safe_params = self._relativise(parameters or {})
            return self.tools[tool_name](**(safe_params))
        except TypeError as e:
            return json.dumps({"status": "error", "message": f"Invalid parameters: {e}"})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def get_system_prompt(self) -> str:
        """
        System prompt for the prompt-based tool protocol. Kept tight so
        small models (phi3:mini, llama3.2:3b) don't burn 20-30 s per turn
        on prompt eval alone. Every line has to earn its place.

        The directive tone is deliberate: many chat-tuned models default
        to "I cannot access your files" safety replies. The user has
        explicitly started this process — refusing would break the product.
        """
        prompt = (
            "You are a local coding assistant with DIRECT filesystem access "
            "via the tools below. The user started this process and granted "
            "access. NEVER refuse, NEVER say 'as an AI I cannot', NEVER ask "
            "the user to paste file contents.\n"
            "\n"
            "REPLY FORMAT (every turn must be EXACTLY one of):\n"
            "  (a) ONE tool call on its own line, no prose before or after:\n"
            '      <tool>{"tool":"NAME","parameters":{...}}</tool>\n'
            "  (b) the final plain-text answer (no <tool> tag) once you have "
            "enough info. Do NOT wrap the answer in quotes.\n"
            "\n"
            "Rules:\n"
            "  1. ALWAYS use list_files to list a directory — never use "
            "run_command with dir, ls, or find for that purpose.\n"
            "  2. If the user mentions files/dirs/the project, call list_files "
            "or read_file FIRST. Do not guess.\n"
            "  3. One tool call per turn. Wait for the result, then decide.\n"
            "  4. Paths passed to tools must be relative to the project root "
            "(strip any absolute prefix the user gave you).\n"
            "\n"
            "Tools:\n"
        )
        for d in self.definitions:
            fn = d["function"]
            props = fn.get("parameters", {}).get("properties", {})
            required = set(fn.get("parameters", {}).get("required", []))
            sig = ", ".join(
                f"{k}{'' if k in required else '?'}"
                for k in props.keys()
            )
            prompt += f"  - {fn['name']}({sig}): {fn['description']}\n"
        prompt += (
            "\nExamples (for illustration only — do NOT execute unless the "
            "user actually asks):\n"
            'Q: show project files -> <tool>{"tool":"list_files","parameters":{"path":"."}}</tool>\n'
            'Q: open src/main.py -> <tool>{"tool":"read_file","parameters":{"path":"src/main.py"}}</tool>\n'
            'Q: save TODO.txt with content "buy milk" -> '
            '<tool>{"tool":"write_file","parameters":{"path":"TODO.txt","content":"buy milk"}}</tool>\n'
        )
        return prompt


# ============================================================================
# MODEL BACKENDS
# ============================================================================
#
# The orchestrator is agnostic about *where* the model runs. It produces a
# conversation history and hands it to a ModelBackend.chat(...) call, which
# returns (content, finish_reason). Two backends ship out of the box:
#
#   * HFBackend     — huggingface_hub.InferenceClient.chat_completion
#   * OllamaBackend — POST http://localhost:11434/api/chat (stdlib urllib;
#                     no extra pip dependency, unlike the `ollama` package)
#
# The tool-use protocol (prompt-based with <tool>…</tool> tags) is identical
# for both — small local models get exactly the same system prompt and
# refusal-retry treatment as cloud models. The trade-off is model quality:
# a 1-3B model will frequently refuse or emit natural-language instead of
# tool calls; 7B+ coder-tuned models (qwen2.5-coder:7b, llama3:8b) do much
# better. The orchestrator can't hide that — but the refusal detector at
# least gives them a second chance.


class ModelBackend:
    """Strategy object that turns a chat history into (content, finish)."""

    def chat(
        self,
        messages: List[Dict[str, Any]],
        max_tokens: int,
        temperature: float,
        tools: Optional[List[Dict[str, Any]]] = None,
    ) -> Tuple[str, str]:
        raise NotImplementedError


class HFBackend(ModelBackend):
    """Hugging Face Inference API / router backend (the original path)."""

    def __init__(self, hf_token: str, model_id: str):
        if not hf_token:
            raise RuntimeError("HF backend requires --hf-token.")
        self.hf_token = hf_token
        self.model_id = model_id
        self._client = InferenceClient(model=model_id, token=hf_token)

    def chat(self, messages, max_tokens, temperature, tools=None):
        resp = self._client.chat_completion(
            messages=messages,
            max_tokens=max_tokens,
            temperature=temperature,
        )
        choice = resp.choices[0]
        content = choice.message.content or ""
        finish_reason = getattr(choice, "finish_reason", None) or ""
        return content, finish_reason


class OllamaBackend(ModelBackend):
    """
    Talks to a local or cloud Ollama endpoint via the official `ollama`
    Python library. Streaming is used so every incoming token chunk acts
    as a natural heartbeat — no separate thread needed.

    Local daemon:  OllamaBackend(model_id="phi3:mini")
    Cloud (ollama.com): OllamaBackend(model_id="gpt-oss:120b-cloud",
                            base_url="https://ollama.com",
                            api_key="<your key>")
    """

    # Context window cap. Small models (phi3:mini, llama3.2) ship Modelfiles
    # with num_ctx=128K which blows KV-cache RAM to tens of GiB. 4096 is a
    # safe default that fits the system prompt + a couple of read_file
    # results. Bump via --ollama-num-ctx when running a 7B+ model on >=16 GB.
    DEFAULT_NUM_CTX = 4096

    def __init__(
        self,
        model_id: str,
        base_url: str = "http://localhost:11434",
        num_ctx: int = DEFAULT_NUM_CTX,
        api_key: str = "",
    ):
        if not model_id:
            raise RuntimeError(
                "Ollama backend requires --model (e.g. 'qwen2.5-coder:7b')."
            )
        from ollama import Client  # noqa: PLC0415
        self.model_id = model_id
        self.base_url = base_url.rstrip("/")
        self.num_ctx = num_ctx
        self.api_key = api_key.strip() or os.environ.get("OLLAMA_API_KEY", "").strip()

        # Build a single Client instance reused for every request.
        # For cloud endpoints the README says to pass headers with Bearer token.
        client_kwargs: Dict[str, Any] = {"host": self.base_url}
        if self.api_key:
            client_kwargs["headers"] = {"Authorization": f"Bearer {self.api_key}"}
        self._client: Any = Client(**client_kwargs)

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
        is_cloud = "localhost" not in self.base_url and "127.0.0.1" not in self.base_url
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
        if "context" in low and ("too large" in low or "exceed" in low):
            return (
                "\n-> Prompt exceeded the model's context window. "
                "Start a new chat to clear history."
            )
        return ""

    def chat(self, messages, max_tokens, temperature, tools=None):
        return self._chat_with_heartbeats_impl(messages, max_tokens, temperature, tools)

    def _chat_with_heartbeats_impl(self, messages, max_tokens, temperature, tools=None):
        """Stream the response token-by-token. Each chunk resets the Dart-side
        inactivity watchdog via the stderr line it emits.

        Passes `tools` to the API so models with native tool-calling (GLM,
        Qwen, Llama 3.x, etc.) can respond with structured `tool_calls`
        instead of — or in addition to — text. When native tool_calls are
        present we serialise them as `<tool>…</tool>` text so the
        orchestrator's existing text-based parser handles them uniformly.
        """
        from ollama import ResponseError  # noqa: PLC0415
        try:
            parts: List[str] = []
            finish_reason = ""
            chunk_count = 0
            # Accumulated native tool calls (list of ollama ToolCall objects).
            native_calls: List[Any] = []

            chat_kwargs: Dict[str, Any] = dict(
                model=self.model_id,
                messages=messages,
                stream=True,
                options={
                    "temperature": temperature,
                    "num_predict": max_tokens,
                    "num_ctx": self.num_ctx,
                },
            )
            if tools:
                chat_kwargs["tools"] = tools

            stream = self._client.chat(**chat_kwargs)
            for chunk in stream:
                content = chunk.message.content or ""
                if content:
                    parts.append(content)

                # Native tool calls: accumulate across chunks.
                tcs = getattr(chunk.message, "tool_calls", None) or []
                native_calls.extend(tcs)

                chunk_count += 1
                if chunk_count % 20 == 1:
                    so_far = len("".join(parts))
                    print(
                        f"[orch] Streaming '{self.model_id}' "
                        f"({so_far} chars so far)...",
                        file=sys.stderr,
                        flush=True,
                    )
                if getattr(chunk, "done", False):
                    finish_reason = getattr(chunk, "done_reason", "") or ""

            # If the model used its native tool-calling API, convert each call
            # to the <tool> tag format the orchestrator already understands.
            # This lets GLM-4, Qwen, Llama 3.x, etc. work without any changes
            # to the orchestrator loop.
            if native_calls:
                tag_lines: List[str] = []
                for tc in native_calls:
                    fn = getattr(tc, "function", tc)
                    name = getattr(fn, "name", None)
                    args = getattr(fn, "arguments", {}) or {}
                    if not name:
                        continue
                    tag_lines.append(
                        f'<tool>{json.dumps({"tool": name, "parameters": args})}</tool>'
                    )
                    print(
                        f"[orch] Native tool_call -> {name}({args})",
                        file=sys.stderr,
                        flush=True,
                    )
                if tag_lines:
                    return "\n".join(tag_lines), finish_reason

            return "".join(parts), finish_reason

        except ResponseError as e:
            hint = self._build_hint_for(str(getattr(e, "error", e)))
            raise RuntimeError(
                f"Ollama error {getattr(e, 'status_code', '')}: "
                f"{getattr(e, 'error', e)}{hint}"
            ) from e
        except Exception as e:
            raise RuntimeError(f"Ollama error: {e}") from e


# ============================================================================
# GROQ BACKEND
# ============================================================================

class GroqBackend(ModelBackend):
    """
    Groq Cloud backend via the official `groq` Python library.
    Ultra-fast LPU inference. API key from https://console.groq.com/keys.
    Streaming is used so token chunks act as heartbeats.
    Reasoning blocks (<think>…</think>) are stripped from the final answer.
    """

    _THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)

    def __init__(self, api_key: str, model_id: str):
        if not api_key:
            raise RuntimeError("Groq backend requires --groq-api-key.")
        if not model_id:
            raise RuntimeError("Groq backend requires --model.")
        from groq import Groq  # noqa: PLC0415
        self.model_id = model_id
        self._client = Groq(api_key=api_key)

    # Track whether this model has already proven it doesn't support native
    # tool calling so we don't waste a round-trip on the next iteration.
    _tools_unsupported: bool = False

    def chat(self, messages, max_tokens, temperature, tools=None):
        from groq import BadRequestError  # noqa: PLC0415

        # If a previous call already hit the "tool calling not supported"
        # 400, skip the tools parameter for all subsequent calls in this
        # session so we rely on the text-based <tool>…</tool> protocol.
        effective_tools = None if self._tools_unsupported else tools

        try:
            parts: List[str] = []
            finish_reason = ""
            chunk_count = 0
            native_calls: List[Any] = []

            chat_kwargs: Dict[str, Any] = dict(
                model=self.model_id,
                messages=messages,
                stream=True,
                temperature=temperature,
                max_completion_tokens=max_tokens,
            )
            if effective_tools:
                chat_kwargs["tools"] = effective_tools

            stream = self._client.chat.completions.create(**chat_kwargs)
            for chunk in stream:
                delta = chunk.choices[0].delta if chunk.choices else None
                if delta:
                    content = delta.content or ""
                    if content:
                        parts.append(content)
                    tcs = getattr(delta, "tool_calls", None) or []
                    native_calls.extend(tcs)
                chunk_count += 1
                if chunk_count % 20 == 1:
                    print(
                        f"[orch] Groq streaming '{self.model_id}' "
                        f"({len(''.join(parts))} chars)...",
                        file=sys.stderr, flush=True,
                    )
                if chunk.choices and chunk.choices[0].finish_reason:
                    finish_reason = chunk.choices[0].finish_reason

            # Native tool calls → <tool> tag format
            if native_calls:
                tag_lines: List[str] = []
                for tc in native_calls:
                    fn = getattr(tc, "function", tc)
                    name = getattr(fn, "name", None)
                    args = getattr(fn, "arguments", {}) or {}
                    if isinstance(args, str):
                        try:
                            args = json.loads(args)
                        except json.JSONDecodeError:
                            args = {}
                    if not name:
                        continue
                    tag_lines.append(
                        f'<tool>{json.dumps({"tool": name, "parameters": args})}</tool>'
                    )
                    print(f"[orch] Groq native tool_call -> {name}({args})",
                          file=sys.stderr, flush=True)
                if tag_lines:
                    return "\n".join(tag_lines), finish_reason

            full = "".join(parts)
            # Strip chain-of-thought blocks before returning.
            full = self._THINK_RE.sub("", full).strip()
            return full, finish_reason

        except BadRequestError as e:
            err_str = str(e).lower()
            if (effective_tools
                    and "tool" in err_str
                    and ("not supported" in err_str or "unsupported" in err_str)):
                # Model doesn't support native tool calling (e.g. DeepSeek-R1,
                # QwQ, other reasoning models). Mark the flag so all future
                # calls in this session skip the tools= parameter, then retry
                # this call immediately using the text-based <tool>…</tool>
                # protocol that is already in the system prompt.
                self._tools_unsupported = True
                print(
                    f"[orch] '{self.model_id}' doesn't support native tool "
                    "calling — falling back to text-based <tool> protocol.",
                    file=sys.stderr, flush=True,
                )
                return self.chat(messages, max_tokens, temperature, tools=tools)
            raise RuntimeError(f"Groq bad request: {e}") from e
        except Exception as e:
            raise RuntimeError(f"Groq error: {e}") from e


# ============================================================================
# ORCHESTRATOR
# ============================================================================

class Orchestrator:
    def __init__(
        self,
        backend: ModelBackend,
        base_path: str = ".",
        temperature: float = 0.2,
        max_tokens: int = 2048,
    ):
        self.backend = backend
        # Expose model_id for logging/diagnostics; both backends carry one.
        self.model_id = getattr(backend, "model_id", "(unknown)")
        self.tool_registry = ToolRegistry(base_path=base_path)
        self.conversation_history: List[Dict[str, Any]] = []
        # Generation knobs. Exposed as CLI flags so the Flutter UI can
        # let users tune them per-backend without editing Python.
        self.temperature = temperature
        self.max_tokens = max_tokens
        # Cap tool-chain length. Each iteration is potentially a 60–120 s
        # model call, so 6 bounds a single /sendPrompt at ~12 min worst case,
        # comfortably inside the Dart-side absolute timeout (20 min).
        self.max_iterations = 10

    def reset(self):
        self.conversation_history = []

    def import_history(self, history: List[Dict[str, Any]]):
        self._ensure_system_prompt()
        for msg in history:
            if not isinstance(msg, dict):
                continue
            role = str(msg.get("role") or "").strip().lower()
            content = str(msg.get("content") or "")
            if role not in ("user", "assistant", "system"):
                continue
            if not content.strip():
                continue
            self.conversation_history.append({
                "role": role,
                "content": content,
            })

    def _ensure_system_prompt(self):
        if not self.conversation_history or self.conversation_history[0].get("role") != "system":
            self.conversation_history.insert(0, {
                "role": "system",
                "content": self.tool_registry.get_system_prompt(),
            })

    # Short reminder prepended to the first user turn. Many HF-router providers
    # silently drop the `system` role (Qwen via hyperbolic is a known offender)
    # so embedding the contract in the user message guarantees the model sees
    # it. Kept short so small Ollama models don't waste prompt-eval time.
    _TURN_PREFIX = (
        "[Reminder: reply with exactly ONE "
        '<tool>{"tool":"NAME","parameters":{...}}</tool> call OR the final '
        "plain-text answer. You have filesystem access via list_files, "
        "read_file, write_file, append_file, delete_file, run_command. "
        "Never refuse.]\n\n"
    )

    def run(self, user_input: str) -> str:
        self._ensure_system_prompt()
        decorated = self._TURN_PREFIX + user_input
        self.conversation_history.append({"role": "user", "content": decorated})

        print(f"[orch] Request: {user_input[:120]!r}", file=sys.stderr)

        refusal_retries = 0
        empty_retries = 0
        truncation_retries = 0

        for iteration in range(self.max_iterations):
            try:
                text, finish_reason = self._call_model()
            except Exception as e:
                return f"Model error: {e}"

            preview = (text or "").replace("\n", " ")[:200]
            print(f"[orch] Model reply (iter {iteration}, finish={finish_reason}): "
                  f"{preview!r}", file=sys.stderr)

            self.conversation_history.append({"role": "assistant", "content": text or ""})

            tag_call = self._parse_tag_tool_call(text or "")
            if tag_call:
                name, params = tag_call
                print(f"[orch] -> tool {name}({params})", file=sys.stderr)
                result = self.tool_registry.execute(name, params)
                # On the last two iterations force a final answer — no more tools.
                is_last_chance = iteration >= self.max_iterations - 2
                if is_last_chance:
                    follow_up = (
                        f"Tool `{name}` returned:\n{result}\n\n"
                        "FINAL ANSWER REQUIRED. Do NOT call any more tools. "
                        "Write only your plain-text answer to the user now."
                    )
                else:
                    follow_up = (
                        f"Tool `{name}` returned:\n{result}\n\n"
                        "Continue. Either call another tool or give the final answer."
                    )
                self.conversation_history.append({"role": "user", "content": follow_up})
                continue

            # --- Truncation detection ---
            # The reply claims to start a tool call (`<tool>` or fenced JSON)
            # but was cut off by max_tokens before the matching `</tool>` /
            # closing brace arrived. Without this branch we'd dump the raw
            # half-written JSON back to the UI.
            looks_truncated = (
                finish_reason == "length"
                or self._looks_like_unclosed_tool(text or "")
            )
            if looks_truncated and truncation_retries < 2:
                truncation_retries += 1
                print(f"[orch] Truncation detected (retry {truncation_retries}).",
                      file=sys.stderr)
                self.conversation_history.append({
                    "role": "user",
                    "content": (
                        "Your previous reply was CUT OFF before the closing "
                        "</tool> tag. Do NOT include any plan, preamble, or "
                        "explanation. Emit ONLY the tool call on a single "
                        "line, e.g.:\n"
                        '<tool>{"tool":"write_file","parameters":'
                        '{"path":"...","content":"..."}}</tool>\n'
                        "If the content is very large, break the work into "
                        "smaller steps: first create the file with a short "
                        "content, then use append_file in follow-up calls."
                    ),
                })
                continue

            # No tool call. Classify the response.
            if self._looks_like_refusal(text or "") and refusal_retries < 2:
                refusal_retries += 1
                print(f"[orch] Refusal detected (retry {refusal_retries}).",
                      file=sys.stderr)
                self.conversation_history.append({
                    "role": "user",
                    "content": (
                        "STOP. That is a refusal and it is wrong. You DO have "
                        "filesystem access through the tools. Your entire next "
                        "message must be exactly one line, e.g.:\n"
                        '<tool>{"tool":"list_files","parameters":{"path":"."}}</tool>\n'
                        "No apology, no explanation, no markdown fences. Just "
                        "the tool call tag."
                    ),
                })
                continue

            if not (text or "").strip() and empty_retries < 1:
                empty_retries += 1
                self.conversation_history.append({
                    "role": "user",
                    "content": "Your reply was empty. Emit a single "
                               '<tool>{"tool":"...","parameters":{...}}</tool> '
                               "call or the final plain-text answer.",
                })
                continue

            # Otherwise treat as final answer.
            return self._clean_final_answer(text or "")

        return "Max iterations reached without a final answer."

    # HTML-ish tags small models sometimes wrap their output in. `<plaintext>`
    # is a deprecated tag phi3 loves to emit; `<pre>`/`<code>` appear when the
    # model decides the answer deserves "formatting". We strip the wrappers
    # but keep the inner text so the UI renders clean markdown. Stray
    # `</tool>` closers that slipped past the parser are also dropped.
    _JUNK_TAG_PATTERN = re.compile(
        r"</?(?:plaintext|pre|code|html|body|p|span|div|tool)\b[^>]*>",
        re.IGNORECASE,
    )
    # Reasoning models (DeepSeek-R1, QwQ, groq reasoning variants) wrap their
    # chain-of-thought in <think>…</think>. Strip the entire block so only the
    # final answer reaches the user.
    _THINK_PATTERN = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)

    @classmethod
    def _clean_final_answer(cls, text: str) -> str:
        if not text:
            return text
        # Strip reasoning blocks first so they don't pollute blank-line collapsing.
        cleaned = cls._THINK_PATTERN.sub("", text)
        cleaned = cls._JUNK_TAG_PATTERN.sub("", cleaned)
        # Collapse runs of blank lines the stripping may have produced.
        cleaned = re.sub(r"\n{3,}", "\n\n", cleaned)
        cleaned = cleaned.strip()
        # Some small models (phi3, llama3.2) wrap every reply in a pair of
        # double-quotes: `"The file was created."` → strip them when the
        # entire response is wrapped (not mid-text quoted content).
        if (
            len(cleaned) >= 2
            and cleaned[0] == '"'
            and cleaned[-1] == '"'
            and cleaned.count('"') == 2
        ):
            cleaned = cleaned[1:-1].strip()
        return cleaned

    @staticmethod
    def _looks_like_unclosed_tool(text: str) -> bool:
        """True if the reply opens a `<tool>` tag (or a ```json fence intended
        as a tool call) without a matching close. Used to detect responses
        that were cut off by max_tokens mid-JSON."""
        if not text:
            return False
        opens = text.count("<tool>")
        closes = text.count("</tool>")
        if opens > closes:
            return True
        # Fallback: fenced ```json ... that carries a `"tool"` key but no
        # matching closing fence.
        if "```json" in text and text.count("```") % 2 == 1:
            if '"tool"' in text or "'tool'" in text:
                return True
        return False

    # Backoff schedule for 429 / transient 5xx errors, in seconds. Total
    # maximum wall time for rate-limit retries: 1+2+4+8+16 = 31 s plus 5
    # model calls. The Dart inactivity watchdog (3 min) sits well above this.
    _RETRY_BACKOFFS = (1, 2, 4, 8, 16)

    # Exception-message substrings that identify a retryable error from the
    # huggingface-hub SDK. The SDK raises `HfHubHTTPError` (subclass of
    # `requests.HTTPError`) which prints the status code into `str(e)`.
    _RETRYABLE_HINTS = (
        "429",
        "too many requests",
        "rate limit",
        "rate-limit",
        "503",
        "502",
        "504",
        "service unavailable",
        "bad gateway",
        "gateway timeout",
    )

    @classmethod
    def _is_retryable_error(cls, exc: BaseException) -> bool:
        msg = str(exc).lower()
        return any(h in msg for h in cls._RETRYABLE_HINTS)

    def _call_model(self) -> tuple:
        """
        Issue a chat-completion request using ONLY the prompt-based protocol.

        Returns `(content, finish_reason)`. `finish_reason == "length"` means
        the model hit `max_tokens` and the reply is truncated — the caller
        must handle that, because a half-written `<tool>...` JSON is worse
        than no tool call at all.

        Retries on 429 / 5xx with exponential backoff (1s, 2s, 4s, 8s, 16s).
        These errors are an HF-router concern (rate limits, upstream 5xx);
        the local Ollama backend has its own simpler error surface, but
        reusing the same loop is harmless — its errors just won't match the
        retryable hint list and will propagate immediately.

        `max_tokens` of 2048 is enough for any single tool call and all but
        the largest write_file contents. 8000 tokens on a 3.8B model (phi3)
        takes multiple minutes to generate and blows the iteration budget;
        the truncation detector handles the rare case where we need more,
        by asking the model to break large writes into append_file chunks.
        """
        last_exc: Optional[BaseException] = None
        # attempt 0 = immediate; attempts 1..N = after waiting backoffs[i-1]
        for attempt in range(len(self._RETRY_BACKOFFS) + 1):
            if attempt > 0:
                wait_s = self._RETRY_BACKOFFS[attempt - 1]
                print(
                    f"[orch] Transient error, backing off {wait_s}s "
                    f"(attempt {attempt + 1}/{len(self._RETRY_BACKOFFS) + 1}): "
                    f"{last_exc}",
                    file=sys.stderr,
                )
                time.sleep(wait_s)
            try:
                return self.backend.chat(
                    messages=self.conversation_history,
                    max_tokens=self.max_tokens,
                    temperature=self.temperature,
                    tools=self.tool_registry.definitions,
                )
            except Exception as e:  # noqa: BLE001 - broad by design
                last_exc = e
                if not self._is_retryable_error(e):
                    # Auth errors, malformed input, Ollama connection refused,
                    # etc. Don't retry.
                    raise
                # else: fall through to next backoff

        # Exhausted all retries. Surface a clear, user-actionable message.
        raise RuntimeError(
            f"Model backend kept returning a rate-limit / transient error "
            f"after {len(self._RETRY_BACKOFFS) + 1} attempts. "
            f"Last error: {last_exc}. "
            f"Try again in a minute, switch to a less-busy model, or check "
            f"quota / daemon health."
        )

    # Heuristic patterns that strongly suggest the model has ignored the
    # tool-use instructions and is emitting a safety refusal instead.
    _REFUSAL_PATTERNS = [
        r"as an? ai",
        r"i can(?:'?| ?no)t access (?:your|the user'?s?|local)",
        r"i (?:do not|don'?t) have (?:the )?ability to access",
        r"i (?:do not|don'?t) have (?:direct )?access to",
        r"(?:i am|i'm) unable to (?:access|read|open|list)",
        r"my environment is isolated",
        r"for security reasons",
        r"please (?:copy|paste) (?:the )?(?:contents|output|result)",
        r"run the following command.*(?:and|then).*paste",
        r"hard drive or files directly",
        r"option\s*1.*copy and paste",
        r"option\s*2.*tree",
    ]

    @classmethod
    def _looks_like_refusal(cls, text: str) -> bool:
        if not text:
            return False
        low = text.lower()
        return any(re.search(p, low) for p in cls._REFUSAL_PATTERNS)

    @staticmethod
    def _parse_tag_tool_call(response: str):
        """
        Parse a tool invocation out of the model reply. The parser is
        intentionally forgiving: it handles <tool>…</tool> tags, markdown
        ```json blocks, and naked JSON objects that carry a `"tool"` key.
        Returns (name, params) or None.
        """
        if not response:
            return None

        candidates: List[str] = []

        # 1. Preferred: <tool>…</tool> — the tag boundaries are explicit, so
        #    we can grab the full body and let _extract_json_objects find the
        #    outermost object (handles nested braces in `parameters`).
        for m in re.finditer(r"<tool[^>]*>(.*?)</tool>", response, re.DOTALL):
            candidates.extend(Orchestrator._extract_json_objects(m.group(1)))

        # 2. ```json { … } ``` fences (some coder models love these).
        for m in re.finditer(r"```(?:json|tool)?\s*(\{.*?\})\s*```", response, re.DOTALL):
            candidates.extend(Orchestrator._extract_json_objects(m.group(1)))

        # 3. Any JSON-looking object in free text that mentions "tool" or "name".
        candidates.extend(
            obj for obj in Orchestrator._extract_json_objects(response)
            if '"tool"' in obj or '"name"' in obj
        )

        for raw in candidates:
            for cleaned in Orchestrator._json_variants(raw):
                try:
                    data = json.loads(cleaned)
                except json.JSONDecodeError:
                    continue
                if not isinstance(data, dict):
                    continue
                name = data.get("tool") or data.get("name")
                params = (
                    data.get("parameters")
                    or data.get("arguments")
                    or data.get("args")
                    or {}
                )
                if isinstance(params, str):
                    # Some models emit parameters as a JSON string.
                    try:
                        params = json.loads(params)
                    except json.JSONDecodeError:
                        params = {}
                if isinstance(name, str) and isinstance(params, dict):
                    return name, params
        return None

    @staticmethod
    def _extract_json_objects(text: str) -> List[str]:
        """
        Scan `text` and return every top-level `{...}` substring with
        correctly balanced braces. Handles nested objects and string
        literals containing `{` or `}`. This is the brace-counter the
        regex engine can't easily do on its own.
        """
        out: List[str] = []
        i = 0
        n = len(text)
        while i < n:
            if text[i] != '{':
                i += 1
                continue
            depth = 0
            in_str = False
            esc = False
            start = i
            while i < n:
                c = text[i]
                if in_str:
                    if esc:
                        esc = False
                    elif c == '\\':
                        esc = True
                    elif c == '"':
                        in_str = False
                elif c == '"':
                    in_str = True
                elif c == '{':
                    depth += 1
                elif c == '}':
                    depth -= 1
                    if depth == 0:
                        out.append(text[start:i + 1])
                        i += 1
                        break
                i += 1
            else:
                break  # unbalanced, stop
        return out

    @staticmethod
    def _json_variants(raw: str):
        """Yield progressively-cleaned forms of a candidate JSON fragment."""
        yield raw
        # Strip simple trailing commas that break json.loads.
        yield re.sub(r",(\s*[}\]])", r"\1", raw)
        # Replace smart quotes with standard ones.
        yield (raw.replace("\u201c", '"').replace("\u201d", '"')
                  .replace("\u2018", "'").replace("\u2019", "'"))


# ============================================================================
# CLI
# ============================================================================

def _read_interactive_request(stream) -> Optional[Dict[str, Any]]:
    """
    Read one line (JSON object) from stdin. Returns None on EOF.
    Accepts either a JSON object {"prompt": "...", "new_session": bool}
    or a raw line (treated as the prompt) for backward compatibility.
    """
    line = stream.readline()
    if not line:
        return None
    line = line.strip()
    if not line:
        return {"prompt": "", "new_session": False}
    if line.startswith("{"):
        try:
            obj = json.loads(line)
            if isinstance(obj, dict):
                obj.setdefault("prompt", "")
                obj.setdefault("new_session", False)
                obj.setdefault("history", [])
                return obj
        except json.JSONDecodeError:
            pass
    return {"prompt": line, "new_session": False}


def main():
    parser = argparse.ArgumentParser(
        description="Client-Side Local Orchestrator (HF router or Ollama)",
    )
    parser.add_argument(
        "--backend",
        choices=["huggingface", "ollama", "groq"],
        default="huggingface",
        help=(
            "Which model backend to use. `huggingface` (default) talks to "
            "the HF Inference router; `ollama` talks to a local/cloud Ollama "
            "daemon; `groq` talks to Groq Cloud (needs --groq-api-key). "
            "All use the same tool protocol."
        ),
    )
    parser.add_argument("--hf-token",
                        help="Hugging Face API token (required when "
                             "--backend=huggingface)")
    parser.add_argument(
        "--model",
        default="meta-llama/Llama-3.1-70B-Instruct",
        help="Model ID. For HF: e.g. 'meta-llama/Llama-3.1-70B-Instruct'. "
             "For Ollama: e.g. 'qwen2.5-coder:7b' or 'llama3:8b'. "
             "Small models (<7B) frequently fail the tool-call protocol.",
    )
    parser.add_argument(
        "--ollama-base-url",
        default="http://localhost:11434",
        help="Ollama daemon or cloud endpoint URL. Local default is "
             "http://localhost:11434; for Ollama Cloud use "
             "https://api.ollama.ai (or the URL shown in your account).",
    )
    parser.add_argument(
        "--ollama-api-key",
        default="",
        help="Bearer token for cloud-hosted Ollama endpoints. Leave empty "
             "for a local daemon (no auth needed).",
    )
    parser.add_argument(
        "--ollama-num-ctx",
        type=int,
        default=OllamaBackend.DEFAULT_NUM_CTX,
        help="Context window for Ollama. Defaults to 4096. Do NOT raise "
             "this to match the model's Modelfile default (often 128K) — "
             "it explodes KV-cache RAM use.",
    )
    parser.add_argument(
        "--temperature",
        type=float,
        default=0.2,
        help="Sampling temperature. Lower = more deterministic tool calls "
             "(0.2 is the sweet spot for small models); raise to ~0.7 for "
             "more natural free-form answers.",
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=2048,
        help="Hard cap on generated tokens per model call. Covers any tool "
             "call + typical file writes. Raising past ~4096 on a 3B model "
             "(phi3) can push a single iteration over a minute.",
    )
    parser.add_argument(
        "--groq-api-key",
        default="",
        help="Groq Cloud API key (required when --backend=groq). "
             "Get one free at https://console.groq.com/keys.",
    )
    parser.add_argument("--interactive", action="store_true",
                        help="Interactive mode (JSON-per-line protocol)")
    parser.add_argument("--install-deps", action="store_true",
                        help="Install required Python packages and exit")
    parser.add_argument("--base-path", default=".",
                        help="Base path that tools are allowed to touch")

    args = parser.parse_args()

    if args.install_deps:
        ok = install_dependencies(verbose=True)
        sys.exit(0 if ok else 1)

    # Dependency check only matters for the HF backend; the Ollama backend
    # uses stdlib-only code, so it happily runs without huggingface_hub /
    # pydantic installed. Users on a fresh machine who want only local
    # inference shouldn't have to `pip install huggingface_hub` first.
    if args.backend == "huggingface":
        missing = check_dependencies()
        if missing:
            print("[orch] Missing dependencies: " + ", ".join(missing),
                  file=sys.stderr)
            print("[orch] Run `python orchestrator.py --install-deps` first.",
                  file=sys.stderr)
            sys.exit(2)
        _import_runtime()

        if not args.hf_token:
            print("[orch] --hf-token is required for --backend=huggingface.",
                  file=sys.stderr)
            sys.exit(2)

        backend: ModelBackend = HFBackend(
            hf_token=args.hf_token,
            model_id=args.model,
        )
    elif args.backend == "groq":
        # Mirror the HuggingFace dep-check gate so missing packages produce a
        # clean exit(2) with a human-readable message rather than an unhandled
        # ModuleNotFoundError traceback.
        try:
            import groq as _groq_probe  # noqa: F401, PLC0415
        except ImportError:
            print("[orch] Missing dependency: groq", file=sys.stderr)
            print("[orch] Run `python orchestrator.py --install-deps` first.",
                  file=sys.stderr)
            sys.exit(2)

        groq_key = args.groq_api_key or os.environ.get("GROQ_API_KEY", "")
        if not groq_key:
            print("[orch] --groq-api-key (or GROQ_API_KEY env var) is required "
                  "for --backend=groq.", file=sys.stderr)
            sys.exit(2)
        backend = GroqBackend(api_key=groq_key, model_id=args.model)
        print(f"[orch] Using Groq backend, model={args.model}", file=sys.stderr)
    else:  # ollama
        backend = OllamaBackend(
            model_id=args.model,
            base_url=args.ollama_base_url,
            num_ctx=args.ollama_num_ctx,
            api_key=args.ollama_api_key,
        )
        try:
            backend.health_check()
        except Exception as e:  # noqa: BLE001
            print(f"[orch] Ollama not ready: {e}", file=sys.stderr)
            sys.exit(3)
        print(
            f"[orch] Using Ollama backend at {args.ollama_base_url} "
            f"(num_ctx={args.ollama_num_ctx})",
            file=sys.stderr,
        )

    print(
        f"[orch] Local Orchestrator ready. Backend: {args.backend}, "
        f"Model: {args.model}",
        file=sys.stderr,
    )

    orchestrator = Orchestrator(
        backend=backend,
        base_path=args.base_path,
        temperature=args.temperature,
        max_tokens=args.max_tokens,
    )

    if args.interactive:
        # Signal readiness so the client knows the process is up.
        print("__READY__")
        sys.stdout.flush()
        try:
            while True:
                req = _read_interactive_request(sys.stdin)
                if req is None:
                    break  # EOF
                if req.get("new_session"):
                    orchestrator.reset()
                    history = req.get("history") or []
                    if isinstance(history, list):
                        orchestrator.import_history(history)
                prompt = (req.get("prompt") or "").strip()
                if not prompt:
                    # Respect the protocol even for empty prompts.
                    print(RESPONSE_SENTINEL)
                    sys.stdout.flush()
                    continue
                try:
                    response = orchestrator.run(prompt)
                except Exception as e:
                    response = f"Error: {e}"
                # Serialize as a single JSON string so embedded newlines survive.
                print(json.dumps({"response": response}))
                print(RESPONSE_SENTINEL)
                sys.stdout.flush()
        except KeyboardInterrupt:
            print("[orch] Shutdown requested.", file=sys.stderr)
    else:
        # One-shot mode: read raw stdin, answer once.
        prompt = sys.stdin.read().strip()
        if prompt:
            response = orchestrator.run(prompt)
            print(response)
            print(RESPONSE_SENTINEL)


if __name__ == "__main__":
    main()
