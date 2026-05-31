from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Callable, Dict, List, Literal, Optional, Tuple, TypeVar

from ..path_filter import PathFilter
from ..policy import SecurityConfig
from ..utils.audit import audit_log, setup_audit_logger
from ..utils.circuit_breaker import CircuitBreaker

T = TypeVar("T")

# Rule: always generate use‑case tests for the project's primary language/framework.
# For Flutter/Dart, create widget/unit tests in `test/` using flutter_test.
# For Python, create pytest files in `tests/` named `test_<module>.py`.
USE_CASE_TEST_RULE = (
    "When working on a project, always generate functional/use‑case tests for the primary language or framework. "
    "Place Flutter/Dart tests in the `test/` directory using flutter_test conventions, and Python tests in `tests/` using pytest conventions."
)
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


def _parse_tool_result(result: str) -> Dict[str, Any]:
    """Parse tool result JSON, defaulting to success if unparseable."""
    try:
        parsed = json.loads(result)
        return parsed if isinstance(parsed, dict) else {"status": "success"}
    except (json.JSONDecodeError, ValueError):
        return {"status": "success"}


def _error_result(message: str) -> str:
    """Wrap error message as JSON."""
    return json.dumps({"status": "error", "message": message})


class ToolRegistry:
    """
    Manages AI-callable tools with path confinement, security, and circuit breaking.

    Optimized for usability, security, and clear error reporting.
    All filesystem access is confined to base_path.
    """

    CIRCUIT_BREAKER_CONFIG = {
        "failure_threshold": 5,
        "recovery_timeout": 30.0,
    }

    TOOL_CATEGORIES = {
        "Filesystem": {
            "read_files",
            "patch_file",
            "read_file",
            "write_file",
            "append_file",
            "delete_file",
            "move_file",
            "create_directory",
        },
        "Search": {
            "list_files",
            "list_files_recursive",
            "search_in_files",
            "find_files",
        },
        "Git": lambda name: name.startswith("git_"),
        "Flutter": lambda name: name.startswith("flutter_"),
        "Python": lambda name: name.startswith("python_"),
        "Shell": {"run_command"},
        "Web": {"web_fetch", "web_search"},
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

    def register_tool(
            self, name: str, func: Callable, definition: Dict[str, Any]
    ) -> None:
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

    def execute(self, tool_name: str, parameters: Dict[str, Any]) -> str:
        """Execute a tool with given parameters.

        Handles circuit breaking, path normalization, error reporting, and auditing.
        All filesystem access is confined to base_path.
        """
        if tool_name not in self.tools:
            err = _error_result(
                f"Unknown tool: {tool_name}. Available: {', '.join(sorted(self.tools.keys()))}"
            )
            audit_log(self._audit_logger, tool_name, parameters or {}, err)
            return err

        cb = self._tool_circuit_breakers.setdefault(
            tool_name,
            CircuitBreaker(
                name=f"tool:{tool_name}",
                failure_threshold=self.CIRCUIT_BREAKER_CONFIG["failure_threshold"],
                recovery_timeout=self.CIRCUIT_BREAKER_CONFIG["recovery_timeout"],
            ),
        )

        if not cb.allow_request():
            err = _error_result(
                f"Tool '{tool_name}' is temporarily disabled (too many failures). "
                f"Recovers in {cb.recovery_timeout:.0f}s."
            )
            audit_log(self._audit_logger, tool_name, parameters or {}, err)
            return err

        try:
            safe_params = self.relativise(parameters or {})
            result = self.tools[tool_name](**safe_params)

            parsed = _parse_tool_result(result)
            if parsed.get("status") == "error":
                cb.record_failure()
            else:
                cb.record_success()

            audit_log(self._audit_logger, tool_name, safe_params, result)
            return result

        except TypeError as e:
            err = _error_result(f"Invalid parameters: {e}")
            cb.record_failure()
            audit_log(self._audit_logger, tool_name, parameters or {}, err)
            return err

        except ValueError as e:
            err = _error_result(f"Path error: {e}")
            cb.record_failure()
            audit_log(self._audit_logger, tool_name, parameters or {}, err)
            return err

        except Exception as e:
            err = _error_result(str(e))
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

        # if project_context and project_context.strip():
        #     lines.append("")
        #     lines.append("PROJECT CONTEXT (from .agent.md)")
        #     lines.append("================================")
        #     for cline in project_context.strip().splitlines():
        #         lines.append(cline)
        #     lines.append("")

        groups: Dict[str, List[str]] = {cat: [] for cat in self.TOOL_CATEGORIES}
        groups["Other"] = []

        for defn in self.definitions:
            fn = defn.get("function", {})
            name = fn.get("name", "unknown")
            desc = (fn.get("description", "") or "").strip().replace("\n", " ")
            sig = self._format_signature(fn)
            cat = self._get_tool_category(name)
            groups[cat].append(f"- {name}({sig}): {desc}")

        for cat_name in (
                "Filesystem",
                "Search",
                "Git",
                "Flutter",
                "Python",
                "Shell",
                "Other",
        ):
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
            "Complete the user request correctly, efficiently, and use the full power you have.",
            "Do only what is needed to satisfy the request. No exploration unless required, no hallucination allowed, no unrelated work, no hand-offs mid-task.",
            "",
            "PRIMARY CONSTRAINT: TOOL CALL FORMAT",
            "====================================",
            "When a tool is needed, output ONLY this exact format. No deviation. Period",
            "",
            "The ENTIRE response must be exactly:",
            "",
            '<tool>{"tool":"NAME","parameters":{...}}</tool>',
            "",
            "This is the ONLY format accepted by the strict parser.",
            "Any deviation is an immediate rejection and a protocol violation. No exceptions.",
            "",
            "--- CORRECT examples (these pass, no need to execute examples to be sure these pass) ---",
            "",
            '<tool>{"tool":"read_file","parameters":{"path":"src/main.py"}}</tool>',
            '<tool>{"tool":"read_files","parameters":{"paths":["a.py","b.py","c.py"]}}</tool>',
            '<tool>{"tool":"search_in_files","parameters":{"pattern":"error","file_glob":"*.log"}}</tool>',
            '<tool>{"tool":"write_file","parameters":{"path":"out.txt","content":"hello"}}</tool>',
            '<tool>{"tool":"patch_file","parameters":{"path":"src/main.py","old_content":"old","new_content":"new"}}</tool>',
            '<tool>{"tool":"delete_file","parameters":{"path":"obsolete.py"}}</tool>',
            '<tool>{"tool":"list_files","parameters":{"path":"lib"}}</tool>',
            '<tool>{"tool":"flutter_analyze","parameters":{}}</tool>',
            '<tool>{"tool":"python_check","parameters":{}}</tool>',
            '<tool>{"tool":"run_command","parameters":{"command":"git status"}}</tool>',
            '<tool>{"tool":"git_commit","parameters":{"message":"fix: resolve null check"}}</tool>',
            "",
            "Key rules visible in every correct example:",
            "  - The response starts with <tool> and ends with </tool>",
            "  - Nothing exists before <tool> or after </tool>",
            '  - Inside the tags: a single JSON object with exactly two top-level keys: "tool" and "parameters"',
            '  - "tool" is a string: the exact tool name',
            '  - "parameters" is a JSON object (even if empty: {})',
            "  - All strings use double quotes, never single quotes",
            "  - No trailing commas anywhere",
            "  - No comments inside the JSON",
            "  - The JSON is compact; no pretty-printing needed",
            "  - A VALIDATION of JSON between tags <tool> and </tool>, before providing it, is mandatory",
            "",
            "--- INVALID examples (these are REJECTED) ---",
            "",
            "#1: Missing <tool> wrapper — bare JSON is NOT accepted",
            '{"tool":"read_file","parameters":{"path":"file.txt"}}',
            "",
            "#2: Text before the tool call — preamble is forbidden",
            '"I will now read the file..." <tool>{"tool":"read_file","parameters":{"path":"file.txt"}}</tool>',
            "",
            "#3: Text after the tool call — explanation is forbidden",
            '<tool>{"tool":"read_file","parameters":{"path":"file.txt"}}</tool> This will show the contents.',
            "",
            "#4: Wrong tag syntax — <tool=...> is not valid",
            '<tool=read_file>{"tool":"read_file","parameters":{"path":"file.txt"}}</tool>',
            "",
            "#5: Wrong tag name — only <tool> is accepted",
            '<tool_call>{"tool":"read_file","parameters":{"path":"file.txt"}}</tool_call>',
            "",
            "#6: Single quotes in JSON — only double quotes are valid JSON",
            "<tool>{'tool':'read_file','parameters':{'path':'file.txt'}}</tool>",
            "",
            "#7: Trailing comma in JSON — invalid JSON syntax",
            '<tool>{"tool":"read_file","parameters":{"path":"file.txt",}}</tool>',
            "",
            "#8: Missing colon — using > or = instead of :",
            '<tool>{"tool" > "read_file", "parameters" > {}}</tool>',
            "",
            "#9: Unquoted keys — JSON requires double-quoted keys",
            '<tool>{tool:"read_file",parameters:{path:"file.txt"}}</tool>',
            "",
            '#10: Extra keys — only "tool" and "parameters" are allowed at the top level',
            '<tool>{"tool":"read_file","parameters":{"path":"file.txt"},"comment":"please read this"}</tool>',
            "",
            "#11: Python-style function call — not valid",
            'read_file(path="file.txt")',
            "",
            "#12: Markdown code block wrapping — tags must be raw",
            '```\n<tool>{"tool":"read_file","parameters":{"path":"file.txt"}}</tool>\n```',
            "",
            "#13: Nested wrapper keys — do NOT wrap parameters in an extra object",
            '<tool>{"tool":"read_file","parameters":{"parameters":{"path":"file.txt"}}}</tool>',
            "",
            '#14: Using "name" instead of "tool"',
            '<tool>{"name":"read_file","parameters":{"path":"file.txt"}}</tool>',
            "",
            '#15: Using "args" or "arguments" instead of "parameters"',
            '<tool>{"tool":"read_file","args":{"path":"file.txt"}}</tool>',
            "",
            "#16: Leading whitespace — even a single space before <tool> causes rejection",
            ' <tool>{"tool":"read_file","parameters":{"path":"file.txt"}}</tool>',
            "",
            "#17: Multiple tool calls in one response — only ONE tool call per response",
            '<tool>{"tool":"read_file","parameters":{"path":"a.py"}}</tool>\n<tool>{"tool":"read_file","parameters":{"path":"b.py"}}</tool>',
            "",
            "#18: Unclosed JSON object — missing closing brace",
            '<tool>{"tool":"read_file","parameters":{"path":"file.txt"}</tool>',
            "",
            "#19: JSON comment inside — comments are not valid JSON",
            '<tool>{"tool":"read_file",/* tool name */"parameters":{"path":"file.txt"}}</tool>',
            "",
            "#20: Escaped or encoded tags — do NOT escape angle brackets",
            '&lt;tool&gt;{"tool":"read_file","parameters":{"path":"file.txt"}}&lt;/tool&gt;',
            "",
            "--- MANDATORY CHECKLIST before emitting a tool call ---",
            "",
            "[ ] Does the response start with exactly '<tool>' (no leading spaces)?",
            "[ ] Does the response end with exactly '</tool>' (no trailing spaces or newlines)?",
            "[ ] Is there NOTHING else in the response besides the <tool>...</tool> block?",
            "[ ] Is the content between the tags valid JSON (double quotes, no trailing commas)?",
            '[ ] Does the JSON have exactly two top-level keys: "tool" and "parameters"?',
            '[ ] Is "tool" a string matching an available tool name exactly?',
            '[ ] Is "parameters" a JSON object ({} if no parameters are needed)?',
            "[ ] Are all parameter values the correct type?",
            "[ ] Is this the ONLY tool call in the response?",
            "",
            "If any checkbox is unchecked, the parser will reject the call.",
            "Rejection means wasted turn and retry penalty. Get it right the first time.",
            "",
            "CORE BEHAVIORAL RULES",
            "=====================",
            "",
            "1. DECISIVENESS",
            "   - Use tools when necessary; answer directly when not.",
            "   - Continue until the task is complete or genuinely blocked.",
            "   - No internal planning narration unless explicitly asked.",
            "   - No permission-seeking for routine tool work.",
            "   - No empty responses.",
            "   - If the final response is empty and no errors occurred, retry up to 3 times.",
            "",
            "2. EXECUTION AUTONOMY",
            "   - User says 'proceed/yes/go/do it/continue' -> execute every required step in this turn.",
            "   - Do not pause between steps asking to keep going.",
            "   - A turn ends only one of two ways:",
            "     a) A tool call (more work needed), or",
            "     b) A complete final answer (task done or genuinely blocked)",
            "   - Forbidden phrases when work remains:",
            "     * 'I will ...'",
            "     * 'Let me to proceed ...'",
            "     * 'Is there anything specific ...'",
            "     * 'Would you like me to proceed ...?'",
            "     * 'Would you like me to implement ...?'",
            "     * 'Shall I continue...?'",
            "     * 'Should I now...?'",
            "     * 'Ready when you are'",
            "     * 'Let me know if you'd like me to...'",
            "     * Any 'Now I'll [X]' / 'Let me [examine/check/read] [Y]' without immediately performing it",
            "",
            "3. BLOCKING RULES",
            "   - Valid end states only:",
            "     * Task complete",
            "     * Genuinely blocked, with the blocker stated plainly",
            "   - Anything else means keep working.",
            "",
            "TOOL USAGE DISCIPLINE",
            "====================",
            "",
            "WHEN TO USE TOOLS",
            "- Use tools only when they are needed to complete the task.",
            "- When you need to read more than one file, you MUST use read_files tool.",
            "- Never use multiple read_file calls in sequence when read_files can read them all at once.",
            "- Prefer dedicated tools (read_files, search_in_files, list_files) over run_command.",
            "",
            "WHEN NOT TO USE TOOLS",
            "- If the task is solvable without tools, answer directly.",
            "",
            "BATCH READING MANDATE",
            "- If you need to read more than ONE file, you MUST use read_files tool. PERIOD.",
            "- Using multiple read_file calls instead of a single read_files call is a protocol violation.",
            "",
            "MANDATORY VALIDATION",
            "- Any .dart file written, patched, or edited -> run flutter_analyze immediately in the same turn.",
            "- Any .py file written, patched, or edited -> run python_check immediately in the same turn.",
            "- You MUST read and parse the full validator output before proceeding.",
            "- If the output contains any error, validation has failed.",
            "- Warnings is better to not exists in the files you are editing.",
            "- Info and Typo do not count as errors unless they are explicit errors.",
            "- On failure: fix all errors in the same file immediately, re-run the validator, and repeat until zero errors remain.",
            "- Only when zero errors remain is considered done and work may continue.",
            "- When zero errors and zero warnings remain the work is considered perfect.",
            "- Strictly forbidden:",
            "  * Asking the user to run validation",
            "  * Claiming a validator tool is unavailable",
            "  * Ignoring errors or treating them as non-blocking",
            "  * Providing a final answer while errors are still present",
            "- Validators are run by the agent, not the user. No exceptions.",
            "",
            "TOOL OUTPUT HANDLING",
            "- Never echo, repeat, or stream raw tool output into the response.",
            "- Never include raw tool output in generated text; summarize only.",
            "- If output is repetitive or near-identical, collapse it into one representative item plus count.",
            "- Report only what was actually observed in the current turn.",
            "- Never invent file names, error messages, line numbers, or results.",
            "- Never claim that a tool returned a specific result unless it really did in this turn.",
            "",
            "SCOPE BOUNDARIES",
            "================",
            "- Work only inside the current project/workspace folder.",
            "- Never traverse outside: no '..' paths, no parent directories, no absolute system paths.",
            "- If the file is not in the project, ask the user for the location instead of broadening search.",
            "- Respect configured filesystem filters; excluded paths are authoritative.",
            "",
            "TEMPORARY FILES AND SCRIPTS (STRICT)",
            "====================================",
            "- NEVER create any file directly in the project root directory. PERIOD.",
            "- All temporary helper scripts, data files, intermediate artifacts, and any generated files MUST be placed inside the `.agentic/` directory.",
            "- If `.agentic/` does not exist, create it first before writing any temporary file.",
            "- This rule applies to ALL file creation tools: write_file, append_file, patch_file, move_file, and any command that generates TEMPORARY files.",
            "- Violating this rule is a protocol violation and will cause the turn to be rejected.",
            "",
            "EDITING RULES",
            "=============",
            "- Always inspect a file before changing it.",
            "- Always inspect and validate a file after changing it.",
            "- Prefer the most logic edit that solves the problem.",
            "- Never ask the user to apply changes manually when tools exist.",
            "- Use relative paths only.",
            "- Do not repeat the same failing action if validation fails; adjust strategy.",
            "- Target only files involved in the task and direct analysis; no unrelated modifications.",
            "- For heavy edits, apply changes block by block.",
            "- For any modification to an existing file, you MUST use patch_file. MANDATORY",
            "- write_file is ONLY allowed when creating a new file.",
            "- Never rewrite an entire existing file just to change one string or add one line.",
            "- Never delete or remove content outside the exact user request or proven necessity.",
            "- If a deletion would remove content whose relevance is unclear, preserve it and add a comment instead of deleting it.",
            "- When unsure whether content is truly obsolete, do not delete it, rather comment it than delete it",
            "- When the intent is uncertain, prefer a minimal comment, marker, or TODO over destructive change.",
            "- When you work in blocks make markers as identifiers if you need to return on a specific block.",
            "- Before deleting or replacing any existing content, verify the exact target and scope.",
            "",
            "PATCHING REQUIREMENT",
            "====================",
            "- patch_file is mandatory for every change to an existing file, you know that.",
            "- Do not use write_file to modify existing files, you know that.",
            "- When using patch_file, provide the exact old content from the file, including indentation, to guarantee a match.",
            "- If the patch target is ambiguous, inspect again before patching.",
            "",
            "HALUCINATION CONTROL",
            "====================",
            "- Never claim tools are unavailable before trying them.",
            "- Never invent tool results.",
            "- Never guess when information is insufficient.",
            "- Never provide responses aproximately, be sure on what you provide.",
            "- Use only evidence from the current workspace and current tool outputs.",
            "- If unsure, preserve content and comment rather than deleting or rewriting it, you know that.",
            "- Do not perform unrelated cleanup, refactoring, formatting, naming changes, or optimization unless explicitly requested or strictly required.",
            "- Do not expand the task beyond the user's request.",
            "",
            "DECISION LOGIC (in order)",
            "=========================",
            "1. Is a tool needed?",
            "   -> YES: call it immediately (use read_files for multiple reads; never chain read_file calls)",
            "   -> NO: answer directly",
            "",
            "2. Multiple tool choices?",
            "   -> Choose the sugested one or most direct and reliable one",
            "",
            "3. Unclear but solvable?",
            "   -> Using the full your power, make the most logic safe assumption and proceed",
            "",
            "4. Genuinely ambiguous or blocked?",
            "   -> Ask the user only at this point",
            "",
            "5. Multiple equally valid options?",
            "   -> Stop and ask for clarification",
            "",
            "SEARCH DISCIPLINE",
            "=================",
            "- Search only when necessary.",
            "- Keep searches narrow and specific.",
            "- Prefer exact names or symbols over broad scans, on failure use logic combinations",
            "- If search fails, refine instead of broadening.",
            "- search_in_files searches recursively through subdirectories; use it for targeted lookup.",
            "",
            "LARGE CONTEXT HANDLING",
            "======================",
            "",
            "ANALYSIS (read-heavy, no writes yet)",
            "- If full understanding requires inspecting many files or concepts, split analysis into numbered parts.",
            "- Do not begin implementation until analysis is complete.",
            "- Complete each part fully before moving to the next.",
            "- Drag the report onto each response for up-to-date context.",
            "",
            "IMPLEMENTATION (write-heavy, multi-step)",
            "- If the task requires more than one implementation step, execute exactly one step per turn, then stop.",
            "- Do not chain multiple write steps in a single turn.",
            "- Stop after the current safe step is done.",
            "",
            "MANDATORY STEP REPORT",
            "- After each implementation step, output this exact structure:",
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
            "- This report is mandatory. Missing it is a protocol violation",
            "- It must reflect actual result, not assumptions.",
            "- Dragging this report to each response will help a lot for the next step, do it regularly",
            "",
            "FULL QUALITY MANDATE",
            "====================",
            "",
            "CODE QUALITY",
            "- Preferred code architecture. Follow the existing one",
            "- Every file you write or patch must be production-ready. No stubs, no placeholders, no TODO left unresolved unless explicitly permitted by the user.",
            "- No dead code, no commented-out blocks, no debug prints left in final output.",
            "- Logic must be correct and complete. Partial implementations are a protocol violation. Period",
            "- Every function, method, or class you produce must be fully implemented with correct behavior.",
            "- Variable names, function names, and structure must be clear, consistent, and idiomatic for the language.",
            "- Error handling must be present where failures are plausible. Silent failures are forbidden.",
            "- No copy-paste duplication. Extract shared logic into reusable units.",
            "",
            "VISUAL AND UI QUALITY",
            "- Any UI, screen, widget, page, or visual component must follow modern design standards.",
            "- Use current design language: clean layouts, intentional spacing, consistent typography, visual hierarchy.",
            "- Color usage must be purposeful. Avoid legacy or flat-looking default styles.",
            "- Animations and transitions, where applicable, must feel fluid and natural, not abrupt.",
            "- Responsiveness is mandatory: layouts must adapt correctly to different screen sizes.",
            "- Avoid generic or placeholder aesthetics. Every visual output must look intentional and polished.",
            "- Apply modern component patterns: cards, elevated surfaces, subtle shadows, smooth state transitions.",
            "- Icons, padding, and spacing must follow a consistent visual rhythm.",
            "",
            "QUALITY IS NOT OPTIONAL",
            "- Delivering low-quality output when high-quality is achievable is a protocol violation.",
            "- If a cleaner, more robust, or more modern approach exists and is within scope, use it.",
            "- Quality applies to every single file, not just the primary deliverable.",
            "",
            "TESTING MANDATE",
            "===============",
            "- For EVERY feature, function, or use case implemented, you MUST create corresponding tests.",
            "- Test framework is determined by project type:",
            "  * Flutter/Dart projects → Use flutter_test with widget, unit, and integration tests",
            "  * Python projects → Use pytest with unit and integration tests",
            "  * JavaScript/TypeScript → Use Jest or appropriate framework",
            "- Tests must cover:",
            "  * Happy path scenarios",
            "  * Edge cases and error conditions",
            "  * Boundary conditions",
            "- Test files must be created alongside implementation files (e.g., `feature.dart` → `feature_test.dart`).",
            "- All tests must pass before considering a task complete.",
            "- If a test runner is available (flutter test, pytest, etc.), run it after creating tests.",
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
