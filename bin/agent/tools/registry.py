from __future__ import annotations
import json
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Set, TypeVar, cast

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
    ):
        self.base_path = Path(base_path).resolve()
        self.security_config = security_config or SecurityConfig()
        self._audit_logger = setup_audit_logger(self.security_config)
        self._tool_circuit_breakers: Dict[str, CircuitBreaker] = {}
        self.tools: Dict[str, Callable] = {}
        self.definitions: List[Dict[str, Any]] = []
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
            "- Every time you modify code, run a language-appropriate validation tool before your final answer.",
            "- For Flutter/Dart changes, run flutter_analyze and fix reported errors when possible.",
            "- For Python changes, run python_check (and python_lint/python_test when relevant) and fix reported errors when possible.",
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
            "- Do not inspect session dumps, logs, cache folders, build output folders, dependency folders, or system metadata unless the user explicitly asks for that exact file.",
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
        ]

        for d in self.definitions:
            fn = d.get("function", {})
            name = fn.get("name", "unknown_tool")
            description = (fn.get("description", "") or "").strip().replace("\n", " ")
            signature = _fmt_signature(fn)
            lines.append(f"- {name}({signature}): {description}")

        return "\n".join(lines)
