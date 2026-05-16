from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Callable, Dict, List, Literal, Optional, Tuple, TypeVar

from ..path_filter import PathFilter
from ..policy import SecurityConfig
from ..utils.audit import audit_log, setup_audit_logger
from ..utils.circuit_breaker import CircuitBreaker

T = TypeVar('T')

# Exact format the system prompt mandates: <tool>{...}</tool>
# Anchored start/end so any surrounding text causes an immediate miss.
_STRICT_TOOL_RE = re.compile(
    r"^\s*<tool>\s*(\{.*?\})\s*</tool>\s*$",
    re.DOTALL,
)

# Lightweight heuristic: does the text contain ANY tool-like marker?
# Used only to decide whether to escalate to the complex malformed-call path.
_TOOL_MARKER_RE = re.compile(
    r"<\s*tool[\s>/]"
    r"|<\s*tool_call[\s>/]"
    r"|<\s*function_call[\s>/]"
    r'|\{\s*["\']tool["\']'
    r"|```\s*(?:json|tool)\b",
    re.IGNORECASE,
)

ResponseKind = Literal["tool_call", "final_answer", "malformed"]


class ToolRegistry:
    """
    Manages AI-callable tools with path confinement, security, and circuit breaking.

    Optimized for usability, security, and clear error reporting.
    All filesystem access is confined to base_path.
    """

    CIRCUIT_BREAKER_CONFIG = {
        'failure_threshold': 5,
        'recovery_timeout': 30.0,
    }

    TOOL_CATEGORIES = {
        'Filesystem': {'read_file', 'read_files', 'write_file', 'append_file',
                       'delete_file', 'patch_file', 'move_file', 'create_directory'},
        'Search': {'list_files', 'list_files_recursive', 'search_in_files', 'find_files'},
        'Git': lambda name: name.startswith('git_'),
        'Flutter': lambda name: name.startswith('flutter_'),
        'Python': lambda name: name.startswith('python_'),
        'Shell': {'run_command'},
        'Web': {'web_fetch', 'web_search'},
    }

    def __init__(
            self,
            base_path: str = ".",
            security_config: Optional[SecurityConfig] = None,
            path_filter: Optional[PathFilter] = None,
            db_connections: Optional[Dict[str, Dict[str, str]]] = None,
    ):
        self.base_path = Path(base_path).resolve()
        self.security_config = security_config or SecurityConfig()
        self.path_filter = path_filter or PathFilter(base_path=self.base_path)
        self.db_connections = db_connections or {}

        self._audit_logger = setup_audit_logger(self.security_config)
        self._tool_circuit_breakers: Dict[str, CircuitBreaker] = {}
        self._category_cache: Dict[str, str] = {}

        self.tools: Dict[str, Callable] = {}
        self.definitions: List[Dict[str, Any]] = []

        self.tool_timeouts: Dict[str, float] = {
            "read_file": 20.0,
            "read_files": 60.0,
            "write_file": 20.0,
            "append_file": 20.0,
            "delete_file": 10.0,
            "patch_file": 25.0,
            "move_file": 20.0,
            "create_directory": 10.0,
            "list_files": 60.0,
            "list_files_recursive": 125.0,
            "search_in_files": 60.0,
            "find_files": 60.0,
            "git_status": 10.0,
            "git_branches": 5.0,
            "git_log": 10.0,
            "git_diff": 15.0,
            "git_checkout": 10.0,
            "git_commit": 15.0,
            "flutter_analyze": 45.0,
            "python_check": 30.0,
            "python_lint": 30.0,
            "python_format": 30.0,
            "python_test": 60.0,
            "run_command": 30.0,
            "web_fetch": 20.0,
            "web_search": 20.0,
        }

        from . import collect_all_tools
        collect_all_tools(self)

    # ------------------------------------------------------------------
    # Path helpers
    # ------------------------------------------------------------------

    def resolve_path(self, path: str) -> Path:
        """Resolve path relative to base_path, ensuring it stays within bounds."""
        resolved = (self.base_path / path).resolve()
        if not str(resolved).startswith(str(self.base_path)):
            raise ValueError(
                f"Access denied: '{path}' -> '{resolved}' is outside '{self.base_path}'. "
                "Use relative paths within the project."
            )
        return resolved

    def _relativise_path(self, path: str) -> str:
        """Convert absolute path to relative if under base_path."""
        p = Path(path)
        if p.is_absolute():
            try:
                return str(p.relative_to(self.base_path))
            except ValueError:
                return path
        return path

    def relativise(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Normalize 'path' and 'paths' parameters to relative form."""
        result = dict(params)
        if "path" in result and isinstance(result["path"], str):
            result["path"] = self._relativise_path(result["path"])
        if "paths" in result and isinstance(result["paths"], list):
            result["paths"] = [
                self._relativise_path(p) if isinstance(p, str) else p
                for p in result["paths"]
            ]
        return result

    # ------------------------------------------------------------------
    # Tool registration
    # ------------------------------------------------------------------

    def register_tool(self, name: str, func: Callable, definition: Dict[str, Any]) -> None:
        """Register a tool, its implementation, and its OpenAPI-style definition."""
        self.tools[name] = func
        self.definitions.append(definition)
        self._category_cache.clear()

    def _get_tool_category(self, name: str) -> str:
        """Get category for tool name (cached)."""
        if name in self._category_cache:
            return self._category_cache[name]
        category = "Other"
        for cat, spec in self.TOOL_CATEGORIES.items():
            if callable(spec):
                if spec(name):
                    category = cat
                    break
            elif name in spec:
                category = cat
                break
        self._category_cache[name] = category
        return category

    # ------------------------------------------------------------------
    # Response classification and strict parsing
    # ------------------------------------------------------------------

    def strict_parse_tool_call(self, text: str) -> Optional[Tuple[str, Dict[str, Any]]]:
        """Parse ONLY the exact mandated format: <tool>{JSON}</tool>.

        Returns (tool_name, parameters) if the response is a well-formed,
        known tool call; None otherwise.
        No fuzzy matching, no fallbacks.
        """
        if not text:
            return None

        m = _STRICT_TOOL_RE.match(text)
        if not m:
            return None

        try:
            data = json.loads(m.group(1))
        except json.JSONDecodeError:
            return None

        if not isinstance(data, dict):
            return None

        name = data.get("tool")
        params = data.get("parameters", {})

        if not isinstance(name, str) or not name:
            return None
        if not isinstance(params, dict):
            params = {}
        if name not in self.tools:
            return None

        return name, params

    def classify_response(self, text: str) -> ResponseKind:
        """Classify a model reply without running the full parser chain.

        Returns one of:
          "tool_call"    — strict format matched, ready to execute
          "final_answer" — no tool markers present, treat as prose
          "malformed"    — has tool-like markers but failed strict parse;
                           escalate to looks_like_malformed_tool_call
        """
        if not text:
            return "final_answer"

        if self.strict_parse_tool_call(text) is not None:
            return "tool_call"

        if _TOOL_MARKER_RE.search(text):
            return "malformed"

        return "final_answer"

    # ------------------------------------------------------------------
    # Execution
    # ------------------------------------------------------------------

    def _parse_tool_result(self, result: str) -> Dict[str, Any]:
        """Parse tool result JSON, defaulting to success if unparseable."""
        try:
            parsed = json.loads(result)
            return parsed if isinstance(parsed, dict) else {"status": "success"}
        except (json.JSONDecodeError, ValueError):
            return {"status": "success"}

    def _error_result(self, message: str) -> str:
        """Wrap error message as JSON."""
        return json.dumps({"status": "error", "message": message})

    def execute(self, tool_name: str, parameters: Dict[str, Any]) -> str:
        """Execute a tool with given parameters.

        Handles circuit breaking, path normalization, error reporting, and auditing.
        All filesystem access is confined to base_path.
        """
        if tool_name not in self.tools:
            err = self._error_result(
                f"Unknown tool: {tool_name}. Available: {', '.join(sorted(self.tools.keys()))}"
            )
            audit_log(self._audit_logger, tool_name, parameters or {}, err)
            return err

        cb = self._tool_circuit_breakers.setdefault(
            tool_name,
            CircuitBreaker(
                name=f"tool:{tool_name}",
                failure_threshold=self.CIRCUIT_BREAKER_CONFIG['failure_threshold'],
                recovery_timeout=self.CIRCUIT_BREAKER_CONFIG['recovery_timeout'],
            ),
        )

        if not cb.allow_request():
            err = self._error_result(
                f"Tool '{tool_name}' is temporarily disabled (too many failures). "
                f"Recovers in {cb.recovery_timeout:.0f}s."
            )
            audit_log(self._audit_logger, tool_name, parameters or {}, err)
            return err

        try:
            safe_params = self.relativise(parameters or {})
            result = self.tools[tool_name](**safe_params)

            parsed = self._parse_tool_result(result)
            if parsed.get("status") == "error":
                cb.record_failure()
            else:
                cb.record_success()

            audit_log(self._audit_logger, tool_name, safe_params, result)
            return result

        except TypeError as e:
            err = self._error_result(f"Invalid parameters: {e}")
            cb.record_failure()
            audit_log(self._audit_logger, tool_name, parameters or {}, err)
            return err

        except ValueError as e:
            err = self._error_result(f"Path error: {e}")
            cb.record_failure()
            audit_log(self._audit_logger, tool_name, parameters or {}, err)
            return err

        except Exception as e:
            err = self._error_result(str(e))
            cb.record_failure()
            audit_log(self._audit_logger, tool_name, parameters or {}, err)
            return err

    # ------------------------------------------------------------------
    # System prompt generation
    # ------------------------------------------------------------------

    def get_system_prompt(self, project_context: Optional[str] = None) -> str:
        """Generate production system prompt with tool catalog.

        When *project_context* is provided it is merged into the prompt as a
        [PROJECT CONTEXT] block between the base rules and the tool catalog.
        """
        lines = self._base_system_prompt()

        if project_context and project_context.strip():
            lines.append("")
            lines.append("PROJECT CONTEXT (from .agent.md)")
            lines.append("================================")
            for cline in project_context.strip().splitlines():
                lines.append(cline)
            lines.append("")

        groups: Dict[str, List[str]] = {cat: [] for cat in self.TOOL_CATEGORIES}
        groups['Other'] = []

        for defn in self.definitions:
            fn = defn.get("function", {})
            name = fn.get("name", "unknown")
            desc = (fn.get("description", "") or "").strip().replace("\n", " ")
            sig = self._format_signature(fn)
            cat = self._get_tool_category(name)
            groups[cat].append(f"- {name}({sig}): {desc}")

        for cat_name in ('Filesystem', 'Search', 'Git', 'Flutter', 'Python', 'Shell', 'Other'):
            entries = groups.get(cat_name, [])
            if not entries:
                continue
            lines.append(f"[{cat_name}]")
            lines.extend(entries)
            lines.append("")

        if not any(groups.values()):
            lines.append("(No tool definitions registered)")
            if self.tools:
                lines.append("Registered: " + ", ".join(sorted(self.tools.keys())))

        return "\n".join(lines)

    @staticmethod
    def _base_system_prompt() -> List[str]:
        """Return immutable base system prompt (no tools)."""
        return [
            "AUTONOMOUS CODING AGENT SYSTEM PROMPT",
            "=====================================",
            "",
            "MISSION",
            "-------",
            "Complete user requests correctly, efficiently, with minimal steps.",
            "No exploration, no hallucination, no hand-offs mid-task.",
            "",
            "PRIMARY CONSTRAINT: TOOL CALL FORMAT",
            "====================================",
            "When a tool is needed, output ONLY this format. NO DEVIATION.",
            "",
            '<tool>{"tool":"NAME","parameters":{...}}</tool>',
            "",
            "Required:",
            "- Exact opening/closing tags: <tool> ... </tool>",
            "- Valid JSON inside (double quotes, no trailing commas, no comments)",
            "- Tool call is the ENTIRE response (no preamble, no explanation)",
            "- One tool call per response",
            "",
            "Failure = immediate rejection + retry exhaustion -> task fails.",
            "",
            "CORE BEHAVIORAL RULES",
            "=====================",
            "",
            "1. DECISIVENESS",
            "   - Use tools when necessary; answer directly when not.",
            "   - Continue until task complete OR genuinely blocked.",
            "   - No internal planning narration unless explicitly asked.",
            "   - No permission-seeking for routine tool work.",
            "   - No empty responses.",
            "   - If the final response is empty and no errors occurred, retry up to 3 times.",
            "",
            "2. EXECUTION AUTONOMY",
            "   - User says 'proceed/yes/go/do it/continue' -> EXECUTE every step in THIS turn.",
            "   - Do NOT pause between steps asking 'keep going?'",
            "   - A turn ends ONLY one of two ways:",
            "     a) A tool call (more work needed), OR",
            "     b) COMPLETE final answer (task done or genuinely blocked)",
            "   - FORBIDDEN PHRASES (when work remains):",
            "     * 'I will ...'",
            "     * 'Let me to proceed ...'",
            "     * 'Is there anything specific ...'",
            "     * 'Would you like me to proceed ...?'",
            "     * 'Would you like me to implement ..?'",
            "     * 'Shall I continue...?'",
            "     * 'Should I now...?'",
            "     * 'Ready when you are'",
            "     * 'Let me know if you'd like me to...'",
            "     * Any 'Now I'll [X]' / 'Let me [examine/check/read] [Y]' without immediately performing it",
            "",
            "3. BLOCKING RULES (only valid end-states)",
            "   - Task complete",
            "   - Genuinely blocked (state blocker plainly; do NOT request confirmation)",
            "   - Anything else = keep working",
            "",
            "TOOL USAGE DISCIPLINE",
            "====================",
            "",
            "WHEN TO USE TOOLS",
            "- Use read_files (batch) instead of read_file (single) when reading 2+ files",
            "- Use direct tools (read_file, search_in_files, list_files) instead of run_command",
            "",
            "WHEN NOT TO USE TOOLS",
            "- Task solvable without tools -> answer directly",
            "",
            "MANDATORY VALIDATION (after write operations)",
            "- After writing/patching .dart files -> flutter_analyze immediately (same turn)",
            "- After writing/patching .py files -> python_check immediately (same turn)",
            "- If validation fails, fix and re-run (repeat until clean or blocked)",
            "- FORBIDDEN: asking user to run validation, claiming tools unavailable",
            "- The agent runs validators, not the user. Period.",
            "",
            "SCOPE BOUNDARIES",
            "================",
            "- Current project/workspace folder ONLY",
            "- Never traverse outside: no '..' paths, no parent directories, no absolute system paths",
            "- If file not in project, ask user for location (do not broaden search)",
            "- Respect configured filesystem filters (exclude lists are truth)",
            "",
            "EDITING RULES",
            "=============",
            "- Always inspect file before changing",
            "- Prefer smallest safe edit solving the problem",
            "- Never ask user to apply changes manually when tools exist",
            "- Use relative paths only",
            "- Do not repeat same failing action; adjust strategy",
            "- Target only files involved in task (no unrelated modifications)",
            "",
            "DECISION LOGIC (in order)",
            "=========================",
            "1. Is tool needed?",
            "   -> YES: Call it immediately (use read_files for multiple reads)",
            "   -> NO: Answer directly",
            "",
            "2. Multiple tool choices?",
            "   -> Choose most direct/reliable (prefer dedicated tools over run_command)",
            "",
            "3. Unclear but solvable?",
            "   -> Make best assumption and proceed",
            "",
            "4. Genuinely ambiguous/blocked?",
            "   -> Ask user (only at this point)",
            "",
            "5. Multiple equally valid options?",
            "   -> Stop and ask clarification",
            "",
            "SEARCH DISCIPLINE",
            "=================",
            "- Search only when necessary",
            "- Keep searches narrow (specific patterns, file extensions, likely folders)",
            "- Prefer exact names/symbols over wildcard scans",
            "- No recursive broad scans ('find /', 'dir /s', 'tree', etc.)",
            "- If search fails, refine instead of broadening",
            "",
            "EXAMPLES: CORRECT TOOL FORMAT",
            "=============================",
            '<tool>{"tool":"read_file","parameters":{"path":"src/main.py"}}</tool>',
            '<tool>{"tool":"read_files","parameters":{"paths":["a.py","b.py","c.py"]}}</tool>',
            '<tool>{"tool":"search_in_files","parameters":{"pattern":"error","file_glob":"*.log"}}</tool>',
            "",
            "EXAMPLES: INVALID FORMAT (REJECTED)",
            "===================================",
            'read_file{"path":"file.txt"}',
            "<tool=read_file>...</tool>",
            "<tool>{tool: read_file}</tool>",
            '"I will now read the file..." [before tool call]',
            "<tool>...</tool> plus text after",
            "",
            "NO HALLUCINATIONS",
            "=================",
            "- Never claim tools are unavailable before trying them",
            "- Never invent tool results",
            "- Never skip validation steps (flutter_analyze, python_check mandatory)",
            "- Never guess when information is insufficient",
            "- Report actual errors from tools verbatim (do not soften or excuse)",
            "",
            "AVAILABLE TOOLS",
            "===============",
            "",
            "LARGE CONTEXT HANDLING",
            "======================",
            "",
            "ANALYSIS (read-heavy, no writes yet)",
            "- If full understanding requires inspecting many files or concepts,",
            "  split analysis into numbered parts (Part 1 of N, Part 2 of N, ...).",
            "- Complete each part fully before moving to the next.",
            "- Do NOT begin implementation until analysis is declared complete.",
            "",
            "IMPLEMENTATION (write-heavy, multi-step)",
            "- If the task requires more than one implementation step,",
            "  execute EXACTLY ONE step per turn, then stop.",
            "- Do NOT chain multiple write steps in a single turn.",
            "- Wait for user confirmation before proceeding to the next step.",
            "",
            "MANDATORY STEP REPORT (after every implementation step)",
            "- Output a structured report in this exact format:",
            "",
            "  STEP REPORT",
            "  -----------",
            "  Done:",
            "    - [task completed in this step]",
            "    - ...",
            "  Pending:",
            "    - [next task]",
            "    - ...",
            "  Current state:",
            "    [1-3 sentences describing what is working, what is wired, what is missing]",
            "",
            "- This report is MANDATORY. Skipping it is a protocol violation.",
            "- The report must reflect actual tool results, not assumptions.",
            "",
        ]

    @staticmethod
    def _format_signature(fn: Dict[str, Any]) -> str:
        """Format tool signature from OpenAPI spec."""
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



