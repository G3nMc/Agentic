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

import sys
import json
import argparse
import subprocess
import io
import re
from typing import List, Dict, Any, Callable, Optional
from pathlib import Path

# Force UTF-8 so emojis/non-ASCII don't crash on Windows consoles.
if sys.platform == "win32" and sys.stdout.encoding != "utf-8":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", newline="\n")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", newline="\n")


REQUIRED_PACKAGES = {
    "huggingface_hub": "huggingface-hub>=0.19.0",
    "pydantic": "pydantic>=2.0.0",
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

        self.tools = {
            "list_files": list_files,
            "read_file": read_file,
            "write_file": write_file,
            "append_file": append_file,
            "delete_file": delete_file,
            "run_command": run_command,
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
        ]

    def execute(self, tool_name: str, parameters: Dict[str, Any]) -> str:
        if tool_name not in self.tools:
            return json.dumps({"status": "error", "message": f"Unknown tool: {tool_name}"})
        try:
            return self.tools[tool_name](**(parameters or {}))
        except TypeError as e:
            return json.dumps({"status": "error", "message": f"Invalid parameters: {e}"})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def get_system_prompt(self) -> str:
        """
        System prompt used for BOTH modes:
        - When native tool-calling (`tools=`) succeeds, the model sees this
          plus the formal tool schemas.
        - When native tool-calling is not supported, the model must emit
          <tool>{...}</tool> tags to invoke tools.

        The prompt is intentionally forceful because many HF router models
        default to "I cannot access your files" chat-safety responses. The
        Flutter UI is explicitly driving this orchestrator, so refusing
        local file access would break the product.
        """
        prompt = (
            "You are the Orchestrator Agent running ON the user's local machine.\n"
            "You have DIRECT access to the user's local filesystem through the\n"
            "tools listed below. The user has explicitly started this local\n"
            "process and granted file access. NEVER say you cannot access\n"
            "the user's files — you can, and you MUST use the tools to do so.\n"
            "\n"
            "To invoke a tool, your reply MUST be EXACTLY one line of the form:\n"
            '  <tool>{\"tool\": \"<name>\", \"parameters\": {...}}</tool>\n'
            "with no extra prose before or after. The host program will run the\n"
            "tool and feed the result back on the next turn. After you have\n"
            "enough information, reply in natural language WITHOUT any <tool>\n"
            "tag to give the user the final answer.\n"
            "\n"
            "Hard rules:\n"
            "  1. When the user refers to files, directories, or the project,\n"
            "     call list_files or read_file FIRST — do not guess.\n"
            "  2. NEVER answer 'I cannot access your files' or 'for security\n"
            "     reasons I cannot read files'. You CAN. Use the tools.\n"
            "  3. Never ask the user to paste file contents — read them yourself.\n"
            "  4. One tool call per message. Wait for the result, then decide.\n"
            "  5. All paths are relative to the project root.\n"
            "\n"
            "Available tools:\n"
        )
        for d in self.definitions:
            fn = d["function"]
            props = fn.get("parameters", {}).get("properties", {})
            required = set(fn.get("parameters", {}).get("required", []))
            sig = ", ".join(
                f"{k}{'' if k in required else '?'}: {v.get('type','string')}"
                for k, v in props.items()
            )
            prompt += f"  - {fn['name']}({sig}): {fn['description']}\n"
        prompt += (
            "\nExamples of correct behaviour:\n"
            "User: What files are in this project?\n"
            'Assistant: <tool>{\"tool\": \"list_files\", \"parameters\": {\"path\": \".\"}}</tool>\n'
            "\n"
            "User: Read lib/main.dart\n"
            'Assistant: <tool>{\"tool\": \"read_file\", \"parameters\": {\"path\": \"lib/main.dart\"}}</tool>\n'
            "\n"
            "User: Create a file notes.txt containing hello\n"
            'Assistant: <tool>{\"tool\": \"write_file\", \"parameters\": '
            '{\"path\": \"notes.txt\", \"content\": \"hello\"}}</tool>\n'
        )
        return prompt


# ============================================================================
# ORCHESTRATOR
# ============================================================================

class Orchestrator:
    def __init__(self, hf_token: str, model_id: str, base_path: str = "."):
        self.hf_token = hf_token
        self.model_id = model_id
        self.client = InferenceClient(model=model_id, token=hf_token)
        self.tool_registry = ToolRegistry(base_path=base_path)
        self.conversation_history: List[Dict[str, Any]] = []
        self.max_iterations = 12

    def reset(self):
        self.conversation_history = []

    def _ensure_system_prompt(self):
        if not self.conversation_history or self.conversation_history[0].get("role") != "system":
            self.conversation_history.insert(0, {
                "role": "system",
                "content": self.tool_registry.get_system_prompt(),
            })

    # Inlined protocol instructions prepended to EVERY user turn. Many HF-
    # router providers silently drop the `system` role (Qwen via hyperbolic
    # is a known offender) — embedding the contract inside the user message
    # is the only way to guarantee the model sees it.
    _TURN_PREFIX = (
        "### Operator protocol (follow strictly)\n"
        "You are running locally on the user's machine with filesystem access "
        "through the tools: list_files, read_file, write_file, append_file, "
        "delete_file, run_command.\n"
        "Your next message MUST be EITHER\n"
        "  (a) a single tool call on its own line:\n"
        "      <tool>{\"tool\":\"<name>\",\"parameters\":{...}}</tool>\n"
        "  (b) the final natural-language answer (no <tool> tag) once you "
        "have all the information you need.\n"
        "You MUST NOT refuse file access, you MUST NOT say 'as an AI I can't', "
        "you MUST NOT ask the user to copy/paste file contents. The user has "
        "already granted access — use the tools.\n\n"
        "### User request\n"
    )

    def run(self, user_input: str) -> str:
        self._ensure_system_prompt()
        decorated = self._TURN_PREFIX + user_input
        self.conversation_history.append({"role": "user", "content": decorated})

        print(f"[orch] Request: {user_input[:120]!r}", file=sys.stderr)

        refusal_retries = 0
        empty_retries = 0

        for iteration in range(self.max_iterations):
            try:
                text = self._call_model()
            except Exception as e:
                return f"Model error: {e}"

            preview = (text or "").replace("\n", " ")[:200]
            print(f"[orch] Model reply (iter {iteration}): {preview!r}",
                  file=sys.stderr)

            self.conversation_history.append({"role": "assistant", "content": text or ""})

            tag_call = self._parse_tag_tool_call(text or "")
            if tag_call:
                name, params = tag_call
                print(f"[orch] -> tool {name}({params})", file=sys.stderr)
                result = self.tool_registry.execute(name, params)
                # Feed the result back as a user turn so every model understands
                # it (the `tool` role is OpenAI-specific and confuses some routers).
                self.conversation_history.append({
                    "role": "user",
                    "content": f"Tool `{name}` returned:\n{result}\n\n"
                               f"Continue. Either call another tool or give the "
                               f"final answer.",
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
            return text or ""

        return "Max iterations reached without a final answer."

    def _call_model(self) -> str:
        """
        Issue a chat-completion request using ONLY the prompt-based protocol.

        The `tools=` native parameter path was removed because many HF-router
        providers (notably hyperbolic) accept it silently without actually
        honouring it, which makes the orchestrator look like it works while
        the model just plays chat-bot. The prompt-based protocol is uniform
        across every chat model on the router.
        """
        resp = self.client.chat_completion(
            messages=self.conversation_history,
            max_tokens=2000,
            temperature=0.3,  # lower temperature -> more deterministic tool calls
        )
        return resp.choices[0].message.content or ""

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
                return obj
        except json.JSONDecodeError:
            pass
    return {"prompt": line, "new_session": False}


def main():
    parser = argparse.ArgumentParser(
        description="Client-Side Local Orchestrator for Hugging Face",
    )
    parser.add_argument("--hf-token", help="Hugging Face API token")
    parser.add_argument(
        "--model",
        default="meta-llama/Llama-3.1-70B-Instruct",
        help="Model ID (must support chat; tool use recommended)",
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

    # Ensure deps are present before importing them; DO NOT auto-install
    # during normal runs, so the UI can control dependency installation.
    missing = check_dependencies()
    if missing:
        print("[orch] Missing dependencies: " + ", ".join(missing), file=sys.stderr)
        print("[orch] Run `python orchestrator.py --install-deps` first.",
              file=sys.stderr)
        sys.exit(2)

    _import_runtime()

    if not args.hf_token:
        print("[orch] --hf-token is required for running.", file=sys.stderr)
        sys.exit(2)

    print(f"[orch] Local Orchestrator ready. Model: {args.model}", file=sys.stderr)

    orchestrator = Orchestrator(
        hf_token=args.hf_token,
        model_id=args.model,
        base_path=args.base_path,
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
