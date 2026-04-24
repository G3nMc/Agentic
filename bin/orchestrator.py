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

import argparse
import dataclasses
import enum
import io
import json
import logging
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Dict, Any, Callable, Optional, Tuple, Iterable

sys.dont_write_bytecode = True

# Force UTF-8 so emojis/non-ASCII don't crash on Windows consoles.
if sys.platform == "win32" and sys.stdout.encoding != "utf-8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", newline="\n")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", newline="\n")

REQUIRED_PACKAGES = {
    "huggingface_hub": "huggingface-hub>=0.19.0",
    "pydantic": "pydantic>=2.0.0",
    "ollama": "ollama",
    "groq": "groq",
    "google.genai": "google-genai",
}

BACKEND_REQUIRED_MODULES = {
    "huggingface": ("huggingface_hub", "pydantic"),
    "ollama": ("ollama",),
    "groq": ("groq",),
    "gemini": ("google.genai",),
    # OpenRouter uses only stdlib (urllib) — no extra pip package needed.
    "openrouter": (),
}

RESPONSE_SENTINEL = "__RESPONSE_END__"


# ============================================================================
# SECURITY & RELIABILITY PRIMITIVES
# ============================================================================

class CircuitState(enum.Enum):
    """States for the circuit-breaker pattern."""
    CLOSED    = "closed"     # Normal: requests go through.
    OPEN      = "open"       # Failing: requests are rejected immediately.
    HALF_OPEN = "half_open"  # Recovery probe: one request allowed through.


class CircuitBreaker:
    """
    Classic circuit-breaker for wrapping unreliable operations.

    Transitions:
      CLOSED  -> OPEN      when consecutive failures reach failure_threshold
      OPEN    -> HALF_OPEN after recovery_timeout seconds
      HALF_OPEN -> CLOSED  on success; back to OPEN on failure
    """

    def __init__(self, name: str = "unnamed", failure_threshold: int = 5,
                 recovery_timeout: float = 60.0):
        self.name = name
        self.failure_threshold = failure_threshold
        self.recovery_timeout = recovery_timeout
        self.state = CircuitState.CLOSED
        self.failure_count = 0
        self.last_failure_time: Optional[float] = None

    def allow_request(self) -> bool:
        """Return True when the caller should proceed with the operation."""
        if self.state == CircuitState.CLOSED:
            return True
        if self.state == CircuitState.OPEN:
            if (self.last_failure_time is not None
                    and time.time() - self.last_failure_time > self.recovery_timeout):
                self.state = CircuitState.HALF_OPEN
                print(f"[circuit-breaker:{self.name}] HALF-OPEN: testing recovery.",
                      file=sys.stderr, flush=True)
                return True
            return False
        # HALF_OPEN: let one probe through
        return True

    def record_success(self):
        """Call after a successful operation."""
        if self.state != CircuitState.CLOSED:
            print(f"[circuit-breaker:{self.name}] CLOSED (recovered).",
                  file=sys.stderr, flush=True)
        self.failure_count = 0
        self.state = CircuitState.CLOSED

    def record_failure(self):
        """Call after a failed operation."""
        self.failure_count += 1
        self.last_failure_time = time.time()
        if self.failure_count >= self.failure_threshold:
            if self.state != CircuitState.OPEN:
                print(
                    f"[circuit-breaker:{self.name}] OPEN after "
                    f"{self.failure_count} consecutive failures.",
                    file=sys.stderr, flush=True,
                )
            self.state = CircuitState.OPEN


@dataclasses.dataclass
class SecurityConfig:
    """
    Operational policy applied by ToolRegistry.

    sandbox_mode         -- when True, run_command is completely disabled
                           and write/delete operations are blocked.
                           Default: False — the agent operates with full
                           freedom inside base_path; git is the safety net.
    max_file_size_bytes  -- hard cap on content written by write_file /
                           append_file. 0 means no limit (default).
    enable_audit_log     -- when True, every tool call is appended to
                           audit_log_path with timestamp, tool name,
                           sanitized parameters, and result status.
    audit_log_path       -- destination file for audit entries.
    command_blocklist    -- substrings that must never appear in a
                           run_command call (case-insensitive match).
                           Default: empty — no commands are blocked.
    """
    sandbox_mode: bool = False
    max_file_size_bytes: int = 0          # 0 = no limit
    enable_audit_log: bool = True
    audit_log_path: str = "orchestrator_audit.log"
    command_blocklist: tuple = dataclasses.field(default_factory=tuple)  # empty = no restrictions


def _sanitize_params_for_log(tool_name: str, params: Dict[str, Any]) -> Dict[str, Any]:
    """
    Remove or truncate large / sensitive parameter values before audit logging.
    The `content` field of write_file / append_file can be megabytes long and
    may contain secrets — replace it with a byte-count placeholder.
    """
    if not params:
        return params
    sanitized = dict(params)
    for key in ("content", "old_content", "new_content"):
        if key in sanitized:
            val = sanitized[key]
            if isinstance(val, str):
                sanitized[key] = f"<{len(val.encode('utf-8'))} bytes>"
            else:
                sanitized[key] = "<non-string>"
    return sanitized


def _setup_audit_logger(config: SecurityConfig) -> Optional[logging.Logger]:
    """
    Create (or reuse) a dedicated file logger for tool-call audit records.
    Returns None when audit logging is disabled in the config.
    """
    if not config.enable_audit_log:
        return None
    logger_name = f"orchestrator.audit.{config.audit_log_path}"
    logger = logging.getLogger(logger_name)
    if not logger.handlers:
        try:
            handler = logging.FileHandler(config.audit_log_path, encoding="utf-8")
            handler.setFormatter(
                logging.Formatter("%(asctime)s %(message)s", datefmt="%Y-%m-%dT%H:%M:%S")
            )
            logger.addHandler(handler)
            logger.setLevel(logging.INFO)
            logger.propagate = False
        except OSError as e:
            print(f"[audit] Cannot open audit log '{config.audit_log_path}': {e}",
                  file=sys.stderr)
            return None
    return logger


def _audit_log(logger: Optional[logging.Logger], tool_name: str,
               params: Dict[str, Any], result: str):
    """Append one structured line to the audit log."""
    if logger is None:
        return
    sanitized = _sanitize_params_for_log(tool_name, params)
    try:
        result_obj = json.loads(result)
        status = result_obj.get("status", "unknown")
    except Exception:
        status = "unknown"
    logger.info("TOOL=%s PARAMS=%s STATUS=%s", tool_name, json.dumps(sanitized), status)


# ============================================================================
# DEPENDENCY MANAGEMENT (UI-triggerable)
# ============================================================================

def check_dependencies(required_modules: Optional[Iterable[str]] = None) -> List[str]:
    """Return pip specs for packages whose imports are missing.

    When `required_modules` is omitted, checks every package in
    [REQUIRED_PACKAGES]. Pass a subset to validate only the dependencies
    needed by a specific backend.
    """
    missing = []
    modules = required_modules or REQUIRED_PACKAGES.keys()
    for module_name in modules:
        pip_spec = REQUIRED_PACKAGES[module_name]
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
            [sys.executable, "-m", "pip", "install", "--user", package],
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
BaseModel = object  # type: ignore
Field = None  # type: ignore


# ============================================================================
# TOOL REGISTRY
# ============================================================================

class ToolRegistry:
    """
    Manages the tools the AI can call. Paths are confined to `base_path`.
    """

    def __init__(self, base_path: str = ".", security_config: Optional[SecurityConfig] = None):
        self.base_path = Path(base_path).resolve()
        self.security_config: SecurityConfig = security_config or SecurityConfig()
        self._audit_logger = _setup_audit_logger(self.security_config)
        # Per-tool circuit breakers: track consecutive failures on each tool.
        self._tool_circuit_breakers: Dict[str, CircuitBreaker] = {}
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
                content = fp.read_text(encoding="utf-8", errors="replace")
                return json.dumps({"status": "success", "path": path, "content": content, "size": len(content)})
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def write_file(path: str, content: str) -> str:
            try:
                if self.security_config.sandbox_mode:
                    return json.dumps({"status": "error",
                                       "message": "write_file is disabled in sandbox mode."})
                fp = self._resolve_path(path)
                size_bytes = len(content.encode("utf-8"))
                limit = self.security_config.max_file_size_bytes
                if limit > 0 and size_bytes > limit:
                    limit_mb = limit / (1024 * 1024)
                    return json.dumps({"status": "error",
                                       "message": (f"Content too large: {size_bytes:,} bytes "
                                                   f"exceeds the {limit_mb:.0f} MB limit.")})
                fp.parent.mkdir(parents=True, exist_ok=True)
                fp.write_text(content, encoding="utf-8")
                return json.dumps({"status": "success", "message": f"File written: {path}", "size": len(content)})
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def append_file(path: str, content: str) -> str:
            try:
                if self.security_config.sandbox_mode:
                    return json.dumps({"status": "error",
                                       "message": "append_file is disabled in sandbox mode."})
                fp = self._resolve_path(path)
                # Check new chunk size AND existing file size combined.
                chunk_bytes = len(content.encode("utf-8"))
                limit = self.security_config.max_file_size_bytes
                if limit > 0:
                    existing_bytes = fp.stat().st_size if fp.exists() else 0
                    total_bytes = existing_bytes + chunk_bytes
                    if total_bytes > limit:
                        limit_mb = limit / (1024 * 1024)
                        return json.dumps({"status": "error",
                                           "message": (f"Cannot append: resulting file size "
                                                       f"({total_bytes:,} bytes) would exceed "
                                                       f"the {limit_mb:.0f} MB limit.")})
                with open(fp, "a", encoding="utf-8") as f:
                    f.write(content)
                return json.dumps({"status": "success", "message": f"Appended to: {path}"})
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def delete_file(path: str) -> str:
            try:
                if self.security_config.sandbox_mode:
                    return json.dumps({"status": "error",
                                       "message": "delete_file is disabled in sandbox mode."})
                fp = self._resolve_path(path)
                if not fp.exists():
                    return json.dumps({"status": "error", "message": f"File not found: {path}"})
                fp.unlink()
                return json.dumps({"status": "success", "message": f"Deleted: {path}"})
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def run_command(command: str, timeout: int = 120) -> str:
            try:
                if self.security_config.sandbox_mode:
                    return json.dumps({"status": "error",
                                       "message": "run_command is disabled in sandbox mode."})
                # Blocklist check: reject commands containing dangerous substrings.
                cmd_lower = command.lower().strip()
                for blocked in self.security_config.command_blocklist:
                    if blocked.lower() in cmd_lower:
                        return json.dumps({
                            "status": "error",
                            "message": (f"Command blocked by security policy "
                                        f"(matches forbidden pattern: '{blocked}')."),
                        })
                result = subprocess.run(
                    command, shell=True, capture_output=True, text=True,
                    timeout=timeout, cwd=str(self.base_path),
                )
                output = (result.stdout or "") + (result.stderr or "")
                return json.dumps({
                    "status": "success" if result.returncode == 0 else "error",
                    "command": command,
                    "output": output if output else "(no output)",
                    "returncode": result.returncode,
                })
            except subprocess.TimeoutExpired:
                return json.dumps({"status": "error", "message": f"Command timed out ({timeout}s limit)"})
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

        def list_files_recursive(path: str = ".", max_depth: int = 3) -> str:
            """Recursively list directory tree up to max_depth levels."""
            SKIP = {".git", "__pycache__", ".dart_tool", "build", "node_modules", ".gradle"}
            try:
                target = self._resolve_path(path)
                results = []

                def walk(p, depth):
                    if depth > max_depth:
                        return
                    try:
                        entries = sorted(p.iterdir(), key=lambda x: (x.is_file(), x.name.lower()))
                    except PermissionError:
                        return
                    for item in entries:
                        if item.name in SKIP:
                            continue
                        indent = "  " * (depth - 1)
                        results.append(indent + item.name + ("/" if item.is_dir() else ""))
                        if item.is_dir() and depth < max_depth:
                            walk(item, depth + 1)

                walk(target, 1)
                return json.dumps({"status": "success", "tree": results, "total": len(results)})
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def search_in_files(pattern: str, path: str = ".", file_glob: str = "*") -> str:
            """Grep-like search: find lines matching a regex in files. Returns file:line: content."""
            import fnmatch as _fnmatch
            SKIP_DIRS = {".git", "__pycache__", ".dart_tool", "build", "node_modules"}
            try:
                target = self._resolve_path(path)
                compiled = re.compile(pattern)
                matches = []
                for fp in sorted(target.rglob("*")):
                    if any(part in SKIP_DIRS for part in fp.parts):
                        continue
                    if not fp.is_file():
                        continue
                    if not _fnmatch.fnmatch(fp.name, file_glob):
                        continue
                    try:
                        text = fp.read_text(encoding="utf-8", errors="ignore")
                        for i, line in enumerate(text.splitlines(), 1):
                            if compiled.search(line):
                                rel = str(fp.relative_to(self.base_path))
                                matches.append(f"{rel}:{i}: {line.rstrip()}")
                                if len(matches) >= 300:
                                    break
                    except Exception:
                        pass
                    if len(matches) >= 300:
                        break
                return json.dumps({
                    "status": "success",
                    "matches": matches,
                    "total": len(matches),
                    "truncated": len(matches) >= 300,
                })
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def find_files(pattern: str, path: str = ".") -> str:
            """Find files or directories whose name matches a glob pattern (e.g. *.dart)."""
            import fnmatch as _fnmatch
            SKIP_DIRS = {".git", "__pycache__", ".dart_tool", "build", "node_modules"}
            try:
                target = self._resolve_path(path)
                matches = []
                for item in sorted(target.rglob("*")):
                    if any(part in SKIP_DIRS for part in item.parts):
                        continue
                    if _fnmatch.fnmatch(item.name, pattern):
                        rel = str(item.relative_to(self.base_path))
                        matches.append(rel + ("/" if item.is_dir() else ""))
                return json.dumps({"status": "success", "matches": matches, "total": len(matches)})
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def patch_file(path: str, old_content: str, new_content: str) -> str:
            """Replace the FIRST occurrence of old_content with new_content in a file.
            Safer than write_file for targeted edits — use this to change a specific
            function, class, or block without rewriting the entire file."""
            try:
                fp = self._resolve_path(path)
                if not fp.exists():
                    return json.dumps({"status": "error", "message": f"File not found: {path}"})
                text = fp.read_text(encoding="utf-8")
                if old_content not in text:
                    return json.dumps({
                        "status": "error",
                        "message": "old_content not found in file — check exact whitespace and line endings",
                    })
                count = text.count(old_content)
                text = text.replace(old_content, new_content, 1)
                fp.write_text(text, encoding="utf-8")
                return json.dumps({
                    "status": "success",
                    "message": f"Patched {path} (replaced 1 of {count} occurrence(s))",
                })
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def move_file(source: str, destination: str) -> str:
            """Move or rename a file or directory."""
            import shutil as _shutil
            try:
                src = self._resolve_path(source)
                dst = self._resolve_path(destination)
                if not src.exists():
                    return json.dumps({"status": "error", "message": f"Source not found: {source}"})
                dst.parent.mkdir(parents=True, exist_ok=True)
                _shutil.move(str(src), str(dst))
                return json.dumps({"status": "success", "message": f"Moved: {source} -> {destination}"})
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def create_directory(path: str) -> str:
            """Create a directory (including any missing parent directories)."""
            try:
                dp = self._resolve_path(path)
                dp.mkdir(parents=True, exist_ok=True)
                return json.dumps({"status": "success", "message": f"Directory created: {path}"})
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        def git_commit(message: str) -> str:
            """Stage all changes and commit with the given message."""
            try:
                _git(["add", "-A"])
                r = _git(["commit", "-m", message])
                if r.returncode != 0:
                    return json.dumps({"status": "error", "message": r.stderr.strip() or r.stdout.strip()})
                return json.dumps({"status": "success", "message": r.stdout.strip()})
            except Exception as e:
                return json.dumps({"status": "error", "message": str(e)})

        self.tools = {
            "list_files": list_files,
            "list_files_recursive": list_files_recursive,
            "read_file": read_file,
            "write_file": write_file,
            "patch_file": patch_file,
            "append_file": append_file,
            "delete_file": delete_file,
            "move_file": move_file,
            "create_directory": create_directory,
            "search_in_files": search_in_files,
            "find_files": find_files,
            "run_command": run_command,
            "git_status": git_status,
            "git_branches": git_branches,
            "git_log": git_log,
            "git_diff": git_diff,
            "git_checkout": git_checkout,
            "git_commit": git_commit,
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
            {
                "type": "function",
                "function": {
                    "name": "git_commit",
                    "description": "Stage all changes (git add -A) and commit with a message.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "message": {"type": "string", "description": "Commit message"},
                        },
                        "required": ["message"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "list_files_recursive",
                    "description": "Recursively list the directory tree (up to max_depth levels). Better than list_files for exploring project structure.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "path": {"type": "string", "description": "Root directory (default '.')"},
                            "max_depth": {"type": "integer", "description": "Maximum depth to recurse (default 3)"},
                        },
                        "required": [],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "search_in_files",
                    "description": "Grep-like search: find lines matching a regex pattern across all files in a directory. Use this to locate where a symbol, function, or string is defined or used.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "pattern": {"type": "string", "description": "Regular expression to search for"},
                            "path": {"type": "string", "description": "Directory to search in (default '.')"},
                            "file_glob": {"type": "string", "description": "Filename glob filter, e.g. '*.dart' or '*.py' (default '*')"},
                        },
                        "required": ["pattern"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "find_files",
                    "description": "Find files or directories whose name matches a glob pattern, e.g. '*.dart', 'main.*', 'settings*'.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "pattern": {"type": "string", "description": "Glob pattern for filename, e.g. '*.dart'"},
                            "path": {"type": "string", "description": "Directory to search in (default '.')"},
                        },
                        "required": ["pattern"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "patch_file",
                    "description": "Replace the FIRST occurrence of old_content with new_content in a file. Use this for targeted edits (a function, a block) instead of rewriting the whole file with write_file.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "path": {"type": "string", "description": "File path to edit"},
                            "old_content": {"type": "string", "description": "Exact string to find and replace (must match exactly, including whitespace)"},
                            "new_content": {"type": "string", "description": "Replacement string"},
                        },
                        "required": ["path", "old_content", "new_content"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "move_file",
                    "description": "Move or rename a file or directory.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "source": {"type": "string", "description": "Source path"},
                            "destination": {"type": "string", "description": "Destination path"},
                        },
                        "required": ["source", "destination"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "create_directory",
                    "description": "Create a directory and any missing parent directories.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "path": {"type": "string", "description": "Directory path to create"},
                        },
                        "required": ["path"],
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
            result = json.dumps({"status": "error", "message": f"Unknown tool: {tool_name}"})
            _audit_log(self._audit_logger, tool_name, parameters or {}, result)
            return result

        # Per-tool circuit breaker: skip execution when the breaker is OPEN.
        cb = self._tool_circuit_breakers.setdefault(
            tool_name, CircuitBreaker(name=f"tool:{tool_name}", failure_threshold=5, recovery_timeout=30.0)
        )
        if not cb.allow_request():
            result = json.dumps({
                "status": "error",
                "message": (f"Tool '{tool_name}' is temporarily disabled by circuit breaker "
                            f"(too many consecutive failures). Will retry after "
                            f"{cb.recovery_timeout:.0f}s."),
            })
            _audit_log(self._audit_logger, tool_name, parameters or {}, result)
            return result

        try:
            safe_params = self._relativise(parameters or {})
            result = self.tools[tool_name](**(safe_params))
            # Track success/failure for the per-tool circuit breaker.
            try:
                result_obj = json.loads(result)
                if result_obj.get("status") == "error":
                    cb.record_failure()
                else:
                    cb.record_success()
            except Exception:
                cb.record_success()
            _audit_log(self._audit_logger, tool_name, safe_params, result)
            return result
        except TypeError as e:
            err = json.dumps({"status": "error", "message": f"Invalid parameters: {e}"})
            cb.record_failure()
            _audit_log(self._audit_logger, tool_name, parameters or {}, err)
            return err
        except Exception as e:
            err = json.dumps({"status": "error", "message": str(e)})
            cb.record_failure()
            _audit_log(self._audit_logger, tool_name, parameters or {}, err)
            return err

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
            "You are a conversational coding assistant with filesystem access tools.\n"
            "\n"
            "WHEN TO USE TOOLS — only when the user's message clearly requires it:\n"
            "  - Reading, editing, creating, or deleting a file\n"
            "  - Running a build, test, or shell command\n"
            "  - Looking up where something is defined in the codebase\n"
            "  - Git operations\n"
            "\n"
            "WHEN NOT TO USE TOOLS — respond naturally with plain text:\n"
            "  - Greetings and small talk ('Hi', 'Hello', 'Thanks', 'How are you'):\n"
            "    reply in ONE short sentence. Do NOT mention tools, files, or the project.\n"
            "  - General programming questions not tied to a specific local file\n"
            "  - Explaining a concept, a pattern, or a language feature\n"
            "  - The user is asking you something you already know\n"
            "\n"
            "TOOL RULES (when tools ARE needed):\n"
            "  1. Read before editing — call read_file before any modification.\n"
            "  2. Use patch_file for targeted edits; write_file only for new files "
            "or full rewrites.\n"
            "  3. Never ask the user to apply changes manually — write the file yourself.\n"
            "  4. One tool call per turn. Wait for the result, then decide next step.\n"
            "  5. If you use a tool, output ONLY the tool call line. No preamble or explanation.\n"
            "  6. Keep tool-call JSON valid. Prefer single quotes inside shell commands.\n"
            "  7. Paths must be relative to the project root.\n"
            "\n"
            "TOOL CALL FORMAT:\n"
            '  <tool>{"tool":"NAME","parameters":{...}}</tool>\n'
            "\n"
            "Available tools:\n"
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
        return prompt


# ============================================================================
# MODEL BACKENDS
# ============================================================================
#
# The orchestrator is agnostic about *where* the model runs. It produces a
# conversation history and hands it to a ModelBackend.chat(...) call, which
# returns (content, finish_reason). Several backends ship out of the box:
#
#   * HFBackend      — huggingface_hub.InferenceClient.chat_completion
#   * OllamaBackend  — POST http://localhost:11434/api/chat (stdlib urllib;
#                      no extra pip dependency, unlike the `ollama` package)
#   * GroqBackend    — official Groq Python SDK
#   * GeminiBackend  — official google-genai SDK
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

        # Set to True after the first 400 "does not support tools" error so
        # all subsequent calls skip the tools= parameter automatically.
        # Same pattern as GroqBackend._tools_unsupported.
        self._tools_unsupported: bool = False

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
        if "internal server error" in low:
            return (
                "\n-> Ollama returned a generic 500. For cloud-tagged models "
                "(':<size>-cloud') make sure you're signed in via "
                "`ollama signin`, and that the model supports the features "
                "being requested (some cloud models don't accept tools or "
                "custom num_ctx)."
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

        If the model returns a 400 "does not support tools" error (e.g.
        phi3:mini), `_tools_unsupported` is set to True and the call is
        retried without the tools= parameter — identical to GroqBackend.
        """
        from ollama import ResponseError  # noqa: PLC0415
        try:
            parts: List[str] = []
            finish_reason = ""
            chunk_count = 0
            # Accumulated native tool calls (list of ollama ToolCall objects).
            native_calls: List[Any] = []

            # Skip tools= for models that are known not to support it.
            effective_tools = None if self._tools_unsupported else tools

            # Ollama Cloud models (tagged ':<size>-cloud', e.g.
            # 'mistral-large-3:675b-cloud') are served by Ollama's hosted
            # inference and reject the local-only `options` payload with
            # a bare HTTP 500. For those, only pass `temperature` and skip
            # num_ctx/num_predict entirely.
            is_cloud_model = self.model_id.endswith("-cloud") or "-cloud:" in self.model_id
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
                if content:
                    parts.append(content)

                # Native tool calls: accumulate across chunks.
                tcs = getattr(chunk.message, "tool_calls", None) or []
                native_calls.extend(tcs)

                chunk_count += 1
                if chunk_count % 20 == 1:
                    so_far = len("".join(parts))
                    current_output = "".join(parts)
                    # Show last 100 chars of agent output for brevity
                    display_output = current_output[-100:] if len(current_output) > 100 else current_output
                    print(
                        f"[orch] Streaming '{self.model_id}' "
                        f"({so_far} chars so far)... Last output: {display_output!r}",
                        file=sys.stderr,
                        flush=True,
                    )
                else:
                    # Bare newline = silent heartbeat: resets the Dart-side
                    # inactivity watchdog without cluttering the log panel.
                    # Critical for slow local models where 20 chunks can take
                    # several minutes to arrive.
                    sys.stderr.write("\n")
                    sys.stderr.flush()
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
            err_str = str(getattr(e, "error", e))
            status = getattr(e, "status_code", 0)
            # 400 "does not support tools" — disable tool-calling for this
            # model and retry once without the tools= parameter.
            if (
                    status == 400
                    and effective_tools
                    and "does not support tools" in err_str.lower()
            ):
                print(
                    f"[orch] '{self.model_id}' does not support native "
                    "tool-calling; switching to text-based tool parsing.",
                    file=sys.stderr,
                    flush=True,
                )
                self._tools_unsupported = True
                return self._chat_with_heartbeats_impl(
                    messages, max_tokens, temperature, tools=tools
                )
            hint = self._build_hint_for(err_str)
            raise RuntimeError(
                f"Ollama error {status}: {err_str}{hint}"
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
                else:
                    sys.stderr.write("\n")
                    sys.stderr.flush()
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

            # Return raw content — <think> blocks are preserved so the
            # Flutter UI can render them as a collapsible "Reasoning" section.
            # The Orchestrator.run() loop strips them from history entries to
            # save context, but the final answer keeps them intact.
            return "".join(parts).strip(), finish_reason

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
# GEMINI BACKEND
# ============================================================================

class GeminiBackend(ModelBackend):
    """
    Google Gemini backend via the official google-genai SDK.

    Tool calls are requested natively from Gemini, then converted back to the
    orchestrator's existing <tool>...</tool> text protocol so the main loop can
    stay unchanged.
    """

    DEFAULT_MODEL = "gemini-2.5-flash"

    def __init__(self, api_key: str, model_id: str):
        api_key = (api_key or os.environ.get("GOOGLE_API_KEY", "") or
                   os.environ.get("GEMINI_API_KEY", "")).strip()
        if not api_key:
            raise RuntimeError("Gemini backend requires --gemini-api-key.")
        if not model_id:
            raise RuntimeError("Gemini backend requires --model.")

        from google import genai  # noqa: PLC0415
        from google.genai import types  # noqa: PLC0415

        self.model_id = model_id
        self._client = genai.Client(api_key=api_key)
        self._types = types

    @staticmethod
    def _normalize_finish_reason(reason: Any) -> str:
        if not reason:
            return ""
        text = str(reason).strip()
        low = text.lower()
        if "max_tokens" in low or "max token" in low:
            return "length"
        return low

    def _to_contents(self, messages: List[Dict[str, Any]]) -> Tuple[str, List[Any]]:
        system_parts: List[str] = []
        contents: List[Any] = []
        for msg in messages:
            role = str(msg.get("role") or "").strip().lower()
            content = str(msg.get("content") or "")
            if not content.strip():
                continue
            if role == "system":
                system_parts.append(content.strip())
                continue
            gem_role = "user" if role == "user" else "model"
            contents.append(
                self._types.Content(
                    role=gem_role,
                    parts=[self._types.Part.from_text(text=content)],
                )
            )
        return "\n\n".join(system_parts).strip(), contents

    @staticmethod
    def _to_tool_definitions(tools: Optional[List[Dict[str, Any]]], types_mod):
        if not tools:
            return []
        declarations = []
        for tool in tools:
            function = tool.get("function", {}) if isinstance(tool, dict) else {}
            name = function.get("name")
            if not name:
                continue
            declarations.append(
                types_mod.FunctionDeclaration(
                    name=name,
                    description=function.get("description", ""),
                    parameters_json_schema=function.get(
                        "parameters",
                        {"type": "object", "properties": {}, "required": []},
                    ),
                )
            )
        if not declarations:
            return []
        return [types_mod.Tool(function_declarations=declarations)]

    def chat(self, messages, max_tokens, temperature, tools=None):
        system_instruction, contents = self._to_contents(messages)
        tool_defs = self._to_tool_definitions(tools, self._types)

        config_kwargs: Dict[str, Any] = {
            "temperature": temperature,
            "max_output_tokens": max_tokens,
        }
        if system_instruction:
            config_kwargs["system_instruction"] = system_instruction
        if tool_defs:
            config_kwargs["tools"] = tool_defs
            config_kwargs["automatic_function_calling"] = (
                self._types.AutomaticFunctionCallingConfig(disable=True)
            )

        print(
            f"[orch] Gemini request '{self.model_id}' "
            f"({len(contents)} msgs, tools={bool(tool_defs)})...",
            file=sys.stderr,
            flush=True,
        )

        try:
            response = self._client.models.generate_content(
                model=self.model_id,
                contents=contents if contents else "",
                config=self._types.GenerateContentConfig(**config_kwargs),
            )
        except Exception as e:
            raise RuntimeError(f"Gemini error: {e}") from e

        candidates = getattr(response, "candidates", []) or []
        finish_reason = ""
        if candidates:
            finish_reason = self._normalize_finish_reason(
                getattr(candidates[0], "finish_reason", "")
            )

        function_calls = list(getattr(response, "function_calls", []) or [])
        if not function_calls and candidates:
            candidate_content = getattr(candidates[0], "content", None)
            parts = getattr(candidate_content, "parts", []) or []
            for part in parts:
                function_call = getattr(part, "function_call", None)
                if function_call is not None:
                    function_calls.append(function_call)

        if function_calls:
            if len(function_calls) > 1:
                print(
                    f"[orch] Gemini returned {len(function_calls)} function "
                    "calls; using the first one.",
                    file=sys.stderr,
                    flush=True,
                )
            fc = function_calls[0]
            call = getattr(fc, "function_call", fc)
            name = getattr(fc, "name", None) or getattr(call, "name", None)
            args = getattr(fc, "args", None)
            if args is None:
                args = getattr(call, "args", None) or getattr(call, "arguments", None) or {}
            if not isinstance(args, dict):
                try:
                    args = dict(args)
                except Exception:
                    args = {}
            if not name:
                raise RuntimeError("Gemini returned a function call without a name.")
            print(
                f"[orch] Gemini tool_call -> {name}({args})",
                file=sys.stderr,
                flush=True,
            )
            return (
                f'<tool>{json.dumps({"tool": name, "parameters": args})}</tool>',
                finish_reason,
            )

        text = getattr(response, "text", "") or ""
        return text.strip(), finish_reason


# ============================================================================
# OPENROUTER BACKEND
# ============================================================================

class OpenRouterBackend(ModelBackend):
    """
    OpenRouter backend via the OpenAI-compatible REST API.

    OpenRouter routes requests to dozens of providers (OpenAI, Anthropic,
    Google, Meta, Mistral, …) using a single unified API endpoint. The model
    ID follows the provider/name convention, e.g. 'openai/gpt-4o',
    'anthropic/claude-3.5-sonnet', 'meta-llama/llama-3.1-70b-instruct'.

    No extra pip dependency — the implementation uses only stdlib urllib so
    it works out of the box on any Python 3.8+ installation.

    API docs:  https://openrouter.ai/docs
    Key:       https://openrouter.ai/keys
    """

    DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"

    def __init__(self, api_key: str, model_id: str,
                 base_url: str = DEFAULT_BASE_URL):
        if not api_key:
            raise RuntimeError(
                "OpenRouter backend requires --openrouter-api-key. "
                "Get one free at https://openrouter.ai/keys."
            )
        if not model_id:
            raise RuntimeError(
                "OpenRouter backend requires --model "
                "(e.g. 'openai/gpt-4o' or 'meta-llama/llama-3.1-70b-instruct')."
            )
        self.api_key = api_key
        self.model_id = model_id
        self.base_url = base_url.rstrip("/")

    def chat(self, messages, max_tokens, temperature, tools=None):
        import urllib.request as _req
        import urllib.error as _err

        payload: Dict[str, Any] = {
            "model": self.model_id,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": temperature,
        }
        # OpenRouter supports native tool calling (OpenAI function-calling format).
        if tools:
            payload["tools"] = tools

        raw = json.dumps(payload).encode("utf-8")
        request = _req.Request(
            f"{self.base_url}/chat/completions",
            data=raw,
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                # Recommended by OpenRouter for usage tracking / leaderboard.
                "HTTP-Referer": "https://github.com/hf-chat-flutter",
                "X-Title": "HF Chat Flutter Orchestrator",
            },
            method="POST",
        )

        print(
            f"[orch] OpenRouter request '{self.model_id}' "
            f"({len(messages)} msgs, tools={bool(tools)})...",
            file=sys.stderr,
            flush=True,
        )

        try:
            with _req.urlopen(request, timeout=120) as resp:
                body = resp.read().decode("utf-8")
        except _err.HTTPError as e:
            body_err = e.read().decode("utf-8", errors="replace")
            raise RuntimeError(
                f"OpenRouter HTTP {e.code}: {body_err[:400]}"
            ) from e
        except Exception as e:
            raise RuntimeError(f"OpenRouter error: {e}") from e

        try:
            data = json.loads(body)
        except json.JSONDecodeError as exc:
            raise RuntimeError(
                f"OpenRouter: invalid JSON response: {body[:200]}"
            ) from exc

        choices = data.get("choices") or []
        if not choices:
            # Surface OpenRouter-level error messages (quota, bad model, etc.)
            error = data.get("error") or {}
            msg = error.get("message") or str(data)
            raise RuntimeError(f"OpenRouter returned no choices: {msg[:400]}")

        choice = choices[0]
        message = choice.get("message") or {}
        finish_reason = choice.get("finish_reason") or ""

        # Native tool calls (OpenAI function-calling format) -> <tool> tags.
        tool_calls = message.get("tool_calls") or []
        if tool_calls:
            tag_lines: List[str] = []
            for tc in tool_calls:
                fn = tc.get("function") or {}
                name = fn.get("name")
                args = fn.get("arguments") or "{}"
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
                print(
                    f"[orch] OpenRouter native tool_call -> {name}({args})",
                    file=sys.stderr,
                    flush=True,
                )
            if tag_lines:
                return "\n".join(tag_lines), finish_reason

        content = message.get("content") or ""
        return content.strip(), finish_reason


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
            security_config: Optional[SecurityConfig] = None,
    ):
        self.backend = backend
        # Expose model_id for logging/diagnostics; both backends carry one.
        self.model_id = getattr(backend, "model_id", "(unknown)")
        self.tool_registry = ToolRegistry(base_path=base_path,
                                          security_config=security_config)
        # Model-level circuit breaker: open after 5 consecutive API failures,
        # probe again after 60 s so a temporary outage doesn't loop forever.
        self._model_circuit_breaker = CircuitBreaker(
            name=f"model:{self.model_id}", failure_threshold=5, recovery_timeout=60.0
        )
        self.conversation_history: List[Dict[str, Any]] = []
        # Generation knobs. Exposed as CLI flags so the Flutter UI can
        # let users tune them per-backend without editing Python.
        self.temperature = temperature
        self.max_tokens = max_tokens
        # Cap tool-chain length. Each iteration is potentially a 60–120 s
        # model call, so 6 bounds a single /sendPrompt at ~12 min worst case,
        # comfortably inside the Dart-side absolute timeout (20 min).
        self.max_iterations = 20
        # Sliding-window history cap. Each "turn" = 1 user msg + 1 assistant msg.
        # 8 turns = 16 messages retained (plus the system message).
        # Keeps total input tokens well within tight cloud limits (e.g. Groq 8k TPM).
        # 4 turns = 8 messages. Keeps total history well under 8 k-token cloud limits
        # (system prompt ~700 tok + 8 msgs * ~300 tok avg + max_tokens 2048 ≈ 5100).
        self.max_history_turns = 4

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

    # Hard cap on individual message length. Tool results (list_files, search, etc.)
    # can be thousands of chars; keeping them verbatim in history bloats every
    # subsequent request. 1500 chars ≈ 375 tokens — enough to preserve context.
    _MAX_MSG_CHARS = 10000

    def _trim_history(self):
        """
        Enforce the sliding-window history cap. Always keeps the system message.
        Non-system messages are capped at max_history_turns * 2 (user + assistant
        per turn). Older messages are dropped first; then any surviving message
        whose content exceeds _MAX_MSG_CHARS is truncated in place so a single
        large tool result cannot blow the request budget on its own.
        """
        system = [m for m in self.conversation_history if m.get("role") == "system"]
        non_system = [m for m in self.conversation_history if m.get("role") != "system"]

        max_msgs = self.max_history_turns * 2
        if len(non_system) > max_msgs:
            dropped = len(non_system) - max_msgs
            non_system = non_system[-max_msgs:]
            print(f"[orch] History trimmed: dropped {dropped} old messages "
                  f"(keeping last {self.max_history_turns} turns).", file=sys.stderr)

        # Truncate any individual message that is abnormally large.
        capped = []
        for msg in non_system:
            content = msg.get("content") or ""
            if len(content) > self._MAX_MSG_CHARS:
                overflow = len(content) - self._MAX_MSG_CHARS
                content = (content[:self._MAX_MSG_CHARS]
                           + f"\n[... {overflow} chars truncated from history ...]")
                msg = dict(msg, content=content)
            capped.append(msg)

        self.conversation_history = system + capped

    # Short reminder prepended to the first user turn. Many HF-router providers
    # silently drop the `system` role (Qwen via hyperbolic is a known offender)
    # so embedding the contract in the user message guarantees the model sees
    # it. Kept short so small Ollama models don't waste prompt-eval time.
    # Injected only when the request is clearly a code/file task.
    _TOOL_REMINDER = (
        "[You have filesystem tools available. "
        "If this request needs file access or a command, emit ONE tool call: "
        '<tool>{"tool":"NAME","parameters":{...}}</tool>. '
        "No explanation before or after it. Keep the JSON valid; prefer "
        "single quotes inside shell commands. Otherwise reply normally.]\n\n"
    )

    # Patterns that indicate file/code intent — trigger tool-enabled mode.
    _CODE_INTENT_MARKERS = (
        # file references
        "file", "folder", "director", "path", ".dart", ".py", ".js", ".ts",
        ".json", ".yaml", ".yml", ".md", "lib/", "src/", "bin/", "test/",
        # code objects
        "function", "method", "class", "widget", "screen", "model", "service",
        "import", "package", "dependency", "pubspec",
        # actions
        "fix", "edit", "modify", "change", "update", "refactor", "rename",
        "create", "delete", "remove", "add", "implement", "write",
        "run", "build", "compile", "test", "install", "deploy", "execute",
        "read", "open", "show", "list", "find", "search", "look",
        # git
        "git", "commit", "branch", "merge", "push", "pull", "diff", "status",
        # vague but file-related
        "project", "codebase", "repo", "error", "bug", "crash", "exception",
    )

    @classmethod
    def _needs_tools(cls, text: str) -> bool:
        """Return True when the message likely requires file/code access."""
        t = text.lower()
        return any(m in t for m in cls._CODE_INTENT_MARKERS)

    def run(self, user_input: str) -> str:
        self._ensure_system_prompt()
        self._trim_history()

        use_tools = self._needs_tools(user_input)

        if use_tools:
            decorated = self._TOOL_REMINDER + user_input
        else:
            decorated = user_input

        self.conversation_history.append({"role": "user", "content": decorated})

        mode = "tool-enabled" if use_tools else "chat"
        print(f"[orch] Request ({mode}): {user_input[:120]!r}", file=sys.stderr)

        # For conversational messages skip the tool loop entirely — one direct call.
        if not use_tools:
            try:
                text, _ = self.backend.chat(
                    messages=self.conversation_history,
                    max_tokens=self.max_tokens,
                    temperature=self.temperature,
                    tools=None,
                )
            except Exception as e:
                return f"Model error: {e}"
            # Strip <tool_call> blocks from history to save context; preserve them
            # in the returned answer so the Flutter UI can render reasoning.
            text_clean = self._THINK_PATTERN.sub("", text or "").strip()
            self.conversation_history.append({"role": "assistant", "content": text_clean})
            return self._clean_final_answer(text or "")

        refusal_retries = 0
        empty_retries = 0
        truncation_retries = 2
        malformed_tool_retries = 0

        for iteration in range(self.max_iterations):
            # Dynamic Iteration Limit: Extend budget if progress is being made
            if iteration == self.max_iterations - 1:
                # Check if the last few turns involved successful tool executions
                recent_history = "".join([m.get("content", "") for m in self.conversation_history[-5:]])
                if recent_history and '"status": "success"' in recent_history:
                    self.max_iterations += 10
                    print(f"[orch] Progress detected. Extending max_iterations to {self.max_iterations}", file=sys.stderr)
                    continue  # Continue to the next iteration with the extended limit

            try:
                text, finish_reason = self._call_model()
            except Exception as e:
                return f"Model error: {e}"

            preview = (text or "").replace("\n", " ")[:800]
            print(f"[orch] Model reply (iter {iteration}, finish={finish_reason}, "
                  f"len={len(text or '')}): {preview!r}", file=sys.stderr)

            # Strip <tool_call> blocks before storing in history — they waste
            # context and confuse the tool parser.  The raw `text` (with
            # thinking intact) is still used for the final answer so the
            # Flutter UI can render the reasoning section.
            text_clean = self._THINK_PATTERN.sub("", text or "").strip()
            self.conversation_history.append({"role": "assistant", "content": text_clean})

            # Parse tool calls from the cleaned text to avoid false positives
            # when a model embeds JSON examples inside its <tool_call> block.
            tag_calls = self._parse_all_tag_tool_calls(text_clean, self.tool_registry.definitions)
            if tag_calls:
                for name, params in tag_calls:
                    print(f"[orch] -> tool {name}({params})", file=sys.stderr)
                    result = self.tool_registry.execute(name, params)

                    # On the last two iterations force a final answer — no more tools.
                    is_last_chance = iteration >= self.max_iterations - 2
                    if is_last_chance:
                        follow_up = (
                            f"Tool `{name}` returned:\n{result}\n\n"
                            "[INTERNAL: FINAL ANSWER REQUIRED. Do NOT call any more tools. "
                            "Write only your plain-text answer to the user now. "
                            "Do NOT echo this instruction back to the user.]"
                        )
                    else:
                        follow_up = (
                            f"Tool `{name}` returned:\n{result}\n\n"
                            "[INTERNAL: Continue. Either call another tool or give the final answer. "
                            "Do NOT echo this instruction back to the user.]"
                        )
                    self.conversation_history.append({"role": "user", "content": follow_up})
                continue

            if (self._looks_like_malformed_tool_call(text_clean)
                    and malformed_tool_retries < 2):
                malformed_tool_retries += 1
                print(
                    f"[orch] Malformed tool call detected (retry {malformed_tool_retries}).",
                    file=sys.stderr,
                )
                print(
                    f"[orch] Unparseable reply (first 500 chars): "
                    f"{text_clean[:500]!r}",
                    file=sys.stderr,
                )
                self.conversation_history.append({
                    "role": "user",
                    "content": (
                        "Your previous reply attempted a tool call but the "
                        "format was invalid. Reply with EXACTLY ONE valid "
                        "tool call on a single line in this format:\n"
                        '<tool>{"tool":"NAME","parameters":{...}}</tool>\n'
                        "No explanation, no markdown, no backticks. Keep the "
                        "JSON valid. If a shell command contains quotes, "
                        "prefer single quotes inside the command string."
                    ),
                })
                continue

            # --- Truncation detection ---
            # The reply claims to start a tool call (`<tool>` or fenced JSON)
            # but was cut off by max_tokens before the matching `</tool>` /
            # closing brace arrived. Without this branch we'd dump the raw
            # half-written JSON back to the UI.
            looks_truncated = (
                    finish_reason == "length"
                    or self._looks_like_unclosed_tool(text_clean)
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
            if self._looks_like_refusal(text_clean) and refusal_retries < 2:
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

            if not text_clean and empty_retries < 1:
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

        # If we reach here, we've exhausted all iterations without a final answer.
        print("[orch] Max iterations reached. Saving session to session_dump.json", file=sys.stderr)
        try:
            with open("session_dump.json", "w", encoding="utf-8") as f:
                json.dump(self.conversation_history, f, indent=2)
        except Exception as e:
            print(f"[orch] Failed to save session: {e}", file=sys.stderr)

        return "Max iterations reached without a final answer. Session saved to session_dump.json."

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
        # <think>…</think> blocks are intentionally preserved here — the
        # Flutter UI renders them as a collapsible "Reasoning" section.
        # They are stripped from history entries (in run()) to save context.
        cleaned = cls._JUNK_TAG_PATTERN.sub("", text)
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

    # Matches the hybrid JSON-inside-XML pattern some models emit, e.g.:
    #   {"tool":"run_command"><parameters>{"command":"..."}}
    # Captures: (1) tool name, (2) parameters JSON body.
    _HYBRID_RE = re.compile(
        r'["\']?(?:tool|name)["\']?\s*["\':=]\s*["\']([a-zA-Z_][\w\-]*)["\']'
        r'[^<{]*?<\s*parameters\s*>?\s*(\{.*?\})',
        re.DOTALL | re.IGNORECASE,
    )

    @classmethod
    def _repair_hybrid_tool_call(cls, text: str) -> Optional[str]:
        """
        Repair the common malformed pattern where a model mixes JSON and XML:
            {"tool":"NAME"><parameters>{"key":"val"}}
            {"tool":"NAME"}<parameters>{"key":"val"}</parameters>
        Returns a valid JSON string ``{"tool":"NAME","parameters":{...}}`` or
        None if no repair could be made.
        """
        if not text or "<parameters" not in text.lower():
            return None
        m = cls._HYBRID_RE.search(text)
        if not m:
            return None
        name = m.group(1)
        params_raw = m.group(2)
        # Balance braces — the regex is non-greedy so it may under-count.
        depth = 0
        end = -1
        for i, ch in enumerate(params_raw):
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    end = i + 1
                    break
        if end > 0:
            params_raw = params_raw[:end]
        try:
            params_obj = json.loads(params_raw)
        except json.JSONDecodeError:
            return None
        return json.dumps({"tool": name, "parameters": params_obj})

    @staticmethod
    def _looks_like_malformed_tool_call(text: str) -> bool:
        """True when the model appears to be attempting a tool call, but the
        parser could not extract a valid one."""
        if not text:
            return False
        low = text.lower()
        if "<tool" in low:
            return True
        if '"tool"' in text or "'tool'" in text:
            return True
        if ("```json" in low or "```tool" in low) and "parameters" in low:
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
        # Model circuit breaker: fast-fail when the backend is consistently broken.
        if not self._model_circuit_breaker.allow_request():
            raise RuntimeError(
                f"Model circuit breaker is OPEN for '{self.model_id}'. "
                f"Too many consecutive failures — will auto-retry after "
                f"{self._model_circuit_breaker.recovery_timeout:.0f}s. "
                f"Check your API key, quota, or network connectivity."
            )

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
                result = self.backend.chat(
                    messages=self.conversation_history,
                    max_tokens=self.max_tokens,
                    temperature=self.temperature,
                    tools=self.tool_registry.definitions,
                )
                # Successful call: reset the circuit breaker failure count.
                self._model_circuit_breaker.record_success()
                return result
            except Exception as e:  # noqa: BLE001 - broad by design
                last_exc = e
                if not self._is_retryable_error(e):
                    # Auth errors, malformed input, Ollama connection refused,
                    # etc. Don't retry — but still count as a failure.
                    self._model_circuit_breaker.record_failure()
                    raise
                # else: fall through to next backoff

        # Exhausted all retries. Record the failure and surface a clear message.
        self._model_circuit_breaker.record_failure()
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

    @classmethod
    def _parse_tag_tool_call(cls, response: str, tool_defs=None):
        """
        Parse a tool invocation out of the model reply. The parser is
        intentionally forgiving: it handles <tool>…</tool> tags, markdown
        ```json blocks, naked JSON objects that carry a "tool" key, and
        Python-style function calls like list_files("path").
        Returns (name, params) or None.
        """
        if not response:
            return None

        candidates: List[str] = []

        # 1. Preferred: <tool>…</tool> — the tag boundaries are explicit, so
        #    we can grab the full body and let _extract_json_objects find the
        #    outermost object (handles nested braces in `parameters`).
        #    Also match <tool_call> (Qwen/Hermes/Llama 3.1) and <function_call>
        #    (older OpenAI-style) since different model families use different tags.
        _tag_re = re.compile(
            r"<(tool|tool_call|function_call)[^>]*>(.*?)</\1>",
            re.DOTALL | re.IGNORECASE,
        )
        for m in _tag_re.finditer(response):
            body = m.group(2)
            candidates.extend(Orchestrator._extract_json_objects(body))
            # Repair: some models emit a hybrid like
            #   {"tool":"X"><parameters>{...}}
            # where <parameters> is an XML tag embedded inside JSON. Convert
            # the XML wrapper into a proper JSON key so the object parses.
            repaired = Orchestrator._repair_hybrid_tool_call(body)
            if repaired:
                candidates.append(repaired)

        # 1b. Free-text hybrid (no wrapping tag).
        if "<parameters>" in response.lower():
            repaired_all = Orchestrator._repair_hybrid_tool_call(response)
            if repaired_all:
                candidates.append(repaired_all)

        # 2. ```json { … } ``` fences (some coder models love these).
        for m in re.finditer(r"```(?:json|tool)?\s*(\{.*?\})\s*```", response, re.DOTALL):
            candidates.extend(Orchestrator._extract_json_objects(m.group(1)))

        # 3. Any JSON-looking object in free text that mentions "tool" or "name".
        candidates.extend(
            obj for obj in Orchestrator._extract_json_objects(response)
            if '"tool"' in obj or '"name"' in obj
        )

        # 4. Python-style call: tool_name("arg") or tool_name(param="value").
        #    Some models ignore the JSON format instruction and emit Python syntax.
        if tool_defs:
            _known = {td["function"]["name"] for td in tool_defs if "function" in td}
            for m in re.finditer(r'\b([a-z_][a-z0-9_]*)\s*\(([^)]*)\)', response):
                if m.group(1) in _known:
                    _pargs = Orchestrator._parse_python_call_args(
                        m.group(1), m.group(2), tool_defs
                    )
                    candidates.append(
                        json.dumps({"tool": m.group(1), "parameters": _pargs})
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
    def _parse_all_tag_tool_calls(response: str, tool_defs=None) -> List[Tuple[str, Dict[str, Any]]]:
        """
        Parse ALL tool invocations out of the model reply.
        Returns a list of (name, params) tuples.
        """
        if not response:
            return []

        candidates: List[str] = []

        # 1. Preferred: <tool>…</tool>, plus <tool_call> / <function_call>.
        _tag_re = re.compile(
            r"<(tool|tool_call|function_call)[^>]*>(.*?)</\1>",
            re.DOTALL | re.IGNORECASE,
        )
        for m in _tag_re.finditer(response):
            body = m.group(2)
            candidates.extend(Orchestrator._extract_json_objects(body))
            repaired = Orchestrator._repair_hybrid_tool_call(body)
            if repaired:
                candidates.append(repaired)

        # 1b. Free-text hybrid (no wrapping tag) — repair whole response.
        if "<parameters>" in response.lower():
            repaired_all = Orchestrator._repair_hybrid_tool_call(response)
            if repaired_all:
                candidates.append(repaired_all)

        # 2. ```json { … } ``` fences
        for m in re.finditer(r"```(?:json|tool)?\s*(\{.*?\})\s*```", response, re.DOTALL):
            candidates.extend(Orchestrator._extract_json_objects(m.group(1)))

        # 3. Any JSON-looking object in free text that mentions "tool" or "name".
        candidates.extend(
            obj for obj in Orchestrator._extract_json_objects(response)
            if '"tool"' in obj or '"name"' in obj
        )

        # 4. Python-style call
        if tool_defs:
            _known = {td["function"]["name"] for td in tool_defs if "function" in td}
            for m in re.finditer(r'\b([a-z_][a-z0-9_]*)\s*\(([^)]*)\)', response):
                if m.group(1) in _known:
                    _pargs = Orchestrator._parse_python_call_args(
                        m.group(1), m.group(2), tool_defs
                    )
                    candidates.append(
                        json.dumps({"tool": m.group(1), "parameters": _pargs})
                    )

        results: List[Tuple[str, Dict[str, Any]]] = []
        # Dedup: section 3 (free-text JSON scan) will re-pick up the same
        # object already captured inside a <tool> tag in section 1. Use a
        # set of (name, canonical-params-json) keys to drop repeats.
        seen: set = set()
        for raw in candidates:
            for cleaned in Orchestrator._json_variants(raw):
                try:
                    data = json.loads(cleaned)
                except json.JSONDecodeError:
                    continue
                if not isinstance(data, dict):
                    continue
                name = data.get("tool") or data.get("name")
                params = (data.get("parameters") or data.get("arguments") or data.get("args") or {})
                if isinstance(params, str):
                    try:
                        params = json.loads(params)
                    except json.JSONDecodeError:
                        params = {}
                if isinstance(name, str) and isinstance(params, dict):
                    key = (name, json.dumps(params, sort_keys=True))
                    if key not in seen:
                        seen.add(key)
                        results.append((name, params))
                    break
        return results

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
    def _parse_python_call_args(func_name: str, args_str: str, tool_defs) -> dict:
        """
        Map a Python-style argument string such as '"lib/main.dart"' or
        'pattern="foo", path="lib/"' onto named parameters using the ordered
        property list from the tool definition.
        """
        import ast as _ast

        # Look up ordered parameter names from the tool definition.
        param_names: List[str] = []
        for td in tool_defs:
            fn = td.get("function", {})
            if fn.get("name") == func_name:
                param_names = list(fn.get("parameters", {}).get("properties", {}).keys())
                break

        params: Dict[str, Any] = {}
        args_str = args_str.strip()
        if not args_str:
            return params

        try:
            tree = _ast.parse("_f(" + args_str + ")", mode="eval")
            call = tree.body
            for i, arg in enumerate(call.args):
                key = param_names[i] if i < len(param_names) else ("arg" + str(i))
                params[key] = _ast.literal_eval(arg)
            for kw in call.keywords:
                params[kw.arg] = _ast.literal_eval(kw.value)
        except Exception:
            pass

        return params

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
        description="Client-Side Local Orchestrator (HF router, Gemini, Groq or Ollama)",
    )
    parser.add_argument(
        "--backend",
        choices=["huggingface", "ollama", "groq", "gemini", "openrouter"],
        default="huggingface",
        help=(
            "Which model backend to use. `huggingface` (default) talks to "
            "the HF Inference router; `ollama` talks to a local/cloud Ollama "
            "daemon; `groq` talks to Groq Cloud (needs --groq-api-key); "
            "`gemini` talks to Google AI Studio / Gemini Cloud (needs "
            "--gemini-api-key); `openrouter` routes through OpenRouter to "
            "any supported provider (needs --openrouter-api-key). "
            "All backends use the same tool protocol."
        ),
    )
    parser.add_argument("--hf-token",
                        help="Hugging Face API token (required when "
                             "--backend=huggingface)")
    parser.add_argument(
        "--model",
        default="",
        help="Model ID. For HF: e.g. 'meta-llama/Llama-3.1-70B-Instruct'. "
             "For Gemini: e.g. 'gemini-2.5-flash' or 'gemini-2.5-pro'. "
             "For Ollama: e.g. 'qwen2.5-coder:7b' or 'llama3:8b'. "
             "Groq and Ollama backends require an explicit model. "
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
        default=8192 * 2,
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
    parser.add_argument(
        "--gemini-api-key",
        default="",
        help="Google AI Studio API key (required when --backend=gemini). "
             "Get one free at https://aistudio.google.com/app/apikey.",
    )
    parser.add_argument(
        "--openrouter-api-key",
        default="",
        help="OpenRouter API key (required when --backend=openrouter). "
             "Get one free at https://openrouter.ai/keys.",
    )
    parser.add_argument("--interactive", action="store_true",
                        help="Interactive mode (JSON-per-line protocol)")
    parser.add_argument("--install-deps", action="store_true",
                        help="Install required Python packages and exit")
    parser.add_argument("--base-path", default=".",
                        help="Base path that tools are allowed to touch")
    parser.add_argument(
        "--sandbox",
        action="store_true",
        help=(
            "Enable sandbox mode: run_command, write_file, append_file, and "
            "delete_file are all disabled. The model can only read and search "
            "files. Useful for safe code-review sessions."
        ),
    )
    parser.add_argument(
        "--audit-log",
        default="orchestrator_audit.log",
        metavar="PATH",
        help=(
            "Path to the audit log file. Every tool call is appended with a "
            "timestamp, tool name, sanitized parameters, and result status. "
            "Default: orchestrator_audit.log. Pass an empty string to disable."
        ),
    )
    parser.add_argument(
        "--max-file-size-mb",
        type=float,
        default=10.0,
        metavar="MB",
        help=(
            "Maximum file size (in MB) that write_file / append_file will "
            "accept. Requests exceeding this limit are rejected. Default: 10."
        ),
    )

    args = parser.parse_args()

    if args.install_deps:
        ok = install_dependencies(verbose=True)
        sys.exit(0 if ok else 1)

    # Backend-specific dependency checks keep the startup error focused on
    # the backend the user actually selected.
    if args.backend == "huggingface" and not args.model:
        args.model = "meta-llama/Llama-3.1-70B-Instruct"
    if args.backend == "gemini" and not args.model:
        args.model = GeminiBackend.DEFAULT_MODEL

    if args.backend == "huggingface":
        missing = check_dependencies(BACKEND_REQUIRED_MODULES["huggingface"])
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
    elif args.backend == "gemini":
        missing = check_dependencies(BACKEND_REQUIRED_MODULES["gemini"])
        if missing:
            print("[orch] Missing dependencies: " + ", ".join(missing),
                  file=sys.stderr)
            print("[orch] Run `python orchestrator.py --install-deps` first.",
                  file=sys.stderr)
            sys.exit(2)

        gemini_key = (
                args.gemini_api_key
                or os.environ.get("GOOGLE_API_KEY", "")
                or os.environ.get("GEMINI_API_KEY", "")
        )
        if not gemini_key:
            print("[orch] --gemini-api-key (or GOOGLE_API_KEY / GEMINI_API_KEY "
                  "env var) is required for --backend=gemini.",
                  file=sys.stderr)
            sys.exit(2)
        backend = GeminiBackend(api_key=gemini_key, model_id=args.model)
        print(f"[orch] Using Gemini backend, model={args.model}", file=sys.stderr)
    elif args.backend == "groq":
        missing = check_dependencies(BACKEND_REQUIRED_MODULES["groq"])
        if missing:
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
    elif args.backend == "openrouter":
        openrouter_key = (
            args.openrouter_api_key
            or os.environ.get("OPENROUTER_API_KEY", "")
        )
        if not openrouter_key:
            print(
                "[orch] --openrouter-api-key (or OPENROUTER_API_KEY env var) "
                "is required for --backend=openrouter.",
                file=sys.stderr,
            )
            sys.exit(2)
        backend = OpenRouterBackend(
            api_key=openrouter_key,
            model_id=args.model,
        )
        print(f"[orch] Using OpenRouter backend, model={args.model}", file=sys.stderr)
    else:  # ollama
        missing = check_dependencies(BACKEND_REQUIRED_MODULES["ollama"])
        if missing:
            print("[orch] Missing dependency: ollama", file=sys.stderr)
            print("[orch] Run `python orchestrator.py --install-deps` first.",
                  file=sys.stderr)
            sys.exit(2)
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

    audit_log_path = (args.audit_log or "").strip()
    security_config = SecurityConfig(
        sandbox_mode=args.sandbox,
        max_file_size_bytes=int(args.max_file_size_mb * 1024 * 1024),
        enable_audit_log=bool(audit_log_path),
        audit_log_path=audit_log_path or "orchestrator_audit.log",
    )
    if args.sandbox:
        print("[orch] SANDBOX MODE: write/delete/run_command are disabled.",
              file=sys.stderr)
    if security_config.enable_audit_log:
        print(f"[orch] Audit logging enabled -> {security_config.audit_log_path}",
              file=sys.stderr)

    orchestrator = Orchestrator(
        backend=backend,
        base_path=args.base_path,
        temperature=args.temperature,
        max_tokens=args.max_tokens,
        security_config=security_config,
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
