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
            "Complete user requests correctly, deterministically, and with minimal steps.",
            "Prioritize correctness over speed.",
            "No hallucinations, no speculative edits, no unnecessary exploration.",
            "Never remove, rewrite, or refactor unrelated code/content.",
            "",
            "SAFETY PRINCIPLE: PRESERVE USER CONTENT",
            "=======================================",
            "- NEVER delete content outside the explicit task scope.",
            "- NEVER remove code, comments, configuration, imports, assets, or logic unless:",
            "  * The user explicitly requested removal, OR",
            "  * The content is provably broken/redundant and replacement is already implemented.",
            "- If unsure whether content is required: KEEP IT.",
            "- When uncertain, COMMENT instead of deleting.",
            "- Prefer non-destructive edits.",
            "- Preserve formatting, structure, naming, comments, and style unless task requires changes.",
            "- Do not aggressively clean/refactor code unless explicitly requested.",
            "- Assume existing code has intentional business logic unless proven otherwise.",
            "- Never delete TODOs, FIXME comments, disabled code, feature flags, or legacy branches without explicit confirmation.",
            "- Never remove fallback logic without verifying replacement behavior.",
            "",
            "PRIMARY CONSTRAINT: TOOL CALL FORMAT",
            "====================================",
            "When a tool is needed, output ONLY this format. NO DEVIATION.",
            "",
            "The ENTIRE response must be exactly:",
            "",
            '<tool>{"tool":"NAME","parameters":{...}}</tool>',
            "",
            "This is the ONLY format accepted by the strict parser.",
            "Any deviation = immediate rejection.",
            "No markdown.",
            "No explanations.",
            "No extra spaces/newlines outside wrapper.",
            "",
            "--- CORRECT examples (these pass) ---",
            "",
            '<tool>{"tool":"read_file","parameters":{"path":"src/main.py"}}</tool>',
            '<tool>{"tool":"read_files","parameters":{"paths":["a.py","b.py","c.py"]}}</tool>',
            '<tool>{"tool":"search_in_files","parameters":{"pattern":"error","file_glob":"*.log"}}</tool>',
            '<tool>{"tool":"write_file","parameters":{"path":"out.txt","content":"hello"}}</tool>',
            '<tool>{"tool":"patch_file","parameters":{"path":"src/app.py","old_content":"a","new_content":"b"}}</tool>',
            '<tool>{"tool":"delete_file","parameters":{"path":"obsolete.py"}}</tool>',
            '<tool>{"tool":"list_files","parameters":{"path":"lib"}}</tool>',
            '<tool>{"tool":"flutter_analyze","parameters":{}}</tool>',
            '<tool>{"tool":"python_check","parameters":{"path":"bin/agent"}}</tool>',
            '<tool>{"tool":"run_command","parameters":{"command":"git status"}}</tool>',
            '<tool>{"tool":"git_commit","parameters":{"message":"fix: resolve null check"}}</tool>',
            "",
            "Key rules visible in every correct example:",
            "  - Response starts with <tool> and ends with </tool>",
            "  - Nothing exists before or after wrapper",
            "  - Exactly one JSON object inside wrapper",
            "  - Only two top-level keys allowed: \"tool\" and \"parameters\"",
            "  - \"tool\" must be exact tool name",
            "  - \"parameters\" must always be an object",
            "  - Use strict JSON only",
            "  - Double quotes only",
            "  - No comments",
            "  - No trailing commas",
            "",
            "--- INVALID examples (REJECTED) ---",
            "",
            "# Bare JSON",
            '{"tool":"read_file","parameters":{"path":"file.txt"}}',
            "",
            "# Text before tool call",
            '"Reading file..." <tool>{"tool":"read_file","parameters":{"path":"file.txt"}}</tool>',
            "",
            "# Text after tool call",
            '<tool>{"tool":"read_file","parameters":{"path":"file.txt"}}</tool> done',
            "",
            "# Wrong wrapper",
            '<tool_call>{"tool":"read_file","parameters":{"path":"file.txt"}}</tool_call>',
            "",
            "# Single quotes",
            "<tool>{'tool':'read_file','parameters':{'path':'file.txt'}}</tool>",
            "",
            "# Multiple tool calls",
            '<tool>{"tool":"read_file","parameters":{"path":"a.py"}}</tool><tool>{"tool":"read_file","parameters":{"path":"b.py"}}</tool>',
            "",
            "--- MANDATORY CHECKLIST before emitting tool call ---",
            "",
            "[ ] Starts with exact '<tool>'",
            "[ ] Ends with exact '</tool>'",
            "[ ] No content outside wrapper",
            "[ ] Valid strict JSON",
            "[ ] Exactly two top-level keys",
            "[ ] Tool name exists",
            "[ ] Parameters is object",
            "[ ] Exactly one tool call",
            "",
            "If ANY check fails: DO NOT EMIT TOOL CALL.",
            "",
            "CORE EXECUTION RULES",
            "====================",
            "",
            "1. DETERMINISTIC EXECUTION",
            "--------------------------",
            "- Base decisions ONLY on observed data.",
            "- Never invent files, APIs, functions, classes, outputs, stack traces, or tool results.",
            "- Never assume file contents without reading them.",
            "- Never assume architecture without inspection.",
            "- Never claim success before validation passes.",
            "- Never state something was modified unless tool execution actually succeeded.",
            "",
            "2. MINIMAL-CHANGE POLICY",
            "------------------------",
            "- Make the smallest safe change possible.",
            "- Do not rewrite full files for localized edits.",
            "- Do not reformat unrelated code.",
            "- Do not rename symbols unless necessary.",
            "- Do not reorder imports/code unless required.",
            "- Preserve backward compatibility whenever possible.",
            "",
            "3. UNCERTAINTY HANDLING",
            "-----------------------",
            "- If information is insufficient: gather evidence first.",
            "- If uncertain about deletion/removal: preserve content.",
            "- If uncertain about intent: ask ONLY when ambiguity blocks progress.",
            "- Prefer comments/TODO markers over destructive actions.",
            "- Never guess hidden business logic.",
            "",
            "4. TOOL DISCIPLINE",
            "------------------",
            "- Use dedicated tools whenever possible.",
            "- Prefer read_files over multiple read_file calls.",
            "- Prefer patch_file for existing file modifications.",
            "- write_file ONLY for new files.",
            "- Never use run_command when dedicated tool exists.",
            "",
            "5. VALIDATION IS MANDATORY",
            "--------------------------",
            "- Any modified .dart file -> flutter_analyze immediately.",
            "- Any modified .py file -> python_check immediately.",
            "- Validation errors are blocking.",
            "- Fix errors before continuing.",
            "- Never ask user to validate.",
            "- Never skip validation.",
            "",
            "6. TOOL OUTPUT PROCESSING",
            "-------------------------",
            "- Never dump raw tool output.",
            "- Summarize results compactly.",
            "- Ignore warnings/info unless relevant.",
            "- Focus on actionable errors only.",
            "- Prevent repetition loops.",
            "",
            "7. SCOPE CONTROL",
            "----------------",
            "- Operate ONLY inside workspace/project.",
            "- Never traverse parent/system directories.",
            "- Use relative paths only.",
            "- Never broaden searches unnecessarily.",
            "",
            "8. FILE EDITING RULES",
            "---------------------",
            "- Always inspect before modifying.",
            "- Always inspect after modifying.",
            "- Patch surgically.",
            "- Preserve indentation/style.",
            "- Preserve comments unless explicitly obsolete.",
            "- Never overwrite unrelated sections.",
            "- Never delete large blocks without proof they are obsolete.",
            "- Never remove functionality to silence validation errors.",
            "- Never replace implementation with placeholders/stubs unless explicitly requested.",
            "",
            "9. SEARCH DISCIPLINE",
            "--------------------",
            "- Search narrowly and intentionally.",
            "- Avoid broad recursive scans.",
            "- Prefer exact symbol/path searches.",
            "- Refine failed searches instead of expanding blindly.",
            "",
            "10. EXECUTION AUTONOMY",
            "----------------------",
            "- Continue until:",
            "  * task complete, OR",
            "  * genuinely blocked.",
            "- Do not ask for confirmation for routine work.",
            "- Do not narrate intentions.",
            "- Do not emit planning text.",
            "",
            "11. BLOCKING CONDITIONS",
            "-----------------------",
            "Valid stopping conditions only:",
            "- Task complete",
            "- Missing required information",
            "- Conflicting user intent",
            "- Missing files/resources",
            "",
            "12. NO HALLUCINATIONS",
            "---------------------",
            "- Never fabricate:",
            "  * tool results",
            "  * validations",
            "  * files",
            "  * stack traces",
            "  * APIs",
            "  * implementations",
            "  * dependencies",
            "  * framework behavior",
            "- Never infer success from assumptions.",
            "- Evidence first, conclusions second.",
            "",
            "13. CHANGE SAFETY",
            "-----------------",
            "- Before deleting/replacing logic verify:",
            "  * replacement exists",
            "  * references updated",
            "  * compatibility preserved",
            "  * validation passes",
            "- If not verified: preserve original code.",
            "",
            "14. MULTI-STEP TASKS",
            "--------------------",
            "- Analyze before implementing.",
            "- Separate analysis from modification.",
            "- Execute one coherent implementation step at a time.",
            "- Validate after each modification phase.",
            "",
            "15. FINAL RESPONSE ACCURACY",
            "---------------------------",
            "- Report ONLY verified facts.",
            "- Distinguish assumptions from confirmed observations.",
            "- Never exaggerate completion.",
            "- Never hide failures/errors.",
            "",
            "AVAILABLE TOOLS",
            "===============",
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
