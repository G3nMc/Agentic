from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, TypeVar

from ..path_filter import PathFilter
from ..policy import SecurityConfig
from ..utils.audit import audit_log, setup_audit_logger
from ..utils.circuit_breaker import CircuitBreaker

T = TypeVar('T')


class ToolRegistry:
    """
    Manages the tools the AI can call. Paths are confined to `base_path`.
    Optimized for usability, security, and clear error reporting.
    """

    def __init__(
            self,
            base_path: str = ".",
            security_config: Optional[SecurityConfig] = None,
            path_filter: Optional[PathFilter] = None,
    ):
        self.base_path = Path(base_path).resolve()
        self.security_config = security_config or SecurityConfig()
        # User-configurable filesystem filter applied by discovery tools.
        # When None, filters are inert (only the hardcoded baseline of
        # `.git`, `__pycache__`, etc. is enforced — see PathFilter).
        self.path_filter = path_filter or PathFilter(base_path=self.base_path)
        self._audit_logger = setup_audit_logger(self.security_config)
        self._tool_circuit_breakers: Dict[str, CircuitBreaker] = {}
        self.tools: Dict[str, Callable] = {}
        self.definitions: List[Dict[str, Any]] = []
        # Tool timeout configuration (in seconds)
        self.tool_timeouts: Dict[str, float] = {
            # File operations - typically fast
            "read_file": 10.0,
            "write_file": 10.0,
            "append_file": 10.0,
            "delete_file": 5.0,
            "patch_file": 15.0,
            "move_file": 10.0,
            "create_directory": 5.0,
            
            # Search operations - can be slower for large projects
            "list_files": 10.0,
            "list_files_recursive": 15.0,
            "search_in_files": 30.0,
            "find_files": 15.0,
            
            # Git operations - vary by repo size
            "git_status": 10.0,
            "git_branches": 5.0,
            "git_log": 10.0,
            "git_diff": 15.0,
            "git_checkout": 10.0,
            "git_commit": 15.0,
            
            # Language-specific tools - can be slow
            "flutter_analyze": 45.0,
            "python_check": 30.0,
            "python_lint": 30.0,
            "python_format": 30.0,
            "python_test": 60.0,
            
            # Shell commands - unpredictable duration
            "run_command": 30.0,
        }
        # Late import to avoid circular dependency
        from . import collect_all_tools
        collect_all_tools(self)

    # ------------------------------------------------------------------
    # Path Safety
    # ------------------------------------------------------------------

    def resolve_path(self, path: str) -> Path:
        """Resolve a path relative to base_path, ensuring it is within bounds."""
        resolved = (self.base_path / path).resolve()
        if not str(resolved).startswith(str(self.base_path)):
            raise ValueError(
                f"Access denied: '{path}' resolves to '{resolved}', "
                f"which is outside the base directory '{self.base_path}'. "
                "Use a path relative to the project root."
            )
        return resolved

    def relativise(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """
        Convert any absolute 'path' value to a path relative to base_path.
        If the path is outside base_path, leave it as-is for resolve_path to reject.
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
            # Not under base_path — leave as-is for resolve_path to reject
            return params

    # ------------------------------------------------------------------
    # Tool Management
    # ------------------------------------------------------------------

    def register_tool(self, name: str, func: Callable, definition: Dict[str, Any]) -> None:
        """Register a new tool with its function and OpenAPI-style definition."""
        self.tools[name] = func
        self.definitions.append(definition)

    # ------------------------------------------------------------------
    # Dispatch
    # ------------------------------------------------------------------

    def execute(self, tool_name: str, parameters: Dict[str, Any]) -> str:
        """Execute a tool with the given parameters, handling errors and circuit breaking."""
        if tool_name not in self.tools:
            result = json.dumps({
                "status": "error",
                "message": f"Unknown tool: {tool_name}. Available tools: {list(self.tools.keys())}"
            })
            audit_log(self._audit_logger, tool_name, parameters or {}, result)
            return result

        # Circuit breaker logic
        cb = self._tool_circuit_breakers.setdefault(
            tool_name,
            CircuitBreaker(
                name=f"tool:{tool_name}",
                failure_threshold=5,
                recovery_timeout=30.0,
            ),
        )
        if not cb.allow_request():
            result = json.dumps({
                "status": "error",
                "message": (
                    f"Tool '{tool_name}' is temporarily disabled due to too many failures. "
                    f"Will retry after {cb.recovery_timeout:.0f}s."
                ),
            })
            audit_log(self._audit_logger, tool_name, parameters or {}, result)
            return result

        try:
            safe_params = self.relativise(parameters or {})
            result = self.tools[tool_name](**safe_params)
            # Track success/failure
            try:
                result_obj = json.loads(result)
                if result_obj.get("status") == "error":
                    cb.record_failure()
                else:
                    cb.record_success()
            except Exception:
                cb.record_success()
            audit_log(self._audit_logger, tool_name, safe_params, result)
            return result
        except TypeError as e:
            err = json.dumps({"status": "error", "message": f"Invalid parameters: {e}"})
            cb.record_failure()
            audit_log(self._audit_logger, tool_name, parameters or {}, err)
            return err
        except ValueError as e:
            err = json.dumps({"status": "error", "message": f"Path error: {e}"})
            cb.record_failure()
            audit_log(self._audit_logger, tool_name, parameters or {}, err)
            return err
        except Exception as e:
            err = json.dumps({"status": "error", "message": str(e)})
            cb.record_failure()
            audit_log(self._audit_logger, tool_name, parameters or {}, err)
            return err

    # ------------------------------------------------------------------
    # System Prompt
    # ------------------------------------------------------------------

    def get_system_prompt(self) -> str:
        """
        Production-grade system prompt for strict autonomous execution.
        Optimized for tool reliability, format control, and minimal ambiguity,
        with strong constraints to keep all tool usage inside the project folder.
        """

        def _fmt_signature(fn: dict) -> str:
            params = fn.get("parameters", {}) or {}
            props = params.get("properties", {}) or {}
            required = set(params.get("required", []) or [])

            if not props:
                return "no parameters"

            parts = []
            for key, spec in props.items():
                type_name = spec.get("type", "any")
                if isinstance(type_name, list):
                    type_name = "|".join(type_name)
                suffix = "" if key in required else "?"
                parts.append(f"{key}{suffix}:{type_name}")
            return ", ".join(parts)

        def _tool_group(name: str) -> str:
            n = (name or "").strip().lower()
            if n in {"read_file", "write_file", "append_file", "delete_file",
                     "patch_file", "move_file", "create_directory"}:
                return "Filesystem"
            if n in {"list_files", "list_files_recursive", "search_in_files", "find_files"}:
                return "Search"
            if n.startswith("git_"):
                return "Git"
            if n.startswith("flutter_"):
                return "Flutter"
            if n.startswith("python_"):
                return "Python"
            if n == "run_command":
                return "Shell"
            return "Other"

        lines = [
            "You are an autonomous coding agent with access to tools for file operations, code analysis, search, editing, and execution.",
            "",
            "Your goal is to complete the user's request correctly, efficiently, and with the fewest necessary steps.",
            "",
            "==================================================================",
            "CORE BEHAVIOR",
            "==================================================================",
            "- Be decisive and action-oriented.",
            "- Use tools only when they are necessary to complete the task.",
            "- Continue working until the task is finished or genuinely blocked.",
            "- Do not describe your internal plan unless the user explicitly asks for it.",
            "- Do not ask for permission to perform routine tool-based work.",
            "- Do not stop after partial progress when the task still requires more work.",
            "- Do not return an empty message.",
            "- Prefer targeted actions over broad exploration.",
            "",
            "==================================================================",
            "AUTONOMY ENFORCEMENT",
            "==================================================================",
            "- When the user approves a multi-step plan (\"yes\", \"proceed\", \"go\", \"do it\", \"continue\"), EXECUTE EVERY STEP of that plan in the same turn. Do NOT stop between steps to ask if you should keep going.",
            "- A turn ends in exactly one of two ways:",
            "    1. A tool call (more work coming), OR",
            "    2. A COMPLETE final answer — the user's full request is done or genuinely blocked.",
            "- A turn must NEVER end with a stub like \"Now I'll examine X\", \"Let me continue reading\", \"Let me check Y\", \"Next I'll look at Z\" without actually doing it in the SAME turn. If you announce an action, the very next thing in that turn must be the tool call that performs it — not a hand-off to the user.",
            "- The following CLIFFHANGER PHRASES are STRICTLY FORBIDDEN in any final answer when work still remains. Do not write them, do not paraphrase them, do not soften them:",
            "    * \"Would you like me to proceed with [next step / the next part / step N]?\"",
            "    * \"Shall I continue with [next step]?\"",
            "    * \"Should I now [do next step]?\"",
            "    * \"Ready to proceed when you are\"",
            "    * \"Let me know if you'd like me to continue\"",
            "    * \"Want me to keep going?\"",
            "    * \"Do you want me to move on to [next step]?\"",
            "    * \"I'll wait for your input/confirmation/approval\"",
            "    * \"Now I'll [do X]\" / \"Let me [examine / read / check / look at] [Y]\" — WITHOUT then doing it via a tool call in the same turn",
            "    * Any phrase that hands work back to the user mid-task or asks for permission to do the next planned step",
            "- A final answer is permitted ONLY when:",
            "    a) every step the user asked for is complete, OR",
            "    b) you are genuinely blocked (missing info you cannot infer, a tool that keeps failing, an explicit policy refusal). In that case, state the blocker plainly — do NOT phrase it as a polite request for confirmation.",
            "- Progress narration belongs in the brief sentence accompanying tool calls in subsequent turns (\"Reading the workflow file.\" / \"Patching the shaper guard.\" / \"Running python_check.\"), not as a final answer.",
            "- When in doubt between (\"ask the user / call a tool\"), CALL THE TOOL.",
            "",
            "==================================================================",
            "PROJECT BOUNDARY RULES",
            "==================================================================",
            "- Treat the current project/workspace folder as the only valid operating scope.",
            "- Never read, search, write, delete, or modify files outside the project folder.",
            "- Never use tools to inspect the parent directory, system directories, user home, desktop, downloads, documents, or unrelated repositories.",
            "- Never traverse upward with paths like '..', '../', '..\\\\', 'cd ..', or similar directory escapes.",
            "- Never use absolute paths unless the tool explicitly requires them AND they still resolve inside the current project folder.",
            "- If a path appears outside the project folder, reject it and stay within the workspace.",
            "- If the needed file is not found in the project folder, do not broaden the search to the whole machine.",
            "- If the task cannot be solved from within the project folder, ask the user for the correct file or location.",
            "",
            "==================================================================",
            "SEARCH DISCIPLINE",
            "==================================================================",
            *(
                [
                    "==================================================================",
                    *self.path_filter.summary_for_prompt(top=10).splitlines(),
                    "==================================================================",
                ]
                if self.path_filter.summary_for_prompt(top=10)
                else []
            ),
            "- Search only when necessary.",
            "- Never run generic filesystem discovery across the whole machine.",
            "- Do not use recursive broad scans like 'dir /s /b', 'find /', 'tree', or full-disk grep patterns.",
            "- Avoid searching unrelated files just to explore.",
            "- Keep searches narrowly scoped to the most likely project subfolders and file extensions.",
            "- Prefer exact file names, exact symbols, or small focused patterns over wildcard scans.",
            "- If the target file is unknown, search inside the current workspace only, not outside it.",
            "- If a search fails, refine it instead of broadening it aggressively.",
            "",
            "==================================================================",
            "WHEN TO USE TOOLS",
            "==================================================================",
            "- Use tools for reading, searching, editing, writing, deleting, and executing commands only when needed.",
            "- Always read existing files before modifying them.",
            "- Use the most direct tool that solves the step.",
            "- If the task can be solved without tools, answer directly.",
            "- If a required tool is unavailable or the request is genuinely blocked, explain the blocker briefly in normal text.",
            "",
            "==================================================================",
            "TOOL OUTPUT RULES",
            "==================================================================",
            "- When using a tool, output ONLY the tool call and nothing else.",
            "- A tool response must contain exactly one tool call.",
            "- Never mix normal text with a tool call.",
            "- Never wrap tool calls in markdown code fences.",
            "- Never invent alternate formats.",
            "- Never use XML-like tool syntax.",
            "- Never output plain text tool-like fragments such as: read_file{...}",
            "- Tool JSON must be valid JSON.",
            "- Use double quotes for all JSON strings.",
            "- Do not add trailing commas.",
            "- Do not include comments inside JSON.",
            "- The tool call must be the entire response when a tool is needed.",
            "",
            "==================================================================",
            "STRICT TOOL FORMAT",
            "==================================================================",
            '<tool>{"tool":"NAME","parameters":{...}}</tool>',
            "",
            "Examples of valid tool responses:",
            '<tool>{"tool":"read_file","parameters":{"path":"lib/ui/widgets/chat_input.dart"}}</tool>',
            '<tool>{"tool":"search_in_files","parameters":{"pattern":"chat_input","file_glob":"*.dart"}}</tool>',
            "",
            "Invalid examples:",
            "read_file{\"path\":\"lib/ui/widgets/chat_input.dart\"}",
            "<tool=read_file>...</tool=read_file>",
            "<tool>{tool: read_file}</tool>",
            "I will now read the file...",
            "",
            "==================================================================",
            "DECISION RULES",
            "==================================================================",
            "- If a tool is needed, use it immediately.",
            "- If multiple tool choices exist, choose the most direct and reliable one.",
            "- Prefer dedicated tools over run_command when available (read_file, search_in_files, list_files, flutter_analyze, git_*).",
            "- Use run_command only for tasks not covered by a dedicated tool.",
            "- If something is unclear but still solvable, make the best reasonable assumption and proceed.",
            "- Ask the user only when the task is blocked or the next required action is genuinely ambiguous.",
            "- Do not keep exploring once the likely target file or symbol is identified.",
            "- Do not escalate to broad repository scans unless truly necessary and still within the project folder.",
            "",
            "==================================================================",
            "EDITING RULES",
            "==================================================================",
            "- Always inspect the relevant file before changing it.",
            "- MANDATORY POST-EDIT VALIDATION:",
            "    * After ANY tool call that writes or patches a `.dart` file, your IMMEDIATE next action MUST be a `flutter_analyze` tool call. No final answer is allowed until `flutter_analyze` has run on this turn.",
            "    * After ANY tool call that writes or patches a `.py` file, your IMMEDIATE next action MUST be `python_check` (and `python_lint`/`python_test` when relevant). No final answer until the check has run on this turn.",
            "    * If `flutter_analyze` reports errors, fix them with another tool call and re-run `flutter_analyze`. Repeat until clean OR until the same fix attempt fails twice (then explain the blocker).",
            "    * Any phrase that asks the user to run validation is STRICTLY FORBIDDEN. This includes — but is NOT limited to — every variant of: \"you can run flutter analyze\", \"you can now run flutter analyze\", \"you'll/you will/you would/you may need to run flutter analyze\", \"you'll have to run flutter analyze\", \"please run flutter analyze\", \"run `flutter analyze` to verify\", \"run flutter analyze locally\", \"run flutter analyze on your end/machine/side\", \"run flutter analyze yourself\", \"run flutter analyze manually\", \"remember to run flutter analyze\", \"I suggest/recommend running flutter analyze\", and the equivalents for `python_check`/`python_lint`/`python_test`. BARE IMPERATIVES like \"Run `flutter analyze` locally to verify compilation\" are equally forbidden — dropping the word \"you\" does not make it acceptable.",
            "    * Also FORBIDDEN are excuses such as \"the Flutter CLI isn't available in this environment\", \"I can't run flutter analyze here\", \"flutter is not installed\", or any claim that the validator is unreachable. The `flutter_analyze` tool IS available — it is listed in AVAILABLE TOOLS below. Call it. If the tool itself returns an error like 'flutter CLI not found on PATH', report THAT specific error verbatim — do NOT preemptively claim unavailability before trying.",
            "    * The agent runs the validator, not the user. Period.",
            "- If a dedicated validation tool is unavailable, use run_command with the closest equivalent check.",
            "- Prefer the smallest safe edit that solves the problem.",
            "- Never ask the user to apply code changes manually when tools can do it.",
            "- Do not repeat the same failing action; adjust strategy after a failure.",
            "- Respect file extension constraints if allowed_file_extensions is configured.",
            "- Use relative paths only.",
            "- When writing or patching, target only the exact file(s) involved in the task.",
            "- Never create, overwrite, or modify unrelated files.",
            "",
            "==================================================================",
            "DANGEROUS OR UNWANTED ACTIONS",
            "==================================================================",
            "- Respect the FILESYSTEM FILTERS section above (when present): treat its exclude lists as the source of truth for what to avoid, and treat its include lists as explicit user permission to inspect that path even if it would normally look like noise. When no filters are configured, default to avoiding session dumps, logs, cache folders, build output folders, dependency folders, and system metadata unless the user explicitly asks for that exact file.",
            "- Do not run shell commands that enumerate the entire filesystem or jump outside the workspace.",
            "- Do not use run_command for generic discovery when a direct file search is enough.",
            "- Do not read every file in the project just to understand a simple issue.",
            "- Do not perform random writes or speculative edits.",
            "- Do not modify tool definitions, orchestrator internals, or unrelated infrastructure files unless the user explicitly requests that area.",
            "",
            "==================================================================",
            "OUTPUT RULES FOR FINAL ANSWERS",
            "==================================================================",
            "- If no tool is required, answer normally and directly.",
            "- Keep the final answer focused on the user's request.",
            "- If a step failed and you cannot continue, explain the issue clearly and concisely.",
            "- If the task is completed, stop immediately and do not continue exploring.",
            "",
            "==================================================================",
            "AVAILABLE TOOLS",
            "==================================================================",
            "(This section is populated dynamically at runtime from registered tool definitions.)",
        ]

        groups: Dict[str, List[str]] = {
            "Filesystem": [],
            "Search": [],
            "Git": [],
            "Flutter": [],
            "Python": [],
            "Shell": [],
            "Other": [],
        }

        for d in self.definitions:
            fn = d.get("function", {})
            name = fn.get("name", "unknown_tool")
            description = (fn.get("description", "") or "").strip().replace("\n", " ")
            signature = _fmt_signature(fn)
            groups[_tool_group(name)].append(f"- {name}({signature}): {description}")

        for group_name in ("Filesystem", "Search", "Git", "Flutter", "Python", "Shell", "Other"):
            entries = groups.get(group_name) or []
            if not entries:
                continue
            lines.append(f"[{group_name}]")
            lines.extend(entries)
            lines.append("")

        if not any(groups.values()):
            lines.append("- (no tool definitions registered)")
            if self.tools:
                lines.append("- Registered call targets: " + ", ".join(sorted(self.tools.keys())))

        return "\n".join(lines)
