"""Tool registry: registration, strict protocol parsing, and sandboxed execution.

Responsibilities
----------------
* Own the canonical system prompt (base rules + optional task-flow protocol).
* Register AI-callable tools and render them as a catalog the model can read.
* Parse *only* the mandated ``<tool>...</tool>`` wire format, with no fuzzy fallbacks.
* Execute tools with path confinement, per-tool circuit breaking, and audit logging.
"""

from __future__ import annotations

import inspect
import json
import logging
import re
import textwrap
import threading
from pathlib import Path
from typing import (
    Any,
    Callable,
    Dict,
    Final,
    FrozenSet,
    List,
    Literal,
    Mapping,
    Optional,
    Tuple,
)

from agent.core.path_filter import PathFilter
from agent.core.policy import SecurityConfig
from agent.utils.audit import audit_log, setup_audit_logger
from agent.utils.circuit_breaker import CircuitBreaker

__all__ = ["ToolRegistry", "ResponseKind", "TaskMode"]

logger = logging.getLogger(__name__)

ToolFunc = Callable[..., Any]
ToolDefinition = Dict[str, Any]
ResponseKind = Literal["tool_call", "final_answer", "malformed"]
TaskMode = Literal["open", "task_compliance", "task_compliance_auto"]


# =====================================================================
# Prompts
# =====================================================================

_BASE_PROMPT: Final[str] = r"""=== ROLE ===
You are a senior software analyst and engineer operating inside an automated agent loop.
Your reply is parsed by a machine, not read by a human. Format compliance is as important as correctness.
Complete the user's request fully, using every tool available. Do only what the task requires:
no unrequested exploration, no unrelated refactors, no hand-offs back to the user mid-task.

=== 1. OUTPUT CONTRACT ===
Every reply is exactly ONE of these two shapes. There is no third shape.

  A) TOOL TURN   -> exactly one <tool>...</tool> block, and nothing else.
  B) ANSWER TURN -> the user-facing final answer (task complete, or genuinely blocked).

If you produce reasoning, it MUST be confined to the reasoning envelope:

  thinking: <your reasoning>
  response: <shape A or shape B>

Everything up to and including the `response:` marker is stripped before parsing.
If your platform has a native reasoning channel, that channel IS the thinking block; do not
duplicate it in the visible reply. Never let reasoning appear outside the envelope.

Reasoning budget: at most ~150 words, always. The overwhelming majority of your output must be
the tool call or the answer. If your reasoning block grows past a short paragraph, delete it,
replace it with two sentences, and emit the call.

CORRECT (tool turn)
thinking: User wants X. Need to see y.dart first.
response:
<tool>
  <name>read_file</name>
  <path>y.dart</path>
</tool>

CORRECT (answer turn)
thinking: All evidence gathered. Synthesize.
response: The root cause is X. The fix is Y.

WRONG (reasoning outside the envelope)
We need to read this file.
<tool>
  <name>read_file</name>
  <path>y.dart</path>
</tool>

=== 2. TOOL CALL FORMAT ===
<tool>
  <name>TOOL_NAME</name>
  <param>value</param>
  ...
</tool>

- First child is <name>, containing the exact tool name. Then one child tag per parameter.
- The tag name IS the parameter name. The tag body IS the value.
- NO attributes on any tag, ever. Attributes are a hard rejection.
- NO JSON wrapper around the call. NO markdown code fences around the call.
- Write values verbatim. Do NOT HTML-escape: write &&  not &amp;&amp; , write "  not &quot; , write =>  not =&gt;
- Single exception: a literal < inside a value must be written &lt; . Entities are unescaped for you.
- List / int / bool parameters: write the JSON literal in the tag body, e.g. <paths>["a.py","b.py"]</paths>
  (JSON is legal only as a parameter value, never as the call itself.)
- A tool with no parameters gets only the <name> child.
- Only the tools in the TOOL CATALOG exist. Parameter names must match the catalog exactly.

VALID
<tool>
  <name>read_files</name>
  <paths>["a.py","b.py","c.py"]</paths>
</tool>

<tool>
  <name>patch_file</name>
  <path>src/main.py</path>
  <old_content>Hello</old_content>
  <new_content>Ciao</new_content>
</tool>

<tool>
  <name>flutter_analyze</name>
</tool>

INVALID
  <tool>{"tool":"read_file","parameters":{"path":"f.txt"}}</tool>      (JSON wrapper)
  <tool name="read_file"><path>f.txt</path></tool>                     (attribute)
  <tool><path>f.txt</path></tool>                                      (missing <name>)
  I will now read the file... <tool>...</tool>                         (prose before)
  <tool>...</tool> This shows the contents.                            (prose after)
  <content>String get a =&gt; b();</content>                           (needless escaping)

PRE-EMIT CHECKLIST
  [ ] Starts with `<tool>`, ends with `</tool>`, nothing else in the reply body.
  [ ] Has a <name> child with the exact tool name.
  [ ] Zero attributes on any tag.
  [ ] Every parameter tag name matches the tool schema.
  [ ] Exactly one tool call.

=== 3. STOP RULE ===
`</tool>` is end-of-stream. Not a space, not a newline, not a comment. Stop generating.

NEVER SIMULATE. You do not know the tool's output. The orchestrator runs the real tool and
returns the real result next turn. Writing a fabricated result is a protocol violation: it gets
parsed as real data and the loop diverges.

BANNED LITERALS: `User:`, `Assistant:`, `[INTERNAL:` must never appear in your reply, under any
whitespace or punctuation. Rephrase in prose ("the user asked", "per the earlier instruction").

WRONG
<tool><name>read_file</name><path>a.py</path></tool>
User: Tool read_file returned: ...
Assistant: Now I'll read b.py.

=== 4. ITERATION BUDGET / BATCHING ===
Each tool call is one full network round-trip. Wasted iterations are the main cause of timeouts.
- Reading 2+ files -> `read_files`. Chaining `read_file` calls is a protocol violation.
- 2+ dirs / deletes / patterns -> `create_directories`, `delete_files`, `search_in_files` with a list.
- Plan touching 5+ files -> design the whole sequence around batch tools from the start.
- Batch results with status "partial" list the failed paths; retry ONLY those, still batched.
- Exception: `write_file` / `patch_file` are one file per call. Never merge writes into one giant
  call — that invites truncation and a malformed tool block.

=== 5. TURN STRUCTURE AND AUTONOMY ===
"proceed / yes / go / do it / continue" means: act now, without further confirmation.
Never ask permission for routine tool work. Never emit an empty reply.

Reads and analysis: chain freely across turns until you understand the task. No narration.
Writes: one coherent implementation step per turn, ending with its validation, then a STEP REPORT.
  A "step" is one logically complete unit (e.g. one feature slice + its tests), not one file.
Do not stop between a write and its validator — they belong to the same turn.

Forbidden while work remains: "I will ...", "I need to see ...", "Let me check ...",
"Would you like me to ...?", "Shall I continue?", "Ready when you are",
and any "Now I'll do X" not immediately followed by doing X.

Valid end states: task complete, or genuinely blocked with the blocker stated plainly.
Anything else means keep working.

STEP REPORT (mandatory after every implementation step, verbatim structure)
  STEP REPORT
  -----------
  Done:
    - <what actually changed this step>
  Pending:
    - <next concrete task>
  Current state:
    <1-3 sentences: what works, what is wired, what is missing>
Report observed facts only. Carry the latest report forward as context on each subsequent turn.

=== 6. EDITING RULES ===
- Inspect before changing. Inspect (and validate) after changing.
- Modifying an existing file -> `patch_file`, always. `write_file` is for NEW files only.
- `patch_file` old_content must be copied exactly, including indentation, to guarantee one match.
  If the target is ambiguous or appears more than once, re-read and widen the anchor first.
- Never rewrite a whole file to change one line. Never ask the user to apply an edit by hand.
- Relative paths only. Touch only files the task requires.
- Heavy edits: proceed block by block; leave a stable marker if you must return to a block.
- Deletion discipline: verify exact target and scope first. Never delete content outside the
  explicit request or a proven necessity. If a block's relevance is genuinely unclear, leave it in
  place and add a short `TODO(verify): ...` comment instead of removing it — but code YOU author
  must ship clean: no commented-out blocks, no dead code, no debug prints.
- If validation fails twice on the same approach, change strategy; do not retry identically.

FILE PLACEMENT
- Never create files in the project root.
- All temp scripts, scratch data, and generated artifacts go in `.agentic/` (create it if absent).
- Applies to write_file, append_file, patch_file, move_file, and any command that emits files.

=== 7. VALIDATION GATE ===
Wrote or patched a .dart file  -> run `flutter_analyze` in the same turn.
Wrote or patched a .py  file   -> run `python_check`    in the same turn.
Read the full validator output before doing anything else.
- Any ERROR = failure. Fix it, re-run, repeat until zero errors.
- WARNINGS in files you touched = failure. Clear them too.
- INFO / lint hints are acceptable unless they mask a real defect.
- Zero errors = done. Zero errors and zero warnings = correct.
Forbidden: asking the user to run validation, claiming a validator is unavailable without trying,
shipping a final answer while errors remain.

=== 8. SHELL COMMANDS (run_command) ===
Use dedicated tools (`read_files`, `search_in_files`, `list_files`) instead of shell whenever possible.
- Simplest command that does the job. Correctness over cleverness.
- Every executable token must be a real program. Env vars and paths are DATA, never commands.
- No loops, pipes, delayed expansion, or nested parsing unless strictly required.
- Never emit a command whose exact semantics you cannot explain.
- Quoting: the body of <command> is XML, so quotes and backslashes need NO escaping; only < and >
  do (&lt; / &gt;). Quote an argument only when it contains a space or shell metacharacter.
  POSIX shells: prefer 'single quotes'. cmd.exe: single quotes are literal — use "double quotes".

CORRECT: echo %LOCALAPPDATA%
WRONG:   for /f "tokens=2*" %a in ('%LOCALAPPDATA%') do echo %LOCALAPPDATA%
CORRECT: <tool><name>run_command</name><command>find . -name 'package_config.json' | head -1</command></tool>

Before emitting: is there a simpler form? am I invoking a real program? does every token earn
its place? would this run in a clean shell? If any answer is no or unknown, regenerate.

=== 9. SCOPE AND EVIDENCE ===
- Work only inside the current workspace. No `..`, no parent traversal, no absolute system paths.
- Respect configured path filters; exclusions are authoritative.
- If a file isn't in the project, ask for its location rather than widening the search.
- Search narrowly: exact symbols and names first. On miss, REFINE the query; do not broaden to a
  full-tree scan. `search_in_files` already recurses.
- Never claim a tool is unavailable before trying it. Never invent file names, paths, line numbers,
  error text, or results. Never guess where evidence is required.
- Ground every claim in the current workspace and this turn's actual tool output.
- Never echo or stream raw tool output into your reply — summarize. Collapse repetitive output into
  one representative item plus a count.

=== 10. DECISION LADDER (in order) ===
1. Tool needed? Yes -> call it now (batch where applicable). No -> answer directly.
2. Several tools fit? Pick the most direct and reliable.
3. Underspecified but one reading is clearly best? Take it, state the assumption in your answer.
4. Two or more readings equally valid, and the wrong pick would waste real work? Ask once, briefly.
5. Genuinely blocked (missing access, missing file, contradictory requirements)? Say so plainly.

=== 11. QUALITY BAR ===
CODE
- Follow the existing architecture and idioms of the project.
- Production-ready only: no stubs, no placeholders, no partial logic, no unresolved TODOs
  (except the deletion-safety TODO above).
- Handle plausible failures explicitly. Silent failure is forbidden.
- Extract shared logic; no copy-paste duplication. Clear, consistent, idiomatic naming.

UI / VISUAL
- Modern design language: clean layout, deliberate spacing, consistent typography, clear hierarchy.
- Purposeful color; no default flat/legacy look; no placeholder aesthetics.
- Cards, elevated surfaces, subtle shadows, smooth state transitions.
- Motion should feel fluid, never abrupt. Layouts must adapt across screen sizes.
- Consistent rhythm for icons, padding, spacing.

TESTS
- Every feature or function you implement gets tests in the same step.
- Frameworks: Dart/Flutter -> flutter_test. Python -> pytest. JS/TS -> Jest.
- Cover the happy path, error conditions, and boundary cases.
- Co-locate per project convention (`feature.dart` -> `feature_test.dart`).
- Run the test runner if one exists. All tests must pass before you call the task complete.

Delivering low-quality output when higher quality is achievable in scope is a protocol violation.
Expanding the task beyond what was asked is also a protocol violation. Hold both.
"""

_PROCEED_HINT_AUTO: Final[str] = (
    "After every <task_status>, the orchestrator auto-proceeds to the next pending task "
    "-- no confirmation needed."
)

_PROCEED_HINT_MANUAL: Final[str] = (
    "After every <task_status>, the orchestrator pauses for the user to click Proceed, Retry, "
    "Skip, Abort, or Replan; the next prompt arrives as a <task_action> tag -- treat the chosen "
    "action as a directive."
)

_TASK_FLOW_PROMPT: Final[str] = """
=== 12. TASK FLOW PROTOCOL (ACTIVE) ===
This conversation runs in structured task-flow mode for requests needing 3+ distinct steps
(e.g. implement / refactor / fix multiple / build). Trivial single-step requests fall through to
the normal tool protocol, with no task tags.

1) PLAN AND START IN ONE REPLY -- NON-NEGOTIABLE.
The first output of the first iteration must be a complete plan inside one <tasks>...</tasks>
block, IMMEDIATELY followed by <task_status> for task #1 and the first <tool> call -- all three in
the SAME reply. The plan comes first (nothing precedes it) but must NOT be the only thing in the
reply. A <tasks>-only reply is a stall, not a valid first iteration, and costs a full iteration to
a corrective nudge.
Exception: a <task_action>...</task_action> prompt means a plan is already running -- do not re-plan.

Plan format is XML child tags -- NO attributes, NO JSON, exactly like the tool protocol.
Max 12 tasks (plan only the next 12 if more are needed, then re-plan later).
Each <task> child of <tasks> carries:
  <id>1</id>
  <name>short title</name>
  <description>what to do</description>
  <success_criteria>how you know it is done</success_criteria>
  <depends_on>1,2</depends_on>   (optional; comma-separated)

CORRECT (plan + start, single reply):
<tasks>
  <task>
    <id>1</id>
    <name>Read pubspec</name>
    <description>Locate the record dependency</description>
    <success_criteria>Version pin identified</success_criteria>
    <depends_on></depends_on>
  </task>
  <task>
    <id>2</id>
    <name>Patch dep</name>
    <description>Bump to a compatible version</description>
    <success_criteria>flutter_analyze clean</success_criteria>
    <depends_on>1</depends_on>
  </task>
</tasks>
<task_status>
  <id>1</id>
  <status>in_progress</status>
  <note>reading pubspec.yaml to locate the record dep</note>
</task_status>
<tool>
  <name>read_file</name>
  <path>pubspec.yaml</path>
</tool>

WRONG (plan only -- model stalls):
<tasks>...</tasks>
(no task_status, no tool -- wastes the next iteration on a corrective nudge)

2) WORK ONE TASK AT A TIME. Use the normal <tool> protocol for reads/writes; never jump ahead.

3) REPORT STATUS -- after finishing or failing a task, emit exactly one <task_status>:
<task_status>
  <id>1</id>
  <status>done</status>
  <note>one line summary</note>
</task_status>
Every iteration that produces work output must include one; skipping it freezes the UI checklist
and triggers a corrective reminder next turn.

Valid status values:
  - pending      : not started (used only inside <tasks>)
  - in_progress  : work started
  - done         : completed, success_criteria met
  - partial      : progress made, needs another iteration
  - blocked      : needs info from the user (state what is missing)
  - failed       : attempted, could not succeed (explain why in note)
  - skipped      : task deemed unnecessary

4) __PROCEED_HINT__

5) RE-PLANNING -- if the plan proves wrong mid-execution (new tasks found, bad ordering), emit a
fresh <tasks>...</tasks> block with the remaining tasks renumbered; the orchestrator swaps it in
for the open pending tasks. Do NOT re-plan merely because a reply missed task_status/tool -- that
is already a counted stall. Emit the missing pieces for the existing plan instead.

6) FINAL ANSWER -- once every task is done (or definitively skipped/failed), reply in plain
prose/markdown with no task tags. Summarize what was accomplished and surface any caveats.

WRONG (no plan, jumps straight into a tool):
<tool>
  <name>read_file</name>
  <path>lib/main.dart</path>
</tool>

WRONG (raw status update outside a tag):
Task 1 is done.

WRONG (reasoning mixed with the tag):
Let me think... <task_status><id>1</id><status>done</status></task_status>
(reasoning belongs in the `thinking:` envelope from section 1; the task tags plus at most one
<tool> call are the only top-level structured items allowed in a reply.)
"""

_TOOL_CATALOG_HEADER: Final[str] = (
    "=== TOOL CATALOG ===\n"
    "These are the only tools that exist. Parameter names must match exactly.\n"
    "Signature notation: name:type for required parameters, name?:type for optional ones."
)


# =====================================================================
# Wire-format regexes
# =====================================================================

# The exact format the system prompt mandates: <tool>...</tool> with child tags.
# Anchored at both ends so any surrounding prose causes an immediate miss.
_STRICT_TOOL_RE: Final = re.compile(
    r"\A\s*<tool\s*>\s*(.*?)\s*</tool\s*>\s*\Z",
    re.DOTALL | re.IGNORECASE,
    )

# Lightweight heuristic: does the text contain ANY tool-like marker? Used only to
# decide whether to escalate to the malformed-call repair path.
_TOOL_MARKER_RE: Final = re.compile(
    r"<\s*/?\s*tool[\s>/]"
    r"|<\s*/?\s*tool_call[\s>/]"
    r"|<\s*/?\s*function_call[\s>/]"
    r"|<\s*/?\s*invoke[\s>/]"
    r"|\{\s*[\"']tool[\"']\s*:"
    r"|\{\s*[\"']name[\"']\s*:\s*[\"'][a-z_]+[\"']\s*,\s*[\"'](?:parameters|arguments)[\"']"
    r"|```\s*(?:json|tool|xml)\b",
    re.IGNORECASE,
)


# =====================================================================
# Category rules (data only -- no lambdas, so the table stays introspectable)
# =====================================================================

_EXACT_CATEGORIES: Final[Mapping[str, FrozenSet[str]]] = {
    "Filesystem": frozenset(
        {
            "read_file",
            "read_files",
            "write_file",
            "append_file",
            "patch_file",
            "delete_file",
            "delete_files",
            "move_file",
            "copy_file",
            "create_directory",
            "create_directories",
        }
    ),
    "Search": frozenset(
        {
            "list_files",
            "list_files_recursive",
            "search_in_files",
            "find_files",
            "grep",
        }
    ),
    "Shell": frozenset({"run_command", "run_commands"}),
    "Web": frozenset({"web_fetch", "web_search"}),
    "Database": frozenset({"db_query", "db_schema", "db_tables"}),
}

_PREFIX_CATEGORIES: Final[Tuple[Tuple[str, str], ...]] = (
    ("Git", "git_"),
    ("Flutter", "flutter_"),
    ("Dart", "dart_"),
    ("Python", "python_"),
    ("Node", "npm_"),
)

_FALLBACK_CATEGORY: Final[str] = "Other"

# Display order in the rendered catalog. Anything unlisted lands in "Other".
_CATEGORY_ORDER: Final[Tuple[str, ...]] = (
    "Filesystem",
    "Search",
    "Git",
    "Flutter",
    "Dart",
    "Python",
    "Node",
    "Shell",
    "Web",
    "Database",
    _FALLBACK_CATEGORY,
)

# Parameter names that hold a single path / a list of paths. Normalized to
# workspace-relative form before a tool ever sees them.
_PATH_PARAMS: Final[FrozenSet[str]] = frozenset(
    {"path", "file", "filename", "source", "destination", "src", "dst", "directory", "root", "cwd"}
)
_PATH_LIST_PARAMS: Final[FrozenSet[str]] = frozenset({"paths", "files", "sources", "targets"})

_MAX_AUDIT_VALUE_CHARS: Final[int] = 512


# =====================================================================
# Module-level helpers
# =====================================================================


def _error_result(message: str) -> str:
    """Serialize an error envelope the orchestrator and model both understand."""
    return json.dumps({"status": "error", "message": message}, ensure_ascii=False)


def _parse_tool_result(result: Any) -> Dict[str, Any]:
    """Best-effort decode of a tool's return value into a status envelope.

    A tool that returns a bare string (e.g. file contents) is treated as success;
    only an explicit ``{"status": "error"}`` counts as a failure for the breaker.
    """
    if isinstance(result, Mapping):
        return dict(result)
    if not isinstance(result, str):
        return {"status": "success"}
    try:
        parsed = json.loads(result)
    except (json.JSONDecodeError, ValueError, TypeError):
        return {"status": "success"}
    return parsed if isinstance(parsed, dict) else {"status": "success"}


def _stringify_result(result: Any) -> str:
    """Normalize any tool return value to the string contract of ``execute``."""
    if isinstance(result, str):
        return result
    if result is None:
        return json.dumps({"status": "success"}, ensure_ascii=False)
    if isinstance(result, (Mapping, list, tuple, int, float, bool)):
        try:
            return json.dumps(result, ensure_ascii=False, default=str)
        except (TypeError, ValueError):
            pass
    return json.dumps({"status": "success", "result": str(result)}, ensure_ascii=False)


def _audit_safe(params: Mapping[str, Any]) -> Dict[str, Any]:
    """Truncate bulky values so file bodies never bloat the audit log."""
    safe: Dict[str, Any] = {}
    for key, value in params.items():
        if isinstance(value, str) and len(value) > _MAX_AUDIT_VALUE_CHARS:
            safe[key] = f"{value[:_MAX_AUDIT_VALUE_CHARS]}... [{len(value)} chars total]"
        elif isinstance(value, (list, tuple)) and len(value) > 20:
            safe[key] = list(value[:20]) + [f"... [{len(value)} items total]"]
        else:
            safe[key] = value
    return safe


# =====================================================================
# Registry
# =====================================================================


class ToolRegistry:
    """Manages AI-callable tools with path confinement, auditing, and circuit breaking.

    Every filesystem-touching tool receives workspace-relative paths only; escape
    attempts are rejected in :meth:`resolve_path` before any I/O happens. Instances
    are safe to share across threads.
    """

    CIRCUIT_BREAKER_CONFIG: Final[Mapping[str, float]] = {
        "failure_threshold": 5,
        "recovery_timeout": 30.0,
    }

    DEFAULT_TIMEOUT: Final[float] = 30.0

    TOOL_TIMEOUTS: Final[Mapping[str, float]] = {
        "read_file": 20.0,
        "read_files": 60.0,
        "write_file": 20.0,
        "append_file": 20.0,
        "delete_file": 10.0,
        "delete_files": 30.0,
        "patch_file": 25.0,
        "move_file": 20.0,
        "create_directory": 10.0,
        "create_directories": 20.0,
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

    def __init__(
            self,
            base_path: str | Path = ".",
            security_config: Optional[SecurityConfig] = None,
            path_filter: Optional[PathFilter] = None,
            db_connections: Optional[Dict[str, Dict[str, str]]] = None,
    ) -> None:
        self.base_path = Path(base_path).expanduser().resolve()
        self.security_config = security_config or SecurityConfig()
        self.path_filter = path_filter or PathFilter(base_path=self.base_path)
        self.db_connections = db_connections or {}

        self._audit_logger = setup_audit_logger(self.security_config)
        self._lock = threading.RLock()
        self._breakers: Dict[str, CircuitBreaker] = {}
        self._category_cache: Dict[str, str] = {}
        self._catalog_cache: Optional[str] = None

        self.tools: Dict[str, ToolFunc] = {}
        self.definitions: List[ToolDefinition] = []

        # Mutable per-instance copy so callers can tune individual timeouts.
        self.tool_timeouts: Dict[str, float] = dict(self.TOOL_TIMEOUTS)

        # Optional policy hook: tools the security config forbids outright.
        self.blocked_tools: set[str] = set(getattr(self.security_config, "blocked_tools", ()) or ())

        # Local import: the tool modules import this class, so this must stay lazy.
        from . import collect_all_tools

        collect_all_tools(self)

    def __contains__(self, name: object) -> bool:
        return isinstance(name, str) and name in self.tools

    def __len__(self) -> int:
        return len(self.tools)

    def __repr__(self) -> str:  # pragma: no cover - debug aid
        return f"<ToolRegistry base={self.base_path} tools={len(self.tools)}>"

    # ------------------------------------------------------------------
    # Path helpers
    # ------------------------------------------------------------------

    def resolve_path(self, path: str | Path) -> Path:
        """Resolve *path* against the workspace root, refusing anything outside it.

        Uses real path containment (not string prefixing), so a sibling directory
        named like the workspace plus a suffix cannot be reached, and symlinks that
        point outward are rejected after resolution.
        """
        raw = str(path).strip()
        candidate = self.base_path if not raw else (self.base_path / raw)
        resolved = candidate.expanduser().resolve()

        if resolved != self.base_path and not resolved.is_relative_to(self.base_path):
            raise ValueError(
                f"Access denied: '{path}' resolves outside the workspace "
                f"('{self.base_path}'). Use relative paths inside the project."
            )
        return resolved

    def is_within_workspace(self, path: str | Path) -> bool:
        """Non-raising variant of :meth:`resolve_path`."""
        try:
            self.resolve_path(path)
        except (ValueError, OSError):
            return False
        return True

    def _relativise_path(self, path: str) -> str:
        """Rewrite an absolute in-workspace path as workspace-relative."""
        try:
            candidate = Path(path)
        except (TypeError, ValueError):
            return path
        if not candidate.is_absolute():
            return path
        try:
            return candidate.resolve().relative_to(self.base_path).as_posix() or "."
        except (ValueError, OSError):
            return path

    def relativise(self, params: Mapping[str, Any]) -> Dict[str, Any]:
        """Normalize every known path-bearing parameter to relative form."""
        normalized: Dict[str, Any] = dict(params)
        for key, value in params.items():
            if key in _PATH_PARAMS and isinstance(value, str):
                normalized[key] = self._relativise_path(value)
            elif key in _PATH_LIST_PARAMS and isinstance(value, (list, tuple)):
                normalized[key] = [
                    self._relativise_path(item) if isinstance(item, str) else item
                    for item in value
                ]
        return normalized

    # ------------------------------------------------------------------
    # Registration
    # ------------------------------------------------------------------

    def register_tool(
            self,
            name: str,
            func: ToolFunc,
            definition: ToolDefinition,
            timeout: Optional[float] = None,
    ) -> None:
        """Register a tool implementation plus its OpenAPI-style definition.

        Re-registering an existing name replaces both the callable and the
        definition, so the rendered catalog never lists a tool twice.
        """
        if not name or not callable(func):
            raise ValueError(f"Invalid tool registration for {name!r}")

        with self._lock:
            self.tools[name] = func
            self.definitions = [d for d in self.definitions if self._definition_name(d) != name]
            self.definitions.append(definition)
            if timeout is not None:
                self.tool_timeouts[name] = timeout
            self._invalidate_caches()

    def unregister(self, name: str) -> bool:
        """Remove a tool. Returns ``True`` if it existed."""
        with self._lock:
            existed = self.tools.pop(name, None) is not None
            before = len(self.definitions)
            self.definitions = [d for d in self.definitions if self._definition_name(d) != name]
            if existed or len(self.definitions) != before:
                self._invalidate_caches()
            return existed

    def get_timeout(self, name: str) -> float:
        """Timeout for *name*, falling back to :attr:`DEFAULT_TIMEOUT`."""
        return self.tool_timeouts.get(name, self.DEFAULT_TIMEOUT)

    def tool_names(self) -> List[str]:
        return sorted(self.tools)

    def _invalidate_caches(self) -> None:
        self._category_cache.clear()
        self._catalog_cache = None

    @staticmethod
    def _definition_name(definition: Mapping[str, Any]) -> str:
        function = definition.get("function")
        if isinstance(function, Mapping):
            return str(function.get("name", ""))
        return str(definition.get("name", ""))

    def _get_tool_category(self, name: str) -> str:
        """Classify a tool name; exact matches win over prefix rules."""
        cached = self._category_cache.get(name)
        if cached is not None:
            return cached

        category = _FALLBACK_CATEGORY
        for candidate, members in _EXACT_CATEGORIES.items():
            if name in members:
                category = candidate
                break
        else:
            for candidate, prefix in _PREFIX_CATEGORIES:
                if name.startswith(prefix):
                    category = candidate
                    break

        self._category_cache[name] = category
        return category

    # ------------------------------------------------------------------
    # Response classification and strict parsing
    # ------------------------------------------------------------------

    def strict_parse_tool_call(self, text: str) -> Optional[Tuple[str, Dict[str, Any]]]:
        """Parse ONLY the mandated ``<tool>...</tool>`` format.

        Returns ``(tool_name, parameters)`` for a well-formed call to a *known*
        tool, else ``None``. No fuzzy matching and no repair — recovery is the
        malformed-call path's job.
        """
        if not text or "<tool" not in text.lower():
            return None

        match = _STRICT_TOOL_RE.match(text)
        if not match:
            return None
        body = match.group(1)
        if not body:
            return None

        # PRIMARY: XML child-tag format (what the prompt mandates).
        parsed = self._parse_xml_body(body)
        if parsed is not None:
            return parsed

        # FALLBACK: legacy JSON-in-tags format, kept for older transcripts.
        return self._parse_json_body(body)

    def _parse_xml_body(self, body: str) -> Optional[Tuple[str, Dict[str, Any]]]:
        # Local import breaks the tool_dispatch <-> registry import cycle.
        from agent.loop.tool_dispatch import parse_tool_call

        try:
            result = parse_tool_call(body, self.definitions)
        except Exception:  # noqa: BLE001 - a parser crash must not kill the turn
            logger.debug("XML tool-call parser raised; treating as unparsed", exc_info=True)
            return None

        if not result:
            return None
        name, params = result
        if not isinstance(name, str) or name not in self.tools:
            return None
        return name, dict(params) if isinstance(params, Mapping) else {}

    def _parse_json_body(self, body: str) -> Optional[Tuple[str, Dict[str, Any]]]:
        try:
            data = json.loads(body)
        except (json.JSONDecodeError, ValueError):
            return None
        if not isinstance(data, dict):
            return None

        name = data.get("tool") or data.get("name")
        if not isinstance(name, str) or name not in self.tools:
            return None

        params = data.get("parameters", data.get("arguments", {}))
        return name, dict(params) if isinstance(params, Mapping) else {}

    def classify_response(self, text: str) -> ResponseKind:
        """Classify a model reply without running the full repair chain.

        * ``tool_call``    — strict format matched a known tool; ready to execute.
        * ``final_answer`` — no tool markers; treat the reply as prose.
        * ``malformed``    — tool-like markers present but strict parsing failed;
          escalate to the malformed-call repair path.
        """
        if not text or not text.strip():
            return "final_answer"
        if self.strict_parse_tool_call(text) is not None:
            return "tool_call"
        if _TOOL_MARKER_RE.search(text):
            return "malformed"
        return "final_answer"

    @staticmethod
    def is_empty_response(text: Optional[str]) -> bool:
        """True when the model returned nothing usable (retry-worthy)."""
        return not text or not text.strip()

    # ------------------------------------------------------------------
    # Execution
    # ------------------------------------------------------------------

    def execute(self, tool_name: str, parameters: Optional[Mapping[str, Any]] = None) -> str:
        """Run a tool and return its result as a string.

        Handles policy checks, circuit breaking, path normalization, parameter
        validation, structured error reporting, and auditing. Never raises: every
        failure comes back as an ``{"status": "error"}`` envelope.
        """
        params: Dict[str, Any] = dict(parameters or {})

        if tool_name not in self.tools:
            return self._reject(
                tool_name,
                params,
                f"Unknown tool: '{tool_name}'. Available: {', '.join(self.tool_names())}",
            )

        if tool_name in self.blocked_tools:
            return self._reject(
                tool_name, params, f"Tool '{tool_name}' is disabled by security policy."
            )

        breaker = self._breaker_for(tool_name)
        if not breaker.allow_request():
            recovery = getattr(breaker, "recovery_timeout", self.CIRCUIT_BREAKER_CONFIG["recovery_timeout"])
            return self._reject(
                tool_name,
                params,
                f"Tool '{tool_name}' is temporarily disabled after repeated failures. "
                f"Recovers in ~{float(recovery):.0f}s. Use a different approach meanwhile.",
            )

        func = self.tools[tool_name]
        safe_params = self.relativise(params)

        # Validate the call signature BEFORE invoking, so a TypeError raised inside
        # the tool body is never misreported as "invalid parameters" -- and so the
        # model's own malformed calls do not trip the breaker for a healthy tool.
        signature_error = self._check_signature(func, safe_params)
        if signature_error is not None:
            return self._reject(
                tool_name,
                safe_params,
                f"Invalid parameters for '{tool_name}': {signature_error}. "
                f"Expected: {tool_name}({self.signature_of(tool_name)}).",
                record_failure=False,
            )

        try:
            result = _stringify_result(func(**safe_params))
        except ValueError as exc:
            return self._reject(tool_name, safe_params, f"Path or value error: {exc}", breaker=breaker)
        except (OSError, PermissionError) as exc:
            return self._reject(tool_name, safe_params, f"Filesystem error: {exc}", breaker=breaker)
        except Exception as exc:  # noqa: BLE001 - a tool crash must not kill the loop
            logger.exception("Tool '%s' raised", tool_name)
            return self._reject(
                tool_name, safe_params, f"{type(exc).__name__}: {exc}", breaker=breaker
            )

        if _parse_tool_result(result).get("status") == "error":
            breaker.record_failure()
        else:
            breaker.record_success()

        audit_log(self._audit_logger, tool_name, _audit_safe(safe_params), result)
        return result

    def _breaker_for(self, tool_name: str) -> CircuitBreaker:
        with self._lock:
            breaker = self._breakers.get(tool_name)
            if breaker is None:
                breaker = CircuitBreaker(
                    name=f"tool:{tool_name}",
                    failure_threshold=int(self.CIRCUIT_BREAKER_CONFIG["failure_threshold"]),
                    recovery_timeout=float(self.CIRCUIT_BREAKER_CONFIG["recovery_timeout"]),
                )
                self._breakers[tool_name] = breaker
            return breaker

    @staticmethod
    def _check_signature(func: ToolFunc, params: Mapping[str, Any]) -> Optional[str]:
        """Return an error message if *params* cannot bind to *func*, else ``None``."""
        try:
            inspect.signature(func).bind(**params)
        except TypeError as exc:
            return str(exc)
        except (ValueError, KeyError):
            # Builtins / C-extensions expose no signature: let the call decide.
            return None
        return None

    def _reject(
            self,
            tool_name: str,
            params: Mapping[str, Any],
            message: str,
            *,
            breaker: Optional[CircuitBreaker] = None,
            record_failure: bool = True,
    ) -> str:
        """Build, audit, and return an error envelope in one step."""
        if breaker is not None and record_failure:
            breaker.record_failure()
        error = _error_result(message)
        audit_log(self._audit_logger, tool_name, _audit_safe(params), error)
        return error

    # ------------------------------------------------------------------
    # System prompt generation
    # ------------------------------------------------------------------

    def get_system_prompt(
            self,
            project_context: Optional[str] = None,
            task_mode: TaskMode | str = "open",
    ) -> str:
        """Assemble the full system prompt: base rules, context, protocol, catalog.

        ``project_context`` (typically the contents of ``.agent.md``) is inserted
        between the base rules and the tool catalog. ``task_mode`` of
        ``task_compliance`` / ``task_compliance_auto`` appends the TASK FLOW
        PROTOCOL section; ``open`` omits it entirely.
        """
        sections: List[str] = [_BASE_PROMPT.strip()]

        if project_context and project_context.strip():
            sections.append(
                "=== PROJECT CONTEXT (from .agent.md) ===\n" + project_context.strip()
            )

        if task_mode in ("task_compliance", "task_compliance_auto"):
            sections.append(self._task_flow_prompt(auto=task_mode == "task_compliance_auto"))

        sections.append(self._tool_catalog())
        return "\n\n".join(sections)

    def _tool_catalog(self) -> str:
        """Render the tool catalog, grouped and alphabetized (cached per revision)."""
        if self._catalog_cache is not None:
            return self._catalog_cache

        grouped: Dict[str, List[str]] = {}
        for definition in self.definitions:
            function = definition.get("function")
            function = function if isinstance(function, Mapping) else definition
            name = str(function.get("name") or "unknown")
            description = " ".join(str(function.get("description") or "").split())
            entry = f"- {name}({self._format_signature(function)})"
            if description:
                entry = f"{entry}: {description}"
            grouped.setdefault(self._get_tool_category(name), []).append(entry)

        parts: List[str] = [_TOOL_CATALOG_HEADER]
        rendered_any = False
        known = set(_CATEGORY_ORDER)
        ordered = list(_CATEGORY_ORDER) + sorted(set(grouped) - known)

        for category in ordered:
            entries = grouped.get(category)
            if not entries:
                continue
            rendered_any = True
            parts.append(f"[{category}]\n" + "\n".join(sorted(entries)))

        if not rendered_any:
            if self.tools:
                parts.append(
                    "(No tool definitions registered; callables available: "
                    + ", ".join(self.tool_names())
                    + ")"
                )
            else:
                parts.append("(No tools registered — answer directly, do not emit tool calls.)")

        catalog = "\n\n".join(parts)
        self._catalog_cache = catalog
        return catalog

    @staticmethod
    def _task_flow_prompt(auto: bool) -> str:
        """Task-flow protocol section, parsed downstream by ``common.loop.task_protocol``."""
        hint = _PROCEED_HINT_AUTO if auto else _PROCEED_HINT_MANUAL
        return textwrap.dedent(_TASK_FLOW_PROMPT).strip().replace("__PROCEED_HINT__", hint)

    @staticmethod
    def _base_system_prompt() -> List[str]:
        """Immutable base prompt (no tools). Kept for backward compatibility."""
        return [_BASE_PROMPT.strip()]

    def signature_of(self, tool_name: str) -> str:
        """Human-readable signature for *tool_name*, or ``unknown tool``."""
        for definition in self.definitions:
            function = definition.get("function")
            function = function if isinstance(function, Mapping) else definition
            if function.get("name") == tool_name:
                return self._format_signature(function)
        return "unknown tool"

    @staticmethod
    def _format_signature(function: Mapping[str, Any]) -> str:
        """Format an OpenAPI-style parameter spec as ``name:type, opt?:type``.

        Required parameters are listed first so the model sees them even if the
        line is truncated by a context squeeze.
        """
        parameters = function.get("parameters") or {}
        properties = parameters.get("properties") or {}
        if not properties:
            return "no parameters"

        required = set(parameters.get("required") or ())
        required_parts: List[str] = []
        optional_parts: List[str] = []

        for key, spec in properties.items():
            spec = spec if isinstance(spec, Mapping) else {}
            type_name = spec.get("type") or "any"
            if isinstance(type_name, (list, tuple)):
                type_name = "|".join(str(item) for item in type_name)
            if type_name == "array":
                items = spec.get("items")
                item_type = (items or {}).get("type") if isinstance(items, Mapping) else None
                type_name = f"array[{item_type or 'any'}]"

            if key in required:
                required_parts.append(f"{key}:{type_name}")
            else:
                optional_parts.append(f"{key}?:{type_name}")

        return ", ".join(required_parts + optional_parts)

#:::::::::::::::::::::::::::::::::OLD

# from __future__ import annotations
#
# import json
# import re
# from pathlib import Path
# from typing import Any, Callable, Dict, List, Literal, Optional, Tuple, TypeVar
#
# from agent.core.path_filter import PathFilter
# from agent.core.policy import SecurityConfig
# from agent.utils.audit import setup_audit_logger, audit_log
# from agent.utils.circuit_breaker import CircuitBreaker
#
# T = TypeVar("T")
#
# _BASE_PROMPT = r"""
# === ROLE ===
# You are a senior software analyst and engineer operating inside an automated agent loop.
# Your reply is parsed by a machine, not read by a human. Format compliance is as important as correctness.
# Complete the user's request fully, using every tool available. Do only what the task requires:
# no unrequested exploration, no unrelated refactors, no hand-offs back to the user mid-task.
#
# === 1. OUTPUT CONTRACT ===
# Every reply is exactly ONE of these two shapes. There is no third shape.
#
#   A) TOOL TURN   -> exactly one <tool>...</tool> block, and nothing else.
#   B) ANSWER TURN -> the user-facing final answer (task complete, or genuinely blocked).
#
# If you produce reasoning, it MUST be confined to the reasoning envelope:
#
#   thinking: <your reasoning>
#   response: <shape A or shape B>
#
# Everything up to and including the `response:` marker is stripped before parsing.
# If your platform has a native reasoning channel, that channel IS the thinking block; do not
# duplicate it in the visible reply. Never let reasoning appear outside the envelope.
#
# Reasoning budget: at most ~150 words, always. The overwhelming majority of your output must be
# the tool call or the answer. If your reasoning block grows past a short paragraph, delete it,
# replace it with two sentences, and emit the call.
#
# CORRECT (tool turn)
# thinking: User wants X. Need to see y.dart first.
# response:
# <tool>
#   <name>read_file</name>
#   <path>y.dart</path>
# </tool>
#
# CORRECT (answer turn)
# thinking: All evidence gathered. Synthesize.
# response: The root cause is X. The fix is Y.
#
# WRONG (reasoning outside the envelope)
# We need to read this file.
# <tool>
#   <name>read_file</name>
#   <path>y.dart</path>
# </tool>
#
# === 2. TOOL CALL FORMAT ===
# <tool>
#   <name>TOOL_NAME</name>
#   <param>value</param>
#   ...
# </tool>
#
# - First child is <name>, containing the exact tool name. Then one child tag per parameter.
# - The tag name IS the parameter name. The tag body IS the value.
# - NO attributes on any tag, ever. Attributes are a hard rejection.
# - NO JSON wrapper around the call. NO markdown code fences around the call.
# - Write values verbatim. Do NOT HTML-escape: write &&  not &amp;&amp; , write "  not &quot; , write =>  not =&gt;
# - Single exception: a literal < inside a value must be written &lt; . Entities are unescaped for you.
# - List / int / bool parameters: write the JSON literal in the tag body, e.g. <paths>["a.py","b.py"]</paths>
#   (JSON is legal only as a parameter value, never as the call itself.)
# - A tool with no parameters gets only the <name> child.
#
# VALID
# <tool>
#   <name>read_files</name>
#   <paths>["a.py","b.py","c.py"]</paths>
# </tool>
#
# <tool>
#   <name>patch_file</name>
#   <path>src/main.py</path>
#   <old_content>Hello</old_content>
#   <new_content>Ciao</new_content>
# </tool>
#
# <tool>
#   <name>flutter_analyze</name>
# </tool>
#
# INVALID
#   <tool>{"tool":"read_file","parameters":{"path":"f.txt"}}</tool>      (JSON wrapper)
#   <tool name="read_file"><path>f.txt</path></tool>                     (attribute)
#   <tool><path>f.txt</path></tool>                                      (missing <name>)
#   I will now read the file... <tool>...</tool>                         (prose before)
#   <tool>...</tool> This shows the contents.                            (prose after)
#   <content>String get a =&gt; b();</content>                           (needless escaping)
#
# PRE-EMIT CHECKLIST
#   [ ] Starts with `<tool>`, ends with `</tool>`, nothing else in the reply body.
#   [ ] Has a <name> child with the exact tool name.
#   [ ] Zero attributes on any tag.
#   [ ] Every parameter tag name matches the tool schema.
#   [ ] Exactly one tool call.
#
# === 3. STOP RULE ===
# `</tool>` is end-of-stream. Not a space, not a newline, not a comment. Stop generating.
#
# NEVER SIMULATE. You do not know the tool's output. The orchestrator runs the real tool and
# returns the real result next turn. Writing a fabricated result is a protocol violation: it gets
# parsed as real data and the loop diverges.
#
# BANNED LITERALS: `User:`, `Assistant:`, `[INTERNAL:` must never appear in your reply, under any
# whitespace or punctuation. Rephrase in prose ("the user asked", "per the earlier instruction").
#
# WRONG
# <tool><name>read_file</name><path>a.py</path></tool>
# User: Tool read_file returned: ...
# Assistant: Now I'll read b.py.
#
# === 4. ITERATION BUDGET / BATCHING ===
# Each tool call is one full network round-trip. Wasted iterations are the main cause of timeouts.
# - Reading 2+ files -> `read_files`. Chaining `read_file` calls is a protocol violation.
# - 2+ dirs / deletes / patterns -> `create_directories`, `delete_files`, `search_in_files` with a list.
# - Plan touching 5+ files -> design the whole sequence around batch tools from the start.
# - Batch results with status "partial" list the failed paths; retry ONLY those, still batched.
# - Exception: `write_file` / `patch_file` are one file per call. Never merge writes into one giant
#   call — that invites truncation and a malformed tool block.
#
# === 5. TURN STRUCTURE AND AUTONOMY ===
# "proceed / yes / go / do it / continue" means: act now, without further confirmation.
# Never ask permission for routine tool work. Never emit an empty reply.
#
# Reads and analysis: chain freely across turns until you understand the task. No narration.
# Writes: one coherent implementation step per turn, ending with its validation, then a STEP REPORT.
#   A "step" is one logically complete unit (e.g. one feature slice + its tests), not one file.
# Do not stop between a write and its validator — they belong to the same turn.
#
# Forbidden while work remains: "I will ...", "I need to see ...", "Let me check ...",
# "Would you like me to ...?", "Shall I continue?", "Ready when you are",
# and any "Now I'll do X" not immediately followed by doing X.
#
# Valid end states: task complete, or genuinely blocked with the blocker stated plainly.
# Anything else means keep working.
#
# STEP REPORT (mandatory after every implementation step, verbatim structure)
#   STEP REPORT
#   -----------
#   Done:
#     - <what actually changed this step>
#   Pending:
#     - <next concrete task>
#   Current state:
#     <1-3 sentences: what works, what is wired, what is missing>
# Report observed facts only. Carry the latest report forward as context on each subsequent turn.
#
# === 6. EDITING RULES ===
# - Inspect before changing. Inspect (and validate) after changing.
# - Modifying an existing file -> `patch_file`, always. `write_file` is for NEW files only.
# - `patch_file` old_content must be copied exactly, including indentation, to guarantee one match.
#   If the target is ambiguous or appears more than once, re-read and widen the anchor first.
# - Never rewrite a whole file to change one line. Never ask the user to apply an edit by hand.
# - Relative paths only. Touch only files the task requires.
# - Heavy edits: proceed block by block; leave a stable marker if you must return to a block.
# - Deletion discipline: verify exact target and scope first. Never delete content outside the
#   explicit request or a proven necessity. If a block's relevance is genuinely unclear, leave it in
#   place and add a short `TODO(verify): ...` comment instead of removing it — but code YOU author
#   must ship clean: no commented-out blocks, no dead code, no debug prints.
# - If validation fails twice on the same approach, change strategy; do not retry identically.
#
# FILE PLACEMENT
# - Never create files in the project root.
# - All temp scripts, scratch data, and generated artifacts go in `.agentic/` (create it if absent).
# - Applies to write_file, append_file, patch_file, move_file, and any command that emits files.
#
# === 7. VALIDATION GATE ===
# Wrote or patched a .dart file  -> run `flutter_analyze` in the same turn.
# Wrote or patched a .py  file   -> run `python_check`    in the same turn.
# Read the full validator output before doing anything else.
# - Any ERROR = failure. Fix it, re-run, repeat until zero errors.
# - WARNINGS in files you touched = failure. Clear them too.
# - INFO / lint hints are acceptable unless they mask a real defect.
# - Zero errors = done. Zero errors and zero warnings = correct.
# Forbidden: asking the user to run validation, claiming a validator is unavailable without trying,
# shipping a final answer while errors remain.
#
# === 8. SHELL COMMANDS (run_command) ===
# Use dedicated tools (`read_files`, `search_in_files`, `list_files`) instead of shell whenever possible.
# - Simplest command that does the job. Correctness over cleverness.
# - Every executable token must be a real program. Env vars and paths are DATA, never commands.
# - No loops, pipes, delayed expansion, or nested parsing unless strictly required.
# - Never emit a command whose exact semantics you cannot explain.
# - Quoting: the body of <command> is XML, so quotes and backslashes need NO escaping; only < and >
#   do (&lt; / &gt;). Quote an argument only when it contains a space or shell metacharacter.
#   POSIX shells: prefer 'single quotes'. cmd.exe: single quotes are literal — use "double quotes".
#
# CORRECT: echo %LOCALAPPDATA%
# WRONG:   for /f "tokens=2*" %a in ('%LOCALAPPDATA%') do echo %LOCALAPPDATA%
# CORRECT: <tool><name>run_command</name><command>find . -name 'package_config.json' | head -1</command></tool>
#
# Before emitting: is there a simpler form? am I invoking a real program? does every token earn
# its place? would this run in a clean shell? If any answer is no or unknown, regenerate.
#
# === 9. SCOPE AND EVIDENCE ===
# - Work only inside the current workspace. No `..`, no parent traversal, no absolute system paths.
# - Respect configured path filters; exclusions are authoritative.
# - If a file isn't in the project, ask for its location rather than widening the search.
# - Search narrowly: exact symbols and names first. On miss, REFINE the query; do not broaden to a
#   full-tree scan. `search_in_files` already recurses.
# - Never claim a tool is unavailable before trying it. Never invent file names, paths, line numbers,
#   error text, or results. Never guess where evidence is required.
# - Ground every claim in the current workspace and this turn's actual tool output.
# - Never echo or stream raw tool output into your reply — summarize. Collapse repetitive output into
#   one representative item plus a count.
#
# === 10. DECISION LADDER (in order) ===
# 1. Tool needed? Yes -> call it now (batch where applicable). No -> answer directly.
# 2. Several tools fit? Pick the most direct and reliable.
# 3. Underspecified but one reading is clearly best? Take it, state the assumption in your answer.
# 4. Two or more readings equally valid, and the wrong pick would waste real work? Ask once, briefly.
# 5. Genuinely blocked (missing access, missing file, contradictory requirements)? Say so plainly.
#
# === 11. QUALITY BAR ===
# CODE
# - Follow the existing architecture and idioms of the project.
# - Production-ready only: no stubs, no placeholders, no partial logic, no unresolved TODOs
#   (except the deletion-safety TODO above).
# - Handle plausible failures explicitly. Silent failure is forbidden.
# - Extract shared logic; no copy-paste duplication. Clear, consistent, idiomatic naming.
#
# UI / VISUAL
# - Modern design language: clean layout, deliberate spacing, consistent typography, clear hierarchy.
# - Purposeful color; no default flat/legacy look; no placeholder aesthetics.
# - Cards, elevated surfaces, subtle shadows, smooth state transitions.
# - Motion should feel fluid, never abrupt. Layouts must adapt across screen sizes.
# - Consistent rhythm for icons, padding, spacing.
#
# TESTS
# - Every feature or function you implement gets tests in the same step.
# - Frameworks: Dart/Flutter -> flutter_test. Python -> pytest. JS/TS -> Jest.
# - Cover the happy path, error conditions, and boundary cases.
# - Co-locate per project convention (`feature.dart` -> `feature_test.dart`).
# - Run the test runner if one exists. All tests must pass before you call the task complete.
#
# Delivering low-quality output when higher quality is achievable in scope is a protocol violation.
# Expanding the task beyond what was asked is also a protocol violation. Hold both.
# """
#
# # Exact format the system prompt mandates: <tool>...</tool> with child tags.
# # Anchored start/end so any surrounding text causes an immediate miss.
# # Matches both the new XML child-tag format and the legacy JSON-in-tags format.
# _STRICT_TOOL_RE = re.compile(
#     r"^\s*<tool>\s*(.*?)\s*</tool>\s*$",
#     re.DOTALL | re.IGNORECASE,
# )
#
# # Lightweight heuristic: does the text contain ANY tool-like marker?
# # Used only to decide whether to escalate to the complex malformed-call path.
# _TOOL_MARKER_RE = re.compile(
#     r"<\s*tool[\s>/]"
#     r"|<\s*tool_call[\s>/]"
#     r"|<\s*function_call[\s>/]"
#     r'|\{\s*["\']tool["\']'
#     r"|```\s*(?:json|tool)\b",
#     re.IGNORECASE,
# )
#
# ResponseKind = Literal["tool_call", "final_answer", "malformed"]
#
#
# def _parse_tool_result(result: str) -> Dict[str, Any]:
#     """Parse tool result JSON, defaulting to success if unparseable."""
#     try:
#         parsed = json.loads(result)
#         return parsed if isinstance(parsed, dict) else {"status": "success"}
#     except (json.JSONDecodeError, ValueError):
#         return {"status": "success"}
#
#
# def _error_result(message: str) -> str:
#     """Wrap error message as JSON."""
#     return json.dumps({"status": "error", "message": message})
#
#
# class ToolRegistry:
#     """
#     Manages AI-callable tools with path confinement, security, and circuit breaking.
#
#     Optimized for usability, security, and clear error reporting.
#     All filesystem access is confined to base_path.
#     """
#
#     CIRCUIT_BREAKER_CONFIG = {
#         "failure_threshold": 5,
#         "recovery_timeout": 30.0,
#     }
#
#     TOOL_CATEGORIES = {
#         "Filesystem": {
#             "read_files",
#             "patch_file",
#             "read_file",
#             "write_file",
#             "append_file",
#             "delete_file",
#             "delete_files",
#             "move_file",
#             "create_directory",
#             "create_directories",
#         },
#         "Search": {
#             "list_files",
#             "list_files_recursive",
#             "search_in_files",
#             "find_files",
#         },
#         "Git": lambda name: name.startswith("git_"),
#         "Flutter": lambda name: name.startswith("flutter_"),
#         "Python": lambda name: name.startswith("python_"),
#         "Shell": {"run_command"},
#         "Web": {"web_fetch", "web_search"},
#     }
#
#     def __init__(
#             self,
#             base_path: str = ".",
#             security_config: Optional[SecurityConfig] = None,
#             path_filter: Optional[PathFilter] = None,
#             db_connections: Optional[Dict[str, Dict[str, str]]] = None,
#     ):
#         self.base_path = Path(base_path).resolve()
#         self.security_config = security_config or SecurityConfig()
#         self.path_filter = path_filter or PathFilter(base_path=self.base_path)
#         self.db_connections = db_connections or {}
#
#         self._audit_logger = setup_audit_logger(self.security_config)
#         self._tool_circuit_breakers: Dict[str, CircuitBreaker] = {}
#         self._category_cache: Dict[str, str] = {}
#
#         self.tools: Dict[str, Callable] = {}
#         self.definitions: List[Dict[str, Any]] = []
#
#         self.tool_timeouts: Dict[str, float] = {
#             "read_file": 20.0,
#             "read_files": 60.0,
#             "write_file": 20.0,
#             "append_file": 20.0,
#             "delete_file": 10.0,
#             "delete_files": 30.0,
#             "patch_file": 25.0,
#             "move_file": 20.0,
#             "create_directory": 10.0,
#             "create_directories": 20.0,
#             "list_files": 60.0,
#             "list_files_recursive": 125.0,
#             "search_in_files": 60.0,
#             "find_files": 60.0,
#             "git_status": 10.0,
#             "git_branches": 5.0,
#             "git_log": 10.0,
#             "git_diff": 15.0,
#             "git_checkout": 10.0,
#             "git_commit": 15.0,
#             "flutter_analyze": 45.0,
#             "python_check": 30.0,
#             "python_lint": 30.0,
#             "python_format": 30.0,
#             "python_test": 60.0,
#             "run_command": 30.0,
#             "web_fetch": 20.0,
#             "web_search": 20.0,
#         }
#
#         from . import collect_all_tools
#
#         collect_all_tools(self)
#
#     # ------------------------------------------------------------------
#     # Path helpers
#     # ------------------------------------------------------------------
#
#     def resolve_path(self, path: str) -> Path:
#         """Resolve path relative to base_path, ensuring it stays within bounds."""
#         resolved = (self.base_path / path).resolve()
#         if not str(resolved).startswith(str(self.base_path)):
#             raise ValueError(
#                 f"Access denied: '{path}' -> '{resolved}' is outside '{self.base_path}'. "
#                 "Use relative paths within the project."
#             )
#         return resolved
#
#     def _relativise_path(self, path: str) -> str:
#         """Convert absolute path to relative if under base_path."""
#         p = Path(path)
#         if p.is_absolute():
#             try:
#                 return str(p.relative_to(self.base_path))
#             except ValueError:
#                 return path
#         return path
#
#     def relativise(self, params: Dict[str, Any]) -> Dict[str, Any]:
#         """Normalize 'path' and 'paths' parameters to relative form."""
#         result = dict(params)
#         if "path" in result and isinstance(result["path"], str):
#             result["path"] = self._relativise_path(result["path"])
#         if "paths" in result and isinstance(result["paths"], list):
#             result["paths"] = [
#                 self._relativise_path(p) if isinstance(p, str) else p
#                 for p in result["paths"]
#             ]
#         return result
#
#     # ------------------------------------------------------------------
#     # Tool registration
#     # ------------------------------------------------------------------
#
#     def register_tool(
#             self, name: str, func: Callable, definition: Dict[str, Any]
#     ) -> None:
#         """Register a tool, its implementation, and its OpenAPI-style definition."""
#         self.tools[name] = func
#         self.definitions.append(definition)
#         self._category_cache.clear()
#
#     def unregister(self, name: str) -> None:
#         """Remove a tool by name. No-op if the tool is not registered."""
#         self.tools.pop(name, None)
#         self.definitions = [
#             d for d in self.definitions
#             if d.get("function", {}).get("name") != name
#         ]
#         self._category_cache.clear()
#
#     def _get_tool_category(self, name: str) -> str:
#         """Get category for tool name (cached)."""
#         if name in self._category_cache:
#             return self._category_cache[name]
#         category = "Other"
#         for cat, spec in self.TOOL_CATEGORIES.items():
#             if callable(spec):
#                 if spec(name):
#                     category = cat
#                     break
#             elif name in spec:
#                 category = cat
#                 break
#         self._category_cache[name] = category
#         return category
#
#     # ------------------------------------------------------------------
#     # Response classification and strict parsing
#     # ------------------------------------------------------------------
#
#     def strict_parse_tool_call(self, text: str) -> Optional[Tuple[str, Dict[str, Any]]]:
#         """Parse ONLY the exact mandated format: <tool>...</tool>.
#
#         Returns (tool_name, parameters) if the response is a well-formed,
#         known tool call; None otherwise.
#         No fuzzy matching, no fallbacks.
#         """
#         if not text:
#             return None
#
#         m = _STRICT_TOOL_RE.match(text)
#         if not m:
#             return None
#
#         body = m.group(1)
#
#         # PRIMARY: try XML child-tag parser
#         from agent.loop.tool_dispatch import _parse_xml_tool_call
#         xml_result = _parse_xml_tool_call(body, self.definitions)
#         if xml_result is not None:
#             name, params = xml_result
#             if name in self.tools:
#                 return name, params
#
#         # FALLBACK: try legacy JSON-in-tags parser
#         try:
#             data = json.loads(body)
#         except json.JSONDecodeError:
#             return None
#
#         if not isinstance(data, dict):
#             return None
#
#         name = data.get("tool")
#         params = data.get("parameters", {})
#
#         if not isinstance(name, str) or not name:
#             return None
#         if not isinstance(params, dict):
#             params = {}
#         if name not in self.tools:
#             return None
#
#         return name, params
#
#     def classify_response(self, text: str) -> ResponseKind:
#         """Classify a model reply without running the full parser chain.
#
#         Returns one of:
#           "tool_call"    — strict format matched, ready to execute
#           "final_answer" — no tool markers present, treat as prose
#           "malformed"    — has tool-like markers but failed strict parse;
#                            escalate to looks_like_malformed_tool_call
#         """
#         if not text:
#             return "final_answer"
#
#         if self.strict_parse_tool_call(text) is not None:
#             return "tool_call"
#
#         if _TOOL_MARKER_RE.search(text):
#             return "malformed"
#
#         return "final_answer"
#
#     # ------------------------------------------------------------------
#     # Execution
#     # ------------------------------------------------------------------
#
#     def execute(self, tool_name: str, parameters: Dict[str, Any]) -> str:
#         """Execute a tool with given parameters.
#
#         Handles circuit breaking, path normalization, error reporting, and auditing.
#         All filesystem access is confined to base_path.
#         """
#         if tool_name not in self.tools:
#             err = _error_result(
#                 f"Unknown tool: {tool_name}. Available: {', '.join(sorted(self.tools.keys()))}"
#             )
#             audit_log(self._audit_logger, tool_name, parameters or {}, err)
#             return err
#
#         cb = self._tool_circuit_breakers.setdefault(
#             tool_name,
#             CircuitBreaker(
#                 name=f"tool:{tool_name}",
#                 failure_threshold=self.CIRCUIT_BREAKER_CONFIG["failure_threshold"],
#                 recovery_timeout=self.CIRCUIT_BREAKER_CONFIG["recovery_timeout"],
#             ),
#         )
#
#         if not cb.allow_request():
#             err = _error_result(
#                 f"Tool '{tool_name}' is temporarily disabled (too many failures). "
#                 f"Recovers in {cb.recovery_timeout:.0f}s."
#             )
#             audit_log(self._audit_logger, tool_name, parameters or {}, err)
#             return err
#
#         try:
#             safe_params = self.relativise(parameters or {})
#             result = self.tools[tool_name](**safe_params)
#
#             parsed = _parse_tool_result(result)
#             if parsed.get("status") == "error":
#                 cb.record_failure()
#             else:
#                 cb.record_success()
#
#             audit_log(self._audit_logger, tool_name, safe_params, result)
#             return result
#
#         except TypeError as e:
#             err = _error_result(f"Invalid parameters: {e}")
#             cb.record_failure()
#             audit_log(self._audit_logger, tool_name, parameters or {}, err)
#             return err
#
#         except ValueError as e:
#             err = _error_result(f"Path error: {e}")
#             cb.record_failure()
#             audit_log(self._audit_logger, tool_name, parameters or {}, err)
#             return err
#
#         except Exception as e:
#             err = _error_result(str(e))
#             cb.record_failure()
#             audit_log(self._audit_logger, tool_name, parameters or {}, err)
#             return err
#
#     # ------------------------------------------------------------------
#     # System prompt generation
#     # ------------------------------------------------------------------
#
#     def get_system_prompt(
#             self,
#             project_context: Optional[str] = None,
#             task_mode: str = "open",
#     ) -> str:
#         """Generate production system prompt with tool catalog.
#
#         When ``project_context`` is provided it is merged into the prompt
#         as a [PROJECT CONTEXT] block between the base rules and the tool
#         catalog. This is what gives the model project-specific knowledge
#         (read from ``.agent.md`` by :func:`load_project_context`).
#
#         When ``task_mode`` is ``task_compliance`` or
#         ``task_compliance_auto`` the TASK FLOW PROTOCOL section is
#         appended, instructing the model to declare a plan with
#         ``<tasks>`` and report progress with ``<task_status>``. In
#         ``open`` mode the section is omitted entirely.
#         """
#         lines = self._base_system_prompt()
#
#         if project_context and project_context.strip():
#             lines.append("")
#             lines.append("PROJECT CONTEXT (from .agent.md)")
#             lines.append("================================")
#             for cline in project_context.strip().splitlines():
#                 lines.append(cline)
#             lines.append("")
#
#         if task_mode in ("task_compliance", "task_compliance_auto"):
#             lines.extend(self._task_flow_prompt_lines(auto=task_mode == "task_compliance_auto"))
#
#         groups: Dict[str, List[str]] = {cat: [] for cat in self.TOOL_CATEGORIES}
#         groups["Other"] = []
#
#         for defn in self.definitions:
#             fn = defn.get("function", {})
#             name = fn.get("name", "unknown")
#             desc = (fn.get("description", "") or "").strip().replace("\n", " ")
#             sig = self._format_signature(fn)
#             cat = self._get_tool_category(name)
#             groups[cat].append(f"- {name}({sig}): {desc}")
#
#         for cat_name in (
#                 "Filesystem",
#                 "Search",
#                 "Git",
#                 "Flutter",
#                 "Python",
#                 "Shell",
#                 "Web",
#                 "Other",
#         ):
#             entries = groups.get(cat_name, [])
#             if not entries:
#                 continue
#             lines.append(f"[{cat_name}]")
#             lines.extend(entries)
#             lines.append("")
#
#         if not any(groups.values()):
#             lines.append("(No tool definitions registered)")
#             if self.tools:
#                 lines.append("Registered: " + ", ".join(sorted(self.tools.keys())))
#
#         return "\n".join(lines)
#
#     @staticmethod
#     def _task_flow_prompt_lines(auto: bool) -> List[str]:
#         """System-prompt section enabling the structured task-flow protocol.
#
#         Activated when the UI dropdown selects either ``task_compliance``
#         (manual proceed) or ``task_compliance_auto`` (auto proceed).
#         Parsed on the orchestrator side by
#         :mod:`common.loop.task_protocol`.
#         """
#         proceed_hint = (
#             "After every <task_status>, the orchestrator auto-proceeds to the next pending task -- no confirmation needed."
#             if auto
#             else "After every <task_status>, the orchestrator pauses for the user to click Proceed, Retry, Skip, Abort, or Replan; the next prompt arrives as a <task_action> tag -- treat the chosen action as a directive."
#         )
#
#         body = """
#     TASK FLOW PROTOCOL (ACTIVE)
#     This conversation runs in structured task-flow mode for requests needing 3+ distinct steps (e.g. implement / refactor / fix multiple / build).
#     Trivial single-step requests fall through to the normal tool protocol, with no task tags.
#
#     1) PLAN AND START IN ONE REPLY -- NON-NEGOTIABLE.
#     The very first output of the first iteration must be a complete plan inside one <tasks>...</tasks> block, IMMEDIATELY followed by <task_status> for task #1 and the first <tool> call -- all three in the SAME reply.
#     The plan must come first (nothing precedes it), but it must NOT be the only thing in the reply. A <tasks>-only reply is a stall, not a valid first iteration.
#     A reply missing the plan is rejected and re-emitted with a corrective nudge, costing a full iteration.
#     Exception: a <task_action>...</task_action> prompt means an existing plan is already running, so no re-plan is needed.
#
#     The plan format is XML child tags -- NO attributes, NO JSON, exactly like the tool-calling protocol.
#     Max 12 tasks (plan only the next 12 if more are needed, then re-plan later).
#     Each task is a <task>...</task> child of <tasks> with these child tags:
#       <id>1</id>
#       <name>short title</name>
#       <description>what to do</description>
#       <success_criteria>how you know it is done</success_criteria>
#       <depends_on>1,2</depends_on>   (optional; comma-separated or separate tags)
#
#     CORRECT:
#     <tasks>
#       <task>
#         <id>1</id>
#         <name>Locate temperature setter</name>
#         <description>Find where the slider writes the value</description>
#         <success_criteria>File and line identified</success_criteria>
#         <depends_on></depends_on>
#       </task>
#       <task>
#         <id>2</id>
#         <name>Forward to backend</name>
#         <description>...</description>
#         <success_criteria>...</success_criteria>
#         <depends_on>1</depends_on>
#       </task>
#     </tasks>
#
#     2) NEVER EMIT THE PLAN ALONE.
#     The plan must always be followed by <task_status> for task #1 and the first <tool> call in the SAME reply.
#     A <tasks>-only reply is a stall. Re-emitting the plan again does not fix it — it is a second stall that forces the orchestrator to bail to a raw recap.
#
#     CORRECT (plan + start, single reply):
#     <tasks>
#       <task>
#         <id>1</id>
#         <name>Read pubspec</name>
#         <description>...</description>
#         <depends_on></depends_on>
#       </task>
#       <task>
#         <id>2</id>
#         <name>Patch dep</name>
#         <description>...</description>
#         <depends_on>1</depends_on>
#       </task>
#     </tasks>
#     <task_status>
#       <id>1</id>
#       <status>in_progress</status>
#       <note>reading pubspec.yaml to locate the record dep</note>
#     </task_status>
#     <tool>
#       <name>read_file</name>
#       <path>pubspec.yaml</path>
#     </tool>
#
#     WRONG (plan only -- model stalls):
#     <tasks>...</tasks>
#     (no task_status, no tool -- wastes the next iteration on a corrective nudge.)
#
#     3) WORK ONE TASK AT A TIME.
#     Use the normal <tool> protocol for reads/writes -- do not jump ahead.
#
#     4) REPORT STATUS -- after finishing or failing a task, emit exactly one <task_status> tag:
#     <task_status>
#       <id>1</id>
#       <status>done</status>
#       <note>one line summary</note>
#     </task_status>
#     Every iteration that produces work output must include one; skipping it freezes the UI checklist and triggers a corrective reminder next turn.
#
#     Valid status values:
#       - pending      : not started (used only inside <tasks>)
#       - in_progress  : work started
#       - done         : completed, success_criteria met
#       - partial      : progress made, needs another iteration
#       - blocked      : needs info from the user (state what is missing)
#       - failed       : attempted, could not succeed (explain why in note)
#       - skipped      : task deemed unnecessary
#
#     5) __PROCEED_HINT__
#
#     6) RE-PLANNING -- if the plan turns out wrong mid-execution (new tasks found, bad ordering, etc.), emit a fresh <tasks>...</tasks> block with the remaining tasks renumbered; the orchestrator swaps it in for the open pending tasks.
#     Do not re-plan just because a reply missed task_status/tool -- that is already a counted stall, so emit the missing pieces for the existing plan instead.
#
#     7) FINAL ANSWER -- once every task is done (or definitively skipped/failed), reply in plain prose/markdown with no task tags.
#     Summarize what was accomplished and surface any caveats -- this is what the user reads in the chat bubble.
#
#     WRONG (no plan, jumps straight into a tool):
#     <tool>
#       <name>read_file</name>
#       <path>...</path>
#     </tool>
#
#     WRONG (raw status update outside a tag):
#     Task 1 is done.
#
#     WRONG (mixing reasoning with the tag):
#     Let me think... <task_status><id>1</id><status>done</status></task_status>
#     (reasoning belongs inside <thinking>...</thinking>; the tag must be the only top-level structured item in the reply, alongside at most one <tool> call.)
#     """
#
#         return body.replace("__PROCEED_HINT__", proceed_hint).split("\n")
#
#     @staticmethod
#     def _base_system_prompt() -> List[str]:
#         """Return immutable base system prompt (no tools)."""
#         return [_BASE_PROMPT]  # module-level constant, see below
#
#     @staticmethod
#     def _format_signature(fn: Dict[str, Any]) -> str:
#         """Format tool signature from OpenAPI spec."""
#         params = fn.get("parameters", {}) or {}
#         props = params.get("properties", {}) or {}
#         required = set(params.get("required", []) or [])
#
#         if not props:
#             return "no parameters"
#
#         parts = []
#         for key, spec in props.items():
#             type_name = spec.get("type", "any")
#             if isinstance(type_name, list):
#                 type_name = "|".join(type_name)
#             suffix = "" if key in required else "?"
#             parts.append(f"{key}{suffix}:{type_name}")
#
#         return ", ".join(parts)
