"""The Orchestrator — runs the model / tool-call / model loop for one request.

Design
------
* ``run()`` is a thin shell: prepare history -> chat-only fast path -> tool loop.
* All per-request mutable state lives in :class:`_TurnState`, created fresh on
  every ``run()``. Nothing that should reset per request lives on ``self``.
* Corrective directives ("nudges") are EPHEMERAL system prompts: each one is
  injected for exactly one model call and cleared at the top of the next
  iteration. Persistent prompts (base / plan / task_state / agent_directive)
  are keyed separately and survive.
* Early exits raise :class:`_Bail`, so no guard has to thread a return value
  back through the loop body.
"""

from __future__ import annotations

import json
import re
import sys
import time
from collections import Counter, deque
from dataclasses import dataclass, field
from typing import Any, Deque, Dict, FrozenSet, List, Optional, Sequence, Set, Tuple

from agent.backends import ModelBackend
from agent.core.policy import SecurityConfig
from agent.core.project_context import load_project_context
from agent.loop.history import ConversationHistory
from agent.loop.task_protocol import (
    TaskMode,
    TaskStatus,
    TaskStatusEvent,
    emit_task_status,
    emit_tasks_proposed,
    emit_thinking,
    log_task_action_received,
    parse_task_action,
    parse_task_status,
    parse_tasks,
    strip_task_tags,
)
from agent.loop.tool_detector import ToolIntentDetector
# NOTE: private import. Ask tool_dispatch to export this as
# ``looks_like_tool_attempt``; kept aliased so only this line changes.
from agent.loop.tool_dispatch import _looks_like_tool_attempt as looks_like_tool_attempt
from agent.loop.tool_dispatch import (
    clean_final_answer,
    clean_history_text,
    drain_recent_drops,
    extract_thinking,
    looks_like_malformed_tool_call,
    looks_like_refusal,
    looks_like_unclosed_tool,
    parse_all_tag_tool_calls,
)
from agent.prompts import (
    format_system_prompt,
    get_project_prompt_for_base_path,
    get_system_prompt_value,
)
from agent.tools.registry import ToolRegistry
from agent.utils.circuit_breaker import CircuitBreaker
from agent.utils.token_estimator import chars_for_tokens, estimate_messages_tokens

__all__ = ["Orchestrator"]

# ======================================================================
# TUNING CONSTANTS
# ======================================================================

# Floor for tool-result chars when the backend reports no context_limit.
_MAX_TOOL_RESULT_CHARS_FALLBACK = 12_000
_MIN_TOOL_RESULT_CHARS = 12_000

_MAX_TRUNCATION_RETRY = 10
# After this many consecutive truncations the generic "your call was cut off"
# nudge has demonstrably failed; switch to the split-the-batch directive.
_MAX_TRUNCATION_BEFORE_SPLIT_NUDGE = 3

_MAX_MALFORMED_RETRIES = 2
_MAX_CONSECUTIVE_MALFORMED = 5
_MAX_REFUSAL_RETRIES = 2
_MAX_CLIFFHANGER_RETRIES = 2
_MAX_STEP_REPORT_RETRIES = 1

_MAX_REPEAT_WARNINGS = 3
_RECENT_CALL_WINDOW = 8

# Idempotent validators: N clean runs in a row means the model is stalling.
_IDEMPOTENT_VALIDATORS: FrozenSet[str] = frozenset(
    {
        "python_check",
        "python_lint",
        "python_test",
        "flutter_analyze",
        "flutter_test",
        "git_status",
        "git_diff",
        "git_log",
    }
)
_MAX_CONSECUTIVE_VALIDATIONS = 3

# Code-correctness validators (subset of the above). A FAILED run downgrades
# the orchestrator-decided terminal task status from done -> partial. The
# read-only git_* tools are excluded: a dirty git_status is not a code failure.
_CODE_VALIDATORS: FrozenSet[str] = frozenset(
    {"python_check", "python_lint", "python_test", "flutter_analyze", "flutter_test"}
)

_WRITE_TOOLS: FrozenSet[str] = frozenset({"write_file", "patch_file", "append_file"})
_READ_TOOLS: FrozenSet[str] = frozenset({"read_file", "read_files"})

# Degenerate-text-loop detection.
_REP_MIN_PHRASE_LEN = 25
_REP_THRESHOLD = 5

# Task-flow nudge thresholds.
_MAX_ITERS_WITHOUT_STATUS = 3
_MAX_ITERS_WITH_EMPTY_REPLY = 2
_MAX_PLAN_THEN_START_NUDGES = 3
_MAX_PLAN_FIRST_NUDGES = 1

# Read-only-loop pressure, expressed as a fraction of the CURRENT iteration
# budget so the thresholds scale with max_iterations instead of being pinned
# to the old hard-coded 10 / 20 / 28.
_PRESSURE_NUDGE_FRAC = 0.10
_PRESSURE_WARN_FRAC = 0.20
_PRESSURE_BAIL_FRAC = 0.28
_PRESSURE_MIN_SUCCESSES = 4
_EXTENSION_SUPPRESS_SUCCESSES = 6

# Stop sequences for the tool loop.
#
# ``<tool>`` is deliberately NOT here. A compliant reply STARTS with ``<tool>``,
# so using it as a stop string truncates every valid tool call to an empty
# string -- which is what produced the "empty reply" epidemic the guards below
# were written to paper over. ``</tool>`` still prevents the model from
# hallucinating a fake transcript after the real call; the missing closing tag
# is repaired by the caller.
_TOOL_STOP_SEQUENCES: Tuple[str, ...] = (
    "<tool",
    "</tool>",
    "\nUser:",
    "\nAssistant:",
    "\n[INTERNAL:",
)

# During synthesis we genuinely want to forbid tool calls, so ``<tool>`` is a
# legitimate stop string here.
_SYNTH_STOP_SEQUENCES: Tuple[str, ...] = _TOOL_STOP_SEQUENCES

_TRUNCATION_MARKERS: Tuple[str, ...] = (
    "[... more lines",
    "[OUTPUT TRUNCATED",
    "[TRUNCATED:",
    "[... chars truncated from middle",
)

_THINKING_MODEL_PATTERNS: Tuple[str, ...] = (
    "kimi",
    "k2.7",
    "deepseek-r1",
    "deepseek-v3.1",
    "qwen3",
    "qwq",
    "gpt-oss",
    "reasoning",
)
_MIN_THINKING_MAX_TOKENS = 4096

# ======================================================================
# TEXT HEURISTICS
# ======================================================================

# Bare confirmations meaning "execute the prior plan", not "explore freely".
# Mirrors workflow.py's _FOLLOWUP_RE.
_FOLLOWUP_RE = re.compile(
    r"^\s*(?:"
    r"ok(?:ay)?(?:\s+(?:proceed|go|do\s+it|continue|good))?"
    r"|yes(?:\s+(?:proceed|go|do\s+it|continue|please))?"
    r"|sure(?:\s+(?:do\s+it|go|proceed))?"
    r"|proceed|continue|go\s+ahead|do\s+it|fix\s+it|please\s+continue"
    r")[\s!.?]*$",
    re.IGNORECASE,
)

# Pure praise with no embedded instruction.
_AFFIRMATION_RE = re.compile(
    r"^\s*(?:great\s+work|well\s+done|perfect|excellent|awesome|fantastic"
    r"|amazing|outstanding|brilliant|superb|incredible|wonderful|terrific"
    r"|fabulous|marvelous|impressive|remarkable|extraordinary|phenomenal"
    r"|exceptional)[\s!.?]*$",
    re.IGNORECASE,
)

# Word-boundary matched: the old substring test flagged "good" as "go" and
# "algorithm" as "go", misclassifying praise as a continuation request.
_ACTION_WORD_RE = re.compile(
    r"\b(?:proceed|continue|go|next|step|follow|execute|run|implement|do\s+it)\b",
    re.IGNORECASE,
)

_ACTION_VERB_RE = re.compile(
    r"\b(implement|fix|write|create|edit|update|modify|refactor|add|delete|"
    r"remove|rename|build|generate|patch|change|apply|install|setup|"
    r"configure|migrate|port|replace)\b",
    re.IGNORECASE,
)

_PATHY_TOKENS: Tuple[str, ...] = (".dart", ".py", "lib/", "bin/", "git ")

_FILE_MENTION_RE = re.compile(r"\b[a-zA-Z_][\w/.-]*\.(?:dart|py|yaml|json|md)\b")


def _is_short_followup(text: str) -> bool:
    """True when *text* is a bare confirmation of a previously stated plan."""
    if not text or not text.strip():
        return False
    stripped = text.strip()

    # Pure praise with no action word: treat as a follow-up so the loop
    # finalizes instead of re-exploring.
    if _AFFIRMATION_RE.match(stripped) and not _ACTION_WORD_RE.search(stripped):
        return True
    if _FOLLOWUP_RE.match(stripped):
        return True
    lowered = stripped.lower()
    return len(stripped) <= 25 and not any(tok in lowered for tok in _PATHY_TOKENS)


def _has_repetitive_output(text: str) -> bool:
    """True when one long sentence repeats enough times to signal a stuck model."""
    if not text or len(text) < _REP_MIN_PHRASE_LEN * _REP_THRESHOLD:
        return False
    sentences = re.split(r"(?<=[.!?])\s*", text)
    long_sentences = [s.strip() for s in sentences if len(s.strip()) >= _REP_MIN_PHRASE_LEN]
    if len(long_sentences) < _REP_THRESHOLD:
        return False
    most_common = Counter(long_sentences).most_common(1)
    return bool(most_common and most_common[0][1] >= _REP_THRESHOLD)


def _canonicalize_tool_key(name: str, params: Dict[str, Any]) -> str:
    """Canonical ``name::params`` key for the repeat-call detector.

    ``run_command`` gets extra normalization so cosmetic re-runs (``2>&1``,
    ``| head -N``, a ``cd x &&`` prefix) collapse onto one key -- without
    collapsing two semantically different commands.
    """
    if name == "run_command" and isinstance(params.get("command"), str):
        cmd = params["command"].strip()
        cmd = re.sub(r"\s*2>&1\s*", " ", cmd)
        cmd = re.sub(r"\s*>\s*/dev/null\s*", " ", cmd)
        cmd = re.sub(r"\s*\|\s*(?:head|tail)\s+-?\d+\s*$", "", cmd)
        cmd = re.sub(r"^cd\s+\S+\s*&&\s*", "", cmd)
        cmd = re.sub(r"\s+", " ", cmd).strip()
        params = {**params, "command": cmd}
    try:
        blob = json.dumps(params, sort_keys=True, ensure_ascii=False, default=str)
    except (TypeError, ValueError):
        blob = repr(sorted(params.items()))
    return f"{name}::{blob}"


def _result_is_success(result: str) -> bool:
    """Cheap status probe that tolerates both JSON spacing conventions."""
    return '"status": "success"' in result or '"status":"success"' in result


# ======================================================================
# PROMPT DIRECTIVES
# ----------------------------------------------------------------------
# Prompt defaults and XML-backed overrides live in agent.prompts. Helpers
# here only fill dynamic values into the selected prompt template.
# ======================================================================


def _directive_agent(task_flow: bool) -> str:
    """Agent directive, reconciled with task-flow mode."""
    base = get_system_prompt_value("AGENT_DIRECTIVE")
    if task_flow:
        return base + get_system_prompt_value("TASK_FLOW_TOOL_CLAUSE")
    return base


def _directive_malformed(error: str) -> str:
    """Corrective feedback for a malformed (or truncated) tool call."""
    return format_system_prompt("MALFORMED_DIRECTIVE_TEMPLATE", error=error)


def _directive_schema_feedback(drop_lines: Sequence[str]) -> str:
    """Surface sanitizer key drops so the model does not silently re-emit."""
    return format_system_prompt(
        "SCHEMA_FEEDBACK_DIRECTIVE_TEMPLATE",
        drop_lines="\n".join(drop_lines),
    )


def _directive_repeat_call(summary: str) -> str:
    return format_system_prompt("REPEAT_CALL_DIRECTIVE_TEMPLATE", summary=summary)


def _directive_validation_complete(count: int) -> str:
    return format_system_prompt("VALIDATION_COMPLETE_DIRECTIVE_TEMPLATE", count=count)


def _directive_truncated_answer(tail: str) -> str:
    return format_system_prompt("TRUNCATED_ANSWER_DIRECTIVE_TEMPLATE", tail=tail)


def _tool_result_followup(name: str, display_result: str, is_last_chance: bool) -> str:
    """Standard follow-up after a tool execution.

    Appends an explicit warning when the result carries truncation markers, so
    the model re-reads before patching instead of building an old_content that
    cannot match.
    """
    if is_last_chance:
        tail = get_system_prompt_value("TOOL_RESULT_FINAL_TAIL")
    else:
        tail = get_system_prompt_value("TOOL_RESULT_CONTINUE_TAIL")

    warning = ""
    if any(marker in display_result for marker in _TRUNCATION_MARKERS):
        warning = get_system_prompt_value("TOOL_RESULT_TRUNCATION_WARNING")

    return format_system_prompt(
        "TOOL_RESULT_FOLLOWUP_TEMPLATE",
        name=name,
        display_result=display_result,
        warning=warning,
        tail_directive=tail,
    )


# ======================================================================
# PER-REQUEST STATE
# ======================================================================


class _Bail(Exception):
    """Internal control flow: abandon the loop and return ``answer``."""

    def __init__(self, answer: str) -> None:
        super().__init__(answer)
        self.answer = answer


@dataclass
class _TurnState:
    """Everything that must reset on every ``run()``.

    Previously these were a mix of locals and instance fields; the instance
    fields (``_iters_without_status``, ``_iters_with_empty_reply``,
    ``_plan_emitted_this_request``, ...) were never reset between requests, so
    request N+1 inherited request N's nudge counters.
    """

    action_intent: bool = False
    is_task_action: bool = False
    plan_emitted: bool = False

    writes: int = 0
    pending_step_report: bool = False
    successful_tools: int = 0

    refusal_retries: int = 0
    empty_retries: int = 0
    truncation_retries: int = 0
    cliffhanger_retries: int = 0
    step_report_retries: int = 0
    malformed_retries: int = 0
    consecutive_malformed: int = 0
    repeat_warnings: int = 0
    consecutive_validations: int = 0

    iters_without_status: int = 0
    iters_with_empty_reply: int = 0
    plan_then_start_nudges: int = 0
    plan_first_nudges: int = 0
    action_pressure_tier: int = 0

    wrote_since_validator: bool = False
    failed_writes_since_read: bool = False

    turn_had_failed_validator: bool = False
    iter_had_failed_validator: bool = False

    recent_calls: Deque[str] = field(
        default_factory=lambda: deque(maxlen=_RECENT_CALL_WINDOW)
    )
    recent_outcomes: Deque[bool] = field(default_factory=lambda: deque(maxlen=12))
    recent_files: Set[str] = field(default_factory=set)


# ======================================================================
# ORCHESTRATOR
# ======================================================================


class Orchestrator:
    """Drives one user request to a final answer through the tool loop."""

    # System-prompt keys that are corrective one-shots. Cleared at the top of
    # every iteration so a stale "FINAL ANSWER REQUIRED" from iteration 12 does
    # not still be in the prompt at iteration 40, contradicting everything else.
    _EPHEMERAL_KEYS: FrozenSet[str] = frozenset(
        {
            "malformed",
            "truncated",
            "truncation_split",
            "refusal",
            "empty_reply",
            "cliffhanger",
            "step_report",
            "repeat_warning",
            "schema_feedback",
            "validation_done",
            "status_nudge",
            "plan_first",
            "plan_then_start",
        }
    )

    _RETRY_BACKOFFS: Tuple[int, ...] = (1, 2, 4, 8, 16)

    _RETRYABLE_HINTS: Tuple[str, ...] = (
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

    def __init__(
            self,
            backend: ModelBackend,
            base_path: str = ".",
            temperature: float = 0.2,
            max_tokens: int = 2048,
            security_config: Optional[SecurityConfig] = None,
            disable_tools: bool = False,
            path_filter: Optional[Any] = None,
            db_connections: Optional[Dict[str, Dict[str, str]]] = None,
            task_mode: str = "task_compliance_auto",
            thinking: bool = False,
            effort: Optional[str] = None,
            auto_num_ctx: bool = False,
            max_iterations: int = 100,
            max_iteration_cap: int = 150,
    ) -> None:
        self.backend = backend
        self.model_id = getattr(backend, "model_id", "(unknown)")
        self.task_mode = TaskMode.parse(task_mode)
        self.disable_tools = disable_tools

        self.tool_registry = ToolRegistry(
            base_path=base_path,
            security_config=security_config,
            path_filter=path_filter,
            db_connections=db_connections,
        )
        self.conversation_history = ConversationHistory()

        self._model_circuit_breaker = CircuitBreaker(
            name=f"model:{self.model_id}", failure_threshold=5, recovery_timeout=60.0
        )

        # --- generation knobs ---------------------------------------------
        self.temperature = temperature
        self.max_tokens = self._floor_thinking_budget(max_tokens, thinking)
        self.thinking = thinking
        self.effort = effort

        # --- context auto-calibration -------------------------------------
        self.auto_num_ctx = auto_num_ctx
        self._auto_num_ctx_calibrated = False
        self._max_prompt_eval_seen = 0

        # --- iteration budget ---------------------------------------------
        self.max_iterations = max(1, max_iterations)
        self._initial_max_iterations = self.max_iterations
        self._max_iteration_cap = max(self.max_iterations, max_iteration_cap)

        # --- cumulative session telemetry ---------------------------------
        self._successful_tool_count = 0
        self._files_modified: Set[str] = set()

        # --- per-request state --------------------------------------------
        self._turn = _TurnState()
        self._active_nudges: Set[str] = set()
        self._project_context: Optional[str] = None
        self._project_context_loaded = False

        self._configure_context_budgets()

    # ------------------------------------------------------------------
    # Construction helpers
    # ------------------------------------------------------------------

    def _floor_thinking_budget(self, max_tokens: int, thinking: bool) -> int:
        """Raise a dangerously low max_tokens for thinking-capable models.

        Chain-of-thought can consume the whole budget, leaving zero visible
        output. Only bump below the floor — a deliberate UI setting above it
        is respected.
        """
        if not thinking or max_tokens >= _MIN_THINKING_MAX_TOKENS:
            return max_tokens
        model_lower = (self.model_id or "").lower()
        if not any(pattern in model_lower for pattern in _THINKING_MODEL_PATTERNS):
            return max_tokens
        self._log(
            f"Thinking-capable model '{self.model_id}' with max_tokens="
            f"{max_tokens} — raising to {_MIN_THINKING_MAX_TOKENS} so reasoning "
            f"does not consume the entire output budget."
        )
        return _MIN_THINKING_MAX_TOKENS

    def _configure_context_budgets(self) -> None:
        """Derive history / tool-result caps from the backend's context window.

        Falls back to tight defaults when the backend reports no limit, so a
        128K cloud model is not throttled by constants sized for 8K Ollama.
        """
        ctx_tokens = int(getattr(self.backend, "context_limit", 0) or 0)
        if ctx_tokens > 0:
            ctx_chars = chars_for_tokens(ctx_tokens, "code")
            # ~2K tokens per user+assistant pair after tool round-trips collapse.
            self.max_history_turns = max(30, ctx_tokens // 2_000)
            # One tool result may occupy ~1/3 of the window: enough for a large
            # source file without head+tail truncation.
            self._max_tool_result_chars = max(40_000, ctx_chars // 3)
            self._history_char_budget = int(ctx_chars * 0.85)
            self._history_token_budget = int(ctx_tokens * 0.85)
        else:
            self.max_history_turns = 6
            self._max_tool_result_chars = _MAX_TOOL_RESULT_CHARS_FALLBACK
            self._history_char_budget = 500_000
            self._history_token_budget = 250_000
        # Init-time ceiling: dynamic recomputation may shrink but never grow
        # past this.
        self._init_max_tool_result_chars = self._max_tool_result_chars

    # ------------------------------------------------------------------
    # Logging
    # ------------------------------------------------------------------

    @staticmethod
    def _log(message: str) -> None:
        """Single stderr channel, so the UI log panel keeps working.

        Swap this body for ``logging`` if you want structured logs; every call
        site goes through here.
        """
        print(f"[orch] {message}", file=sys.stderr, flush=True)

    # ------------------------------------------------------------------
    # Session management
    # ------------------------------------------------------------------

    def reset(self) -> None:
        self.conversation_history.reset_all()
        self._turn = _TurnState()
        self._active_nudges.clear()
        self._successful_tool_count = 0
        self._files_modified.clear()
        self.max_iterations = self._initial_max_iterations

    def import_history(self, history: List[Dict[str, Any]]) -> None:
        self._ensure_system_prompt()
        self.conversation_history.import_external_history(history)

    def _ensure_system_prompt(self) -> None:
        """Install the base system prompt, loading project context once."""
        if not self._project_context_loaded:
            try:
                self._project_context = load_project_context(
                    str(self.tool_registry.base_path)
                )
            except Exception as exc:  # noqa: BLE001 - context is optional
                self._log(f"Could not load project context: {exc}")
                self._project_context = None
            self._project_context_loaded = True

        try:
            project_config_prompt = get_project_prompt_for_base_path(
                self.tool_registry.base_path
            )
        except Exception as exc:  # noqa: BLE001 - prompt config is optional
            self._log(f"Could not load project prompt config: {exc}")
            project_config_prompt = None

        if project_config_prompt and project_config_prompt.strip():
            self.conversation_history.set_system_prompt(
                "project_config",
                project_config_prompt.strip(),
            )
        else:
            self.conversation_history.remove_system_prompt("project_config")

        self.conversation_history.set_system_prompt(
            "base",
            self.tool_registry.get_system_prompt(
                project_context=self._project_context,
                task_mode=self.task_mode.value,
            ),
        )

    # ------------------------------------------------------------------
    # Ephemeral nudges
    # ------------------------------------------------------------------

    def _nudge(self, key: str, content: str) -> None:
        """Install a one-shot corrective directive for the next model call."""
        self.conversation_history.set_system_prompt(key, content)
        if key in self._EPHEMERAL_KEYS:
            self._active_nudges.add(key)

    def _clear_nudges(self) -> None:
        """Drop every one-shot directive from the previous iteration."""
        for key in tuple(self._active_nudges):
            self.conversation_history.remove_system_prompt(key)
        self._active_nudges.clear()

    def _set_persistent(self, key: str, content: Optional[str]) -> None:
        """Install or remove a directive that must survive across iterations."""
        if content:
            self.conversation_history.set_system_prompt(key, content)
        else:
            self.conversation_history.remove_system_prompt(key)

    # ------------------------------------------------------------------
    # Task-state shims — delegate to ConversationHistory.task_tracker
    # ------------------------------------------------------------------
    # The canonical state lives in the tracker; these properties keep older
    # call sites working. Prefer the tracker's own API in new code.

    @property
    def _tracker(self) -> Any:
        return self.conversation_history.task_tracker

    @property
    def _planned_task_ids(self) -> List[int]:
        return self._tracker.task_ids

    @_planned_task_ids.setter
    def _planned_task_ids(self, value: Optional[List[int]]) -> None:
        if not value:
            self._tracker.clear_plan()
        else:
            self._tracker._task_ids = list(value)

    @property
    def _planned_tasks(self) -> Dict[int, Any]:
        return self._tracker._tasks

    @_planned_tasks.setter
    def _planned_tasks(self, value: Optional[Dict[int, Any]]) -> None:
        tracker = self._tracker
        tracker._tasks = dict(value or {})
        if value:
            tracker._task_ids = list(value.keys())
            for tid, task in value.items():
                status = getattr(task, "status", None)
                if status is not None:
                    tracker._statuses[tid] = status

    @property
    def _active_task_id(self) -> Optional[int]:
        return self._tracker.active_task_id

    @_active_task_id.setter
    def _active_task_id(self, value: Optional[int]) -> None:
        self._tracker._active_task_id = value

    @property
    def _inprogress_task_ids(self) -> Set[int]:
        return self._tracker.inprogress_ids

    @_inprogress_task_ids.setter
    def _inprogress_task_ids(self, value: Optional[Set[int]]) -> None:
        self._tracker._inprogress_ids = set(value) if value else set()

    # ------------------------------------------------------------------
    # Plan mirroring
    # ------------------------------------------------------------------

    def _remove_plan_system_prompt(self) -> None:
        self.conversation_history.remove_system_prompt("plan")
        self.conversation_history.remove_system_prompt("task_state")

    def _update_plan_system_prompt(self) -> None:
        """Mirror the active plan into a keyed system message.

        Without this the model sees the base prompt's "PLAN FIRST" rule, does
        not realize a plan already exists, and re-emits ``<tasks>`` every
        iteration — the single most common task-flow failure.
        """
        if not self.task_mode.is_task_flow:
            return

        parts: List[str] = [
            get_system_prompt_value("PLAN_SYSTEM_MARKER"),
            get_system_prompt_value("PLAN_SYSTEM_OVERRIDE"),
        ]

        planned_ids = self._planned_task_ids
        if planned_ids:
            tasks = self._planned_tasks
            in_progress = self._inprogress_task_ids
            active = self._active_task_id
            parts.extend(("", get_system_prompt_value("PLAN_ACTIVE_HEADER")))
            for tid in planned_ids:
                task = tasks.get(tid)
                name = getattr(task, "name", None) or f"Task {tid}"
                description = getattr(task, "description", "") or ""
                if tid in in_progress:
                    marker = "▶ IN_PROGRESS"
                elif tid == active:
                    marker = "▶ ACTIVE"
                else:
                    marker = "○ pending"
                line = f"  #{tid} {marker} — {name}"
                if description:
                    short = description[:120]
                    if len(description) > 120:
                        short += "..."
                    line += f"\n       {short}"
                parts.append(line)
            parts.append(get_system_prompt_value("PLAN_END_MARKER"))

        active = self._active_task_id
        if active is not None:
            task = self._planned_tasks.get(active)
            name = getattr(task, "name", None) or f"Task #{active}"
            parts.extend(
                (
                    "",
                    format_system_prompt(
                        "PLAN_CURRENT_TASK_TEMPLATE",
                        active=active,
                        name=name,
                    ),
                )
            )
        elif planned_ids:
            parts.extend(
                (
                    "",
                    get_system_prompt_value("PLAN_NO_ACTIVE_TASK"),
                )
            )

        self.conversation_history.set_system_prompt("plan", "\n".join(parts))
        self.conversation_history.sync_task_state()

    # ------------------------------------------------------------------
    # Budget management
    # ------------------------------------------------------------------

    def _current_tokens(self) -> int:
        return estimate_messages_tokens(
            self.conversation_history.to_messages(),
            content_type="code",
            per_message_overhead=10,
        )

    def _per_message_token_cap(self) -> int:
        ctx_tokens = int(getattr(self.backend, "context_limit", 0) or 0)
        if ctx_tokens > 0:
            # ~20% of the window: room for a full source file, but no single
            # turn can dominate.
            return max(2_500, ctx_tokens // 5)
        return getattr(
            ConversationHistory, "MAX_MSG_TOKENS", max(2_500, self._history_token_budget // 10)
        )

    def _trim_history(self) -> None:
        """Token-aware trim of the turns only; keyed system prompts survive."""
        self.conversation_history.trim_turns_to_budget(
            self._history_token_budget,
            content_type="code",
            max_msg_tokens=self._per_message_token_cap(),
        )

    def _enforce_budget_and_recompute(self) -> None:
        """Trim if over budget, then size the tool-result cap from what is free.

        Both steps share one token estimate — the previous code estimated the
        whole history twice per iteration, which is the most expensive thing in
        the loop on a large session.
        """
        used = self._current_tokens()
        if used > self._history_token_budget:
            self._trim_history()
            used = self._current_tokens()
            self._log(
                f"History over token budget; trimmed to ~{used} tokens "
                f"(budget {self._history_token_budget})."
            )

        if int(getattr(self.backend, "context_limit", 0) or 0) <= 0:
            return

        free_tokens = max(0, self._history_token_budget - used)
        # Reserve 15% of free space for the reply plus safety margin.
        alloc_chars = chars_for_tokens(int(free_tokens * 0.85), "code")
        self._max_tool_result_chars = max(
            _MIN_TOOL_RESULT_CHARS,
            min(self._init_max_tool_result_chars, alloc_chars),
        )

    def _calibrate_context_budget(self) -> None:
        """Clamp the history budget to the backend's real prompt capacity.

        The first call is always the smallest (system prompt + request), so we
        track the maximum ``prompt_eval_count`` seen and converge upward. The
        target never exceeds the context-derived budget: for models whose real
        window is under ~28K, letting the floor win would over-fill the prompt
        and make the server silently truncate the system prompt.
        """
        if not self.auto_num_ctx:
            return
        real_eval = int(getattr(self.backend, "last_prompt_eval_count", 0) or 0)
        if real_eval <= 0:
            return

        previous_max = self._max_prompt_eval_seen
        self._max_prompt_eval_seen = max(previous_max, real_eval)

        grew_significantly = (
                previous_max > 0 and self._max_prompt_eval_seen >= int(previous_max * 1.5)
        )
        if self._auto_num_ctx_calibrated and not grew_significantly:
            return

        basis = self._max_prompt_eval_seen
        floor = 24_000  # below this, multi-turn coding context does not fit
        target = min(self._history_token_budget, max(floor, int(basis * 0.85)))

        if target != self._history_token_budget:
            old_budget = self._history_token_budget
            self._history_token_budget = target
            ratio = (target / old_budget) if old_budget > 0 else 1.0
            self._history_char_budget = max(72_000, int(self._history_char_budget * ratio))
            self._max_tool_result_chars = max(
                _MIN_TOOL_RESULT_CHARS, int(self._max_tool_result_chars * ratio)
            )
            direction = "down" if target < old_budget else "up"
            self._log(
                f"Auto-calibrated context budget {direction} from "
                f"max_prompt_eval={basis}: tokens {old_budget} -> {target}, "
                f"chars -> {self._history_char_budget}, tool_result_chars -> "
                f"{self._max_tool_result_chars}"
            )
        self._auto_num_ctx_calibrated = True

    # ------------------------------------------------------------------
    # Tool-intent heuristic
    # ------------------------------------------------------------------

    def _should_escalate_chat_to_tools(self, user_input: str, model_reply: str) -> bool:
        """True when a chat-mode response should be retried with tools enabled."""
        if ToolIntentDetector.needs_tools(user_input):
            return True
        if parse_all_tag_tool_calls(model_reply, self.tool_registry.definitions):
            return True
        # Protocol tags in chat mode: the model wants the task protocol, but
        # chat mode does not advertise it, so the tags get stripped to nothing.
        if parse_tasks(model_reply) or parse_task_status(model_reply):
            return True
        if looks_like_malformed_tool_call(model_reply)[0]:
            return True
        return bool(looks_like_refusal(model_reply))

    # ------------------------------------------------------------------
    # Entry point
    # ------------------------------------------------------------------

    def run(self, user_input: str) -> str:
        """Drive one request to a final answer. Never raises."""
        user_input = user_input or ""
        self._ensure_system_prompt()
        self._trim_history()

        self._turn = _TurnState()
        self._clear_nudges()
        self._remove_plan_system_prompt()

        is_continuation = self._detect_task_action(user_input)
        if not is_continuation:
            self._planned_task_ids = []
            self._planned_tasks = {}
        self._active_task_id = None
        self._inprogress_task_ids = set()

        has_prior_assistant = any(
            msg.get("role") == "assistant" for msg in self.conversation_history.turns
        )
        is_followup = has_prior_assistant and _is_short_followup(user_input)
        self._turn.action_intent = bool(
            is_followup or _ACTION_VERB_RE.search(user_input)
        )

        use_tools = (not self.disable_tools) and (
                is_followup or ToolIntentDetector.needs_tools(user_input)
        )

        # Directives are keyed system prompts, never prepended to user turns.
        self._set_persistent(
            "agent_directive",
            _directive_agent(self.task_mode.is_task_flow) if use_tools else None,
        )
        self._set_persistent(
            "followup",
            get_system_prompt_value("FOLLOWUP_DIRECTIVE")
            if (is_followup and use_tools)
            else None,
        )
        self._set_persistent("action_nudge", None)

        self.conversation_history.add_user(user_input)
        self._log(
            f"Request ({'tool-enabled' if use_tools else 'chat'}): "
            f"{user_input[:120]!r}"
        )

        try:
            if not use_tools:
                answer = self._run_chat_only(user_input)
                if answer is not None:
                    return answer
                # Escalated: fall through to the tool loop with tools enabled.
            return self._run_tool_loop()
        except _Bail as bail:
            return bail.answer
        except Exception as exc:  # noqa: BLE001 - the UI must always get a string
            self._log(f"Unhandled orchestrator error: {type(exc).__name__}: {exc}")
            return (
                "The agent hit an internal error and stopped: "
                f"{type(exc).__name__}: {exc}"
            )

    def _detect_task_action(self, user_input: str) -> bool:
        """True when the prompt is a ``<task_action>`` envelope (a continuation)."""
        if not self.task_mode.is_task_flow:
            return False
        event = parse_task_action(user_input)
        if event is None:
            return False
        log_task_action_received(event)
        self._turn.is_task_action = True
        return True

    # ------------------------------------------------------------------
    # Chat-only fast path
    # ------------------------------------------------------------------

    def _run_chat_only(self, user_input: str) -> Optional[str]:
        """One direct model call. Returns ``None`` to escalate to the tool loop."""
        try:
            text, _ = self.backend.chat(
                conversation=self.conversation_history,
                max_tokens=self.max_tokens,
                temperature=self.temperature,
                tools=None,
                thinking=self.thinking,
                effort=self.effort,
                on_thinking=emit_thinking,
            )
        except Exception as exc:  # noqa: BLE001
            # Pop the user turn so a retry does not produce two consecutive
            # user messages, and the error string never enters model context.
            last = self.conversation_history.last_turn()
            if last and last.get("role") == "user":
                self.conversation_history.pop_turn()
            return f"Model error: {exc}"

        # Surface chain-of-thought from the chat-only path as well, so the
        # UI can show the model's reasoning even for plain Q/A replies.
        _visible, thinking = extract_thinking(text or "")
        if thinking:
            emit_thinking(thinking)

        text_clean = clean_history_text(text or "")

        if self._should_escalate_chat_to_tools(user_input, text_clean):
            self._log("Chat reply looked tool-related; retrying in tool mode.")
            self._set_persistent(
                "agent_directive", _directive_agent(self.task_mode.is_task_flow)
            )
            return None

        if self._looks_like_cliffhanger(text_clean):
            self._log("Chat reply is a cliffhanger; retrying in tool mode.")
            self._set_persistent(
                "agent_directive", _directive_agent(self.task_mode.is_task_flow)
            )
            return None

        self.conversation_history.add_assistant(text_clean)
        final = clean_final_answer(text or "")
        if final.strip():
            return final

        self._log("Chat reply empty after cleaning (protocol/thinking tags only).")
        return self._build_recap_answer(
            reason="chat-mode reply was empty after stripping protocol tags"
        )

    # ------------------------------------------------------------------
    # Main tool loop
    # ------------------------------------------------------------------

    def _run_tool_loop(self) -> str:
        state = self._turn
        iteration = 0

        while iteration < self.max_iterations:
            self._log(f"--- iteration {iteration}/{self.max_iterations} ---")
            state.iter_had_failed_validator = False
            # Every corrective directive lives exactly one model call.
            self._clear_nudges()

            self._apply_action_pressure(state, iteration)
            self._maybe_extend_iterations(state, iteration)
            self._enforce_budget_and_recompute()

            try:
                text, finish_reason = self._call_model()
            except Exception as exc:  # noqa: BLE001
                self._log(f"Model call failed permanently: {exc}")
                return f"Model error: {exc}"

            self._calibrate_context_budget()

            # [stop-sequence-fix] ``</tool>`` is a stop sequence, and some
            # providers strip it, leaving an unclosed tag the parser would
            # reject. Repair it before anything else looks at the text.
            if text and looks_like_unclosed_tool(text):
                text = text + "</tool>"

            saw_status, text = self._process_task_protocol(state, text, iteration)
            if text is None:  # plan-first nudge injected; retry
                iteration += 1
                continue

            self._log(
                f"reply (finish={finish_reason}, len={len(text or '')}): "
                f"{(text or '')[:400].replace(chr(10), ' ')!r}"
            )

            # Surface the model's chain-of-thought to the UI as a structured
            # ``thinking`` event so the chat view can show it live. The
            # reasoning is still stripped from the visible answer below.
            _visible, thinking = extract_thinking(text or "")
            if thinking:
                emit_thinking(thinking)

            text_clean = clean_history_text(text or "")
            self.conversation_history.add_assistant(text_clean)

            tool_calls = parse_all_tag_tool_calls(
                text_clean, self.tool_registry.definitions
            )

            if self._guard_repetitive_output(text_clean, tool_calls, iteration):
                iteration += 1
                continue

            sanitized_tools = self._surface_sanitizer_drops()

            if tool_calls:
                self._dispatch_tool_calls(
                    state, tool_calls, sanitized_tools, saw_status, iteration
                )
                iteration += 1
                continue

            if not text_clean.strip():
                self._handle_empty_reply(state, text, iteration)
                iteration += 1
                continue

            if self._handle_malformed(state, text_clean, finish_reason, iteration):
                iteration += 1
                continue

            if self._handle_truncation(state, text_clean, finish_reason):
                iteration += 1
                continue

            if state.refusal_retries < _MAX_REFUSAL_RETRIES and looks_like_refusal(
                    text_clean
            ):
                state.refusal_retries += 1
                self._log(f"Refusal detected (retry {state.refusal_retries}).")
                self._nudge("refusal", get_system_prompt_value("REFUSAL_DIRECTIVE"))
                iteration += 1
                continue

            if state.cliffhanger_retries < _MAX_CLIFFHANGER_RETRIES and (
                    self._looks_like_cliffhanger(text_clean)
            ):
                state.cliffhanger_retries += 1
                self._log(f"Cliffhanger reply (retry {state.cliffhanger_retries}).")
                self._nudge("cliffhanger", get_system_prompt_value("CLIFFHANGER_DIRECTIVE"))
                iteration += 1
                continue

            # One best-effort step-report nudge. Task status is
            # orchestrator-decided and the final answer is always synthesized,
            # so more than one round-trip here is not worth the latency.
            if (
                    state.pending_step_report
                    and state.step_report_retries < _MAX_STEP_REPORT_RETRIES
                    and not self._looks_like_step_report(text_clean)
            ):
                state.step_report_retries += 1
                self._log("Missing step report after a write; single nudge.")
                self._nudge("step_report", get_system_prompt_value("STEP_REPORT_DIRECTIVE"))
                iteration += 1
                continue
            state.pending_step_report = False

            # clean_final_answer strips more than clean_history_text, so a
            # reply that passed the empty guard can still collapse here.
            final_answer = clean_final_answer(text or "")
            if final_answer.strip():
                self._emit_terminal_task_status()
                return final_answer

            self._log("Final answer empty after cleaning; falling back to recap.")
            return self._build_recap_answer(reason="final answer empty after cleaning")

        self._log("Max iterations reached.")
        self._dump_session()
        return self._build_recap_answer(
            reason=f"max iterations ({self.max_iterations}) reached without a "
                   "synthesized answer"
        )

    # ------------------------------------------------------------------
    # Loop guards
    # ------------------------------------------------------------------

    def _apply_action_pressure(self, state: _TurnState, iteration: int) -> None:
        """Escalate pressure when an action request produces only reads.

        Re-evaluated every iteration and self-clearing, so the directive
        disappears the moment the model finally writes something.
        """
        in_read_only_loop = (
                state.action_intent
                and state.writes == 0
                and state.successful_tools >= _PRESSURE_MIN_SUCCESSES
        )
        if not in_read_only_loop:
            if state.action_pressure_tier:
                self._set_persistent("action_nudge", None)
                state.action_pressure_tier = 0
            return

        bail_at = max(8, int(self.max_iterations * _PRESSURE_BAIL_FRAC))
        warn_at = max(6, int(self.max_iterations * _PRESSURE_WARN_FRAC))
        nudge_at = max(4, int(self.max_iterations * _PRESSURE_NUDGE_FRAC))

        if iteration >= bail_at:
            self._log(
                f"Action request with zero writes after {iteration} iterations; "
                f"bailing to recap."
            )
            raise _Bail(
                self._build_recap_answer(
                    reason=f"action task stalled at iteration {iteration} with zero "
                           f"writes despite {state.successful_tools} successful reads"
                )
            )

        if iteration >= warn_at and state.action_pressure_tier < 2:
            state.action_pressure_tier = 2
            self._set_persistent(
                "action_nudge",
                get_system_prompt_value("ACTION_FINAL_WARNING_DIRECTIVE"),
            )
        elif iteration >= nudge_at and state.action_pressure_tier < 1:
            state.action_pressure_tier = 1
            self._set_persistent(
                "action_nudge",
                get_system_prompt_value("ACTION_NUDGE_DIRECTIVE"),
            )

    def _maybe_extend_iterations(self, state: _TurnState, iteration: int) -> None:
        """Grow the iteration budget when real progress is happening.

        Progress is measured from tracked outcomes rather than by re-scanning
        history text for ``"status": "success"``. Extending no longer consumes
        an iteration: the old code did ``iteration += 1; continue``, so every
        fifth iteration was spent bumping a counter instead of calling the
        model.
        """
        if self.max_iterations >= self._max_iteration_cap:
            return
        near_limit = iteration >= self.max_iterations - 3
        if not (iteration and iteration % 5 == 0) and not near_limit:
            return

        successes = sum(1 for ok in state.recent_outcomes if ok)
        errors = len(state.recent_outcomes) - successes
        distinct_recent = len(set(state.recent_calls))
        headroom = self._max_iteration_cap - self.max_iterations

        # Extending a read-only loop on an action request only rewards the
        # model for refusing to act; pressure handles that case instead.
        if (
                state.action_intent
                and state.writes == 0
                and state.successful_tools >= _EXTENSION_SUPPRESS_SUCCESSES
        ):
            self._log(
                f"Read-only loop on action task (successes="
                f"{state.successful_tools}, writes=0) — extension suppressed."
            )
            return

        if successes > errors and successes > 0 and distinct_recent >= 3:
            extension = min(5 + successes * 2, headroom)
        elif len(state.recent_files) >= 3 and state.successful_tools >= 5:
            extension = min(20, headroom)
        else:
            return

        if extension <= 0:
            return
        old_limit = self.max_iterations
        self.max_iterations += extension
        self._log(
            f"Progress detected (successes={successes} errors={errors} "
            f"files={len(state.recent_files)}); max_iterations "
            f"{old_limit} -> {self.max_iterations}"
        )

    def _guard_repetitive_output(
            self,
            text_clean: str,
            tool_calls: Sequence[Tuple[str, Dict[str, Any]]],
            iteration: int,
    ) -> bool:
        """Bail on degenerate text loops. Returns True if handled.

        Skipped when a valid tool call is present (batch calls legitimately
        repeat structure) and routed to the malformed path when the reply is a
        broken tool call carrying repetitive code.
        """
        if tool_calls or not _has_repetitive_output(text_clean):
            return False
        if looks_like_malformed_tool_call(text_clean)[0]:
            self._log(
                f"Repetitive output at iteration {iteration} but the reply looks "
                f"like a malformed tool call; routing to the malformed path."
            )
            return False
        self._log(
            f"Repetitive output at iteration {iteration} "
            f"({len(text_clean)} chars); bailing to recap."
        )
        raise _Bail(self._build_recap_answer(reason="model stuck in a repetitive text loop"))

    def _surface_sanitizer_drops(self) -> Set[str]:
        """Tell the model which keys the sanitizer stripped.

        Without this the model silently re-emits the call, which is now
        byte-identical to a previous one, and the repeat detector kills the turn.
        """
        drops = drain_recent_drops()
        if not drops:
            return set()
        lines = [
            f"  - {name}: rejected keys {dropped}; the only accepted keys are "
            f"{kept or '[none — see schema]'}"
            for name, dropped, kept in drops
        ]
        self._nudge("schema_feedback", _directive_schema_feedback(lines))
        return {name for name, _, _ in drops}

    def _handle_empty_reply(
            self, state: _TurnState, raw_text: Optional[str], iteration: int
    ) -> None:
        """The raw reply was non-empty but everything got stripped."""
        state.iters_with_empty_reply += 1
        self._log(
            f"Cleaned reply empty (streak={state.iters_with_empty_reply}); raw "
            f"reply was {len(raw_text or '')} chars of reasoning / task tags / "
            f"fake transcript."
        )

        # Plan emitted but no work: the generic nudge is too vague here — the
        # model just re-emits the plan. Fires immediately, no streak needed.
        if self.task_mode.is_task_flow and state.plan_emitted:
            state.plan_then_start_nudges += 1
            self._log(
                f"Plan already emitted but no task_status + tool; plan-then-start "
                f"nudge {state.plan_then_start_nudges}/{_MAX_PLAN_THEN_START_NUDGES}"
            )
            if state.plan_then_start_nudges >= _MAX_PLAN_THEN_START_NUDGES:
                self._emit_terminal_task_status()
                raise _Bail(
                    self._build_recap_answer(
                        reason=f"model stuck in a plan-then-start loop "
                               f"({state.plan_then_start_nudges} attempts)"
                    )
                )
            self._nudge("plan_then_start", get_system_prompt_value("PLAN_THEN_START_DIRECTIVE"))
            return

        if state.iters_with_empty_reply >= _MAX_ITERS_WITH_EMPTY_REPLY:
            self._nudge("empty_reply", get_system_prompt_value("EMPTY_AFTER_STRIP_DIRECTIVE"))
            state.iters_with_empty_reply = 0
        elif state.empty_retries < 1:
            state.empty_retries += 1
            self._nudge("empty_reply", get_system_prompt_value("EMPTY_REPLY_DIRECTIVE"))

    def _handle_malformed(
            self, state: _TurnState, text_clean: str, finish_reason: Optional[str], iteration: int
    ) -> bool:
        """Corrective feedback for malformed tool calls. True if handled."""
        is_malformed, error = looks_like_malformed_tool_call(text_clean)
        if not is_malformed:
            return False

        # An unclosed structure in a long reply is almost always a generation
        # cutoff, not a syntax error. Route it to the truncation path, which
        # has 10 retries with tail context instead of 2 generic ones.
        if "Unclosed" in error and len(text_clean) > 2000:
            self._log(
                f"Malformed call looks like truncation (unclosed, "
                f"{len(text_clean)} chars); routing to the truncation path."
            )
            # Explicit hand-off: the old code relied on the truncation detector
            # re-deriving this, and silently fell through to the final-answer
            # path when finish_reason was not "length".
            return self._handle_truncation(
                state, text_clean, finish_reason, force_tool_truncation=True
            )

        state.consecutive_malformed += 1
        if state.malformed_retries < _MAX_MALFORMED_RETRIES:
            state.malformed_retries += 1
            self._log(
                f"Malformed tool call (retry {state.malformed_retries}): {error} | "
                f"reply head: {text_clean[:300]!r}"
            )
            self._nudge("malformed", _directive_malformed(error))
            return True

        if state.consecutive_malformed >= _MAX_CONSECUTIVE_MALFORMED:
            self._log(
                f"Consecutive malformed cap reached "
                f"({state.consecutive_malformed}); bailing."
            )
        else:
            self._log(f"Malformed tool call: retries exhausted. Error: {error}")
        # History holds only broken calls; synthesis would fail too.
        raise _Bail(get_system_prompt_value("MALFORMED_GIVE_UP_MESSAGE"))

    def _handle_truncation(
            self,
            state: _TurnState,
            text_clean: str,
            finish_reason: Optional[str],
            force_tool_truncation: bool = False,
    ) -> bool:
        """Recover a reply cut off by max_tokens. True if handled."""
        unclosed = looks_like_unclosed_tool(text_clean)
        looks_truncated = force_tool_truncation or finish_reason == "length" or unclosed
        if not looks_truncated:
            return False
        if state.truncation_retries >= _MAX_TRUNCATION_RETRY:
            return False

        state.truncation_retries += 1
        is_tool_truncation = (
                force_tool_truncation
                or unclosed
                or bool(parse_all_tag_tool_calls(text_clean, self.tool_registry.definitions))
        )

        if is_tool_truncation:
            self._log(f"Truncated tool call (retry {state.truncation_retries}).")
            if state.truncation_retries >= _MAX_TRUNCATION_BEFORE_SPLIT_NUDGE:
                self._log("Repeated truncation; switching to the split-batch directive.")
                self._nudge(
                    "truncation_split",
                    get_system_prompt_value("TRUNCATION_SPLIT_DIRECTIVE"),
                )
            else:
                self._nudge(
                    "malformed",
                    _directive_malformed(get_system_prompt_value("TRUNCATED_TOOL_ERROR")),
                )
        else:
            self._log(f"Truncated final answer (retry {state.truncation_retries}).")
            tail = text_clean[-800:]
            self._nudge("truncated", _directive_truncated_answer(tail))
        return True

    # ------------------------------------------------------------------
    # Task protocol
    # ------------------------------------------------------------------

    def _process_task_protocol(
            self, state: _TurnState, text: Optional[str], iteration: int
    ) -> Tuple[bool, Optional[str]]:
        """Parse / emit task-flow events and strip the tags from *text*.

        Returns ``(saw_status, text)``; ``text is None`` means a plan-first
        nudge was injected and the iteration should restart.
        """
        if not self.task_mode.is_task_flow:
            return False, text

        saw_status = False
        if text:
            text = self._handle_proposed_plan(state, text)

            status_events = parse_task_status(text)
            # Terminal statuses from the model are NOT trusted: it routinely
            # finishes the work and forgets to emit ``done``, freezing the
            # checklist. The orchestrator decides them from the real outcome
            # in _emit_terminal_task_status; ``in_progress`` is honored as a
            # cursor for which task is active.
            terminal = (TaskStatus.DONE, TaskStatus.FAILED, TaskStatus.SKIPPED)
            for event in status_events:
                self._tracker.update_status(event.id, event.status, event.note)
                if event.status == TaskStatus.IN_PROGRESS:
                    self._active_task_id = event.id
                    self._inprogress_task_ids = self._inprogress_task_ids | {event.id}
                if event.status not in terminal:
                    emit_task_status(event)
            saw_status = bool(status_events)

            self._update_plan_system_prompt()
            text = strip_task_tags(text)
            if saw_status:
                state.iters_without_status = 0

        # A brand-new request must produce a plan. Bounded so a model that
        # cannot plan does not spend the whole budget being nudged.
        if (
                not state.plan_emitted
                and not state.is_task_action
                and state.plan_first_nudges < _MAX_PLAN_FIRST_NUDGES
                and iteration <= _MAX_PLAN_FIRST_NUDGES
        ):
            state.plan_first_nudges += 1
            self._log(
                f"Iteration {iteration} in {self.task_mode.value} emitted no "
                f"<tasks> plan; injecting the plan-first nudge."
            )
            self._nudge("plan_first", get_system_prompt_value("PLAN_FIRST_DIRECTIVE"))
            return saw_status, None

        return saw_status, text

    def _handle_proposed_plan(self, state: _TurnState, text: str) -> str:
        """Accept a first/legitimate plan; discard a re-emission."""
        proposed = parse_tasks(text)
        if not proposed:
            return text

        if state.plan_emitted and not state.is_task_action and self._planned_task_ids:
            # Accepting a re-emitted plan teaches the model that re-planning is
            # normal — the root cause of the plan-then-start loop.
            self._log(
                f"Model re-emitted a <tasks> plan while one is active "
                f"(ids={self._planned_task_ids}); discarding the re-emission."
            )
            return strip_task_tags(text)

        # A legitimate re-plan must close out the old tasks or the checklist
        # stays frozen on them forever.
        if self._planned_task_ids:
            in_progress = self._inprogress_task_ids
            for old_id in self._planned_task_ids:
                status = TaskStatus.DONE if old_id in in_progress else TaskStatus.SKIPPED
                emit_task_status(
                    TaskStatusEvent(
                        id=old_id, status=status, note="auto: superseded by re-plan"
                    )
                )
                self._log(f"Auto-closing task #{old_id} ({status.value}: re-plan).")

        emit_tasks_proposed(proposed)
        self._planned_tasks = {task.id: task for task in proposed}
        self._planned_task_ids = [task.id for task in proposed]
        self._tracker.set_plan(proposed)
        state.plan_emitted = True
        return text

    def _emit_terminal_task_status(self) -> None:
        """Decide and emit the terminal status from the real turn outcome.

        Rule: a code validator that failed IN THIS ITERATION -> partial;
        otherwise -> done. Uses the per-iteration flag so an early failure does
        not downgrade a much later text-only answer.
        """
        if not self.task_mode.is_task_flow:
            return

        targets: Set[int] = set(self._inprogress_task_ids)
        if not targets and self._active_task_id is not None:
            targets.add(self._active_task_id)
        if not targets and self._planned_task_ids:
            targets.add(self._planned_task_ids[0])
        if not targets:
            return

        if self._turn.iter_had_failed_validator:
            status, note = TaskStatus.PARTIAL, "auto: a code validator failed this turn"
        else:
            status, note = TaskStatus.DONE, "auto: completed this turn"

        for tid in sorted(targets):
            emit_task_status(TaskStatusEvent(id=tid, status=status, note=note))
            self._log(f"Terminal task_status (orchestrator-decided): #{tid} -> {status.value}")

    def _maybe_nudge_missing_status(self, state: _TurnState, saw_status: bool) -> None:
        if not self.task_mode.is_task_flow or saw_status:
            return
        state.iters_without_status += 1
        if state.iters_without_status < _MAX_ITERS_WITHOUT_STATUS:
            return
        self._log(
            f"{state.iters_without_status} tool iterations without a "
            f"<task_status>; injecting a corrective nudge."
        )
        self._nudge("status_nudge", get_system_prompt_value("TASK_STATUS_NUDGE_DIRECTIVE"))
        state.iters_without_status = 0

    # ------------------------------------------------------------------
    # Tool dispatch
    # ------------------------------------------------------------------

    def _dispatch_tool_calls(
            self,
            state: _TurnState,
            tool_calls: Sequence[Tuple[str, Dict[str, Any]]],
            sanitized_tools: Set[str],
            saw_status: bool,
            iteration: int,
    ) -> None:
        state.consecutive_malformed = 0
        state.iters_with_empty_reply = 0
        state.plan_then_start_nudges = 0

        self._maybe_nudge_missing_status(state, saw_status)

        if self._detect_repeat_calls(state, tool_calls, sanitized_tools):
            return  # warning injected; skip execution this iteration

        for name, params in tool_calls:
            state.recent_calls.append(_canonicalize_tool_key(name, params))
            self._log(f"-> {name}({json.dumps(params, default=str)[:200]})")
            result = self.tool_registry.execute(name, params)
            self._record_outcome(state, name, params, result)

            display_result = self._bound_result(result)
            is_last_chance = iteration >= self.max_iterations - 2
            self.conversation_history.add_turn(
                "user", _tool_result_followup(name, display_result, is_last_chance)
            )

        if state.consecutive_validations >= _MAX_CONSECUTIVE_VALIDATIONS:
            self._log(
                f"{state.consecutive_validations} clean validations in a row; "
                f"forcing finalize."
            )
            self._nudge(
                "validation_done",
                _directive_validation_complete(state.consecutive_validations),
            )

    def _detect_repeat_calls(
            self,
            state: _TurnState,
            tool_calls: Sequence[Tuple[str, Dict[str, Any]]],
            sanitized_tools: Set[str],
    ) -> bool:
        """Warn (then bail) when the model loops on an identical call.

        Three exemptions: (1) a call whose keys we just stripped is not really a
        duplicate, (2) an idempotent validator or a run_command verifier re-run
        after a write is real progress, (3) re-reading a file after a failed
        patch is how the model recovers from a truncated read.
        """
        repeats: List[Tuple[str, Dict[str, Any]]] = []
        for name, params in tool_calls:
            if name in sanitized_tools:
                continue
            key = _canonicalize_tool_key(name, params)
            if key not in state.recent_calls:
                continue
            if state.wrote_since_validator and (
                    name in _IDEMPOTENT_VALIDATORS or name == "run_command"
            ):
                self._log(f"{name} re-run after a write — legitimate, not a repeat.")
                continue
            if name in _READ_TOOLS and state.failed_writes_since_read:
                self._log(f"{name} re-read after failed writes — legitimate.")
                continue
            repeats.append((name, params))

        if not repeats:
            return False

        state.repeat_warnings += 1
        self._log(
            f"Repeat tool call (warning {state.repeat_warnings}/"
            f"{_MAX_REPEAT_WARNINGS}): {[name for name, _ in repeats]}"
        )
        if state.repeat_warnings >= _MAX_REPEAT_WARNINGS:
            raise _Bail(
                self._build_recap_answer(
                    reason=f"repeat-call cap after {state.repeat_warnings} warnings "
                           f"on {[name for name, _ in repeats]}"
                )
            )

        summary = ", ".join(
            f"{name}({json.dumps(params, ensure_ascii=False, default=str)[:120]})"
            for name, params in repeats
        )
        self._nudge("repeat_warning", _directive_repeat_call(summary))
        return True

    def _record_outcome(
            self, state: _TurnState, name: str, params: Dict[str, Any], result: str
    ) -> None:
        """Update all progress / loop-detection counters from one tool result."""
        success = _result_is_success(result)
        state.recent_outcomes.append(success)

        is_write = name in _WRITE_TOOLS
        is_validator = name in _IDEMPOTENT_VALIDATORS

        if success:
            state.successful_tools += 1
            self._successful_tool_count += 1

            if is_write:
                path = params.get("path") or ""
                if path:
                    self._files_modified.add(path)
                    state.recent_files.add(path)
                state.writes += 1
                state.pending_step_report = True
                state.wrote_since_validator = True

            if is_validator:
                state.consecutive_validations += 1
                # A validator just ran: the next one is only legitimate if
                # another write happens first.
                state.wrote_since_validator = False
            elif name == "run_command":
                # run_command doubles as a custom validator; treat it the same
                # way so write -> verify -> write -> verify is not a repeat.
                state.wrote_since_validator = False
            elif not is_write:
                state.consecutive_validations = 0

            if name in _READ_TOOLS:
                state.failed_writes_since_read = False
        else:
            state.consecutive_validations = 0
            if name in _CODE_VALIDATORS:
                state.turn_had_failed_validator = True
                state.iter_had_failed_validator = True
            if is_write:
                state.failed_writes_since_read = True

    def _bound_result(self, result: str) -> str:
        """Head+tail truncation: keep imports/headers AND the implementation."""
        limit = self._max_tool_result_chars
        if len(result) <= limit:
            return result
        half = limit // 2
        dropped = len(result) - limit
        return (
                result[:half]
                + f"\n[... {dropped} chars truncated from middle ...]\n"
                + result[-half:]
        )

    # ------------------------------------------------------------------
    # Text classifiers
    # ------------------------------------------------------------------

    _CLIFFHANGER_RE = re.compile(
        r"\b(?:"
        r"would\s+you\s+like\s+me\s+to\s+(?:proceed|continue|move|go|start|next)"
        r"|shall\s+i\s+(?:proceed|continue|move|go|start)"
        r"|should\s+i\s+(?:now|next|proceed|continue)"
        r"|(?:are\s+you\s+)?ready\s+to\s+proceed"
        r"|let\s+me\s+know\s+if\s+(?:you|i|we)"
        r"|want\s+me\s+to\s+(?:keep|continue|proceed)"
        r"|do\s+you\s+want\s+me\s+to\s+(?:proceed|continue|move|go)"
        r"|(?:i'?ll|i\s+will|i\s+can)\s+wait\s+for\s+your\s+"
        r"(?:input|confirmation|approval|go)"
        r"|please\s+confirm\s+(?:if|whether|to)"
        r")\b",
        re.IGNORECASE,
    )

    _ANNOUNCE_VERBS = (
        r"examine|read|check|look\s+(?:at|into)|continue|proceed|see|verify|inspect|"
        r"review|analyze|investigate|explore|search|scan|trace|find|locate|fix|"
        r"update|patch|replace|correct|modify|adjust|implement|handle|address|resolve"
    )

    _ANNOUNCE_STUB_RE = re.compile(
        r"^\s*(?:"
        r"now\s+i\s*(?:'?ll|will)"
        r"|next,?\s+i\s*(?:'?ll|will)"
        r"|next,?\s+let\s+me"
        rf"|let\s+me\s+(?:{_ANNOUNCE_VERBS})"
        rf"|i\s*(?:'?ll|will)\s+(?:now|{_ANNOUNCE_VERBS})"
        rf"|(?:i|we)\s+need\s+to\s+(?:understand|figure\s+out|{_ANNOUNCE_VERBS})"
        rf"|i\s+(?:have|got)\s+to\s+(?:understand|figure\s+out|{_ANNOUNCE_VERBS})"
        rf"|i\s+must\s+(?:understand|figure\s+out|{_ANNOUNCE_VERBS})"
        r")\b",
        re.IGNORECASE,
    )

    _STEP_REPORT_MARKER_RE = re.compile(
        r"^\s*[_*]*STEP\s+REPORT[_*]*\s*$", re.IGNORECASE | re.MULTILINE
    )

    def _looks_like_step_report(self, text: str) -> bool:
        return bool(text) and bool(self._STEP_REPORT_MARKER_RE.search(text))

    def _looks_like_cliffhanger(self, text: str) -> bool:
        """True when a plain-text reply hands work back instead of finishing.

        Two shapes: an explicit confirmation request (always), or a short
        announce-stub with no tool call. Long replies containing these phrases
        alongside real content are not flagged.
        """
        stripped = (text or "").strip()
        if not stripped:
            return False
        if self._CLIFFHANGER_RE.search(stripped):
            return True
        return len(stripped) <= 200 and bool(self._ANNOUNCE_STUB_RE.search(stripped))

    # ------------------------------------------------------------------
    # Synthesis and recap
    # ------------------------------------------------------------------

    def _attempt_synthesis(self) -> Optional[str]:
        """One last model call asking for a final answer.

        If the model insists on a final validation tool we run it and ask
        again — otherwise the common failure is a ``flutter_analyze`` call
        returned to the user as the "answer". Returns cleaned text, or ``None``
        so the caller falls back to the raw recap.
        """
        max_synth_tools = 3
        synth_tool_count = 0

        # Defensive copy: the synthesis directive must not pollute the live
        # history for the next user turn.
        synth_history = self.conversation_history.copy()
        # The base prompt carries the whole tool catalog; leaving it in makes
        # the model keep emitting <tool> tags during synthesis.
        synth_history.clear_system_prompts()
        synth_history.set_system_prompt(
            "synthesis",
            get_system_prompt_value("SYNTHESIS_DIRECTIVE"),
        )

        while synth_tool_count < max_synth_tools:
            try:
                text, _ = self.backend.chat(
                    conversation=synth_history,
                    max_tokens=max(self.max_tokens, 8192),
                    temperature=self.temperature,
                    tools=None,
                    stop=list(_SYNTH_STOP_SEQUENCES),
                    thinking=self.thinking,
                    effort=self.effort,
                    on_thinking=emit_thinking,
                )
            except Exception as exc:  # noqa: BLE001
                self._log(f"Synthesis call failed: {exc}")
                return None

            text = text or ""
            tool_calls = parse_all_tag_tool_calls(text, self.tool_registry.definitions)

            if tool_calls:
                # Record the assistant turn ONCE, not once per call.
                synth_history.add_assistant(text)
                for name, params in tool_calls:
                    self._log(f"Synthesis phase: executing requested tool {name}.")
                    try:
                        result = self.tool_registry.execute(name, params)
                    except Exception as exc:  # noqa: BLE001
                        result = json.dumps(
                            {"status": "error", "message": f"Tool execution failed: {exc}"}
                        )
                    if len(result) > 6000:
                        result = (
                                result[:3000]
                                + "\n[... result truncated in synthesis ...]\n"
                                + result[-3000:]
                        )
                    synth_history.add_user(
                        _tool_result_followup(name, result, is_last_chance=True)
                    )
                    synth_tool_count += 1

                synth_history.set_system_prompt(
                    "synthesis",
                    get_system_prompt_value("SYNTHESIS_DIRECTIVE")
                    + get_system_prompt_value("SYNTHESIS_LAST_CHANCE_SUFFIX"),
                )
                continue

            salvaged = self._salvage_synthesis_text(text)
            if salvaged is not None:
                return salvaged
            return None

        self._log(
            f"Synthesis hit the max tool-call allowance ({max_synth_tools}); "
            f"falling back to the raw recap."
        )
        return None

    def _salvage_synthesis_text(self, text: str) -> Optional[str]:
        """Validate and clean a synthesis reply. ``None`` -> use the raw recap."""
        raw_len = len(text)

        # Trailing tool attempt: keep the prose that came before it.
        tool_index = text.find("<tool")
        if tool_index > 0:
            candidate = text[:tool_index].strip()
            if len(candidate) >= 20:
                self._log(
                    f"Synthesis had a trailing tool call at offset {tool_index}; "
                    f"salvaging {len(candidate)} chars."
                )
                text = candidate

        # Check the RAW text: clean_final_answer would strip the wrapper and
        # hide a real tool call.
        if parse_all_tag_tool_calls(text, self.tool_registry.definitions):
            self._log("Synthesis reply contained tool calls; using the raw recap.")
            return None

        cleaned = clean_final_answer(text).strip()
        if not cleaned:
            self._log(f"Synthesis produced empty text (raw_len={raw_len}).")
            return None
        if parse_all_tag_tool_calls(cleaned, self.tool_registry.definitions):
            self._log("Cleaned synthesis still contained tool calls.")
            return None
        if len(cleaned) < 200 and looks_like_tool_attempt(cleaned):
            self._log(f"Synthesis looks like orphaned tool fragments (len={len(cleaned)}).")
            return None

        # NOTE: looks_like_malformed_tool_call is deliberately NOT applied here.
        # A good summary naturally names prior tools and may quote JSON results,
        # and that heuristic then discards a perfectly valid final answer.
        self._log(f"Synthesis succeeded (raw={raw_len}, clean={len(cleaned)}).")
        return cleaned

    def _build_recap_answer(self, reason: str = "") -> str:
        """Best available answer when the loop must abandon.

        1. Ask the model to synthesize from existing history.
        2. Stitch the last few tool results into readable markdown.
        3. Otherwise a short, honest error.
        """
        synthesized = self._attempt_synthesis()
        if synthesized:
            return synthesized

        results = self._collect_tool_result_snippets()
        prefix = (
                "**I couldn't compose a single synthesized answer"
                + (f" ({reason})" if reason else "")
                + ".**\n\n"
        )
        if not results:
            return prefix + (
                "No tool results were collected before bailing — the request may be "
                "too ambiguous, or the model may not support tool use. Try "
                "rephrasing, or use a different model."
            )
        return (
                prefix
                + "Here's a recap of what I found while investigating:\n\n"
                + "\n\n".join(results)
        )

    def _collect_tool_result_snippets(self, limit: int = 6, per_result: int = 4000) -> List[str]:
        """Readable markdown for the most recent tool results."""
        snippets: List[str] = []
        for message in self.conversation_history.turns:
            if message.get("role") != "user":
                continue
            content = message.get("content") or ""
            if not content.startswith("Tool `"):
                continue
            head, _, body = content.partition("\n")
            body = self._strip_internal_marker(body).strip()
            payload = self._extract_tool_payload(body)
            if len(payload) > per_result:
                payload = payload[:per_result].rstrip() + "\n… (truncated)"
            snippets.append(f"### {head.rstrip(':')}\n\n```\n{payload}\n```")

        # Consecutive identical results (six empty searches) add no information
        # and bury anything useful that came before them.
        deduped: List[str] = []
        for snippet in snippets:
            if not deduped or deduped[-1] != snippet:
                deduped.append(snippet)
        return deduped[-limit:]

    @staticmethod
    def _strip_internal_marker(body: str) -> str:
        """Drop the trailing ``[INTERNAL: ...]`` directive from a follow-up."""
        index = body.find("[INTERNAL:")
        return body if index == -1 else body[:index].rstrip()

    @staticmethod
    def _extract_tool_payload(body: str) -> str:
        """Surface the human-readable field of a JSON tool envelope."""
        try:
            payload = json.loads(body)
        except (ValueError, TypeError):
            return body
        if not isinstance(payload, dict):
            return body
        for key in ("content", "message", "stdout", "result"):
            value = payload.get(key)
            if isinstance(value, str) and value.strip():
                return value
        for key in ("matches", "tree", "files", "lines"):
            value = payload.get(key)
            if isinstance(value, list) and value:
                return "\n".join(str(item) for item in value[:50])
        return body

    def _dump_session(self) -> None:
        """Write the transcript to ``.agentic/`` for post-mortem debugging.

        The old code wrote ``session_dump.json`` into the process CWD, which
        violates the project-root rule the system prompt enforces on the model.
        """
        try:
            target_dir = self.tool_registry.base_path / ".agentic"
            target_dir.mkdir(parents=True, exist_ok=True)
            path = target_dir / f"session_dump_{int(time.time())}.json"
            with path.open("w", encoding="utf-8") as handle:
                json.dump(
                    self.conversation_history.to_messages(),
                    handle,
                    indent=2,
                    ensure_ascii=False,
                    default=str,
                )
            self._log(f"Session dumped to {path}")
        except OSError as exc:
            self._log(f"Failed to save the session dump: {exc}")

    # ------------------------------------------------------------------
    # Backend call: retry + circuit breaker
    # ------------------------------------------------------------------

    @classmethod
    def _is_retryable_error(cls, exc: BaseException) -> bool:
        message = str(exc).lower()
        return any(hint in message for hint in cls._RETRYABLE_HINTS)

    def _call_model(self) -> Tuple[str, Optional[str]]:
        """One chat completion via the prompt-based protocol.

        Returns ``(content, finish_reason)``; ``finish_reason == "length"``
        means the reply is truncated, which the caller must handle — a
        half-written ``<tool>`` is worse than no tool call.

        Retries 429 / 5xx with backoff (1, 2, 4, 8, 16 s).
        """
        # Refresh the task-state prompt before every call so the model never
        # re-emits a status for a task the tracker already closed.
        self.conversation_history.sync_task_state()

        if not self._model_circuit_breaker.allow_request():
            raise RuntimeError(
                f"Model circuit breaker is OPEN for '{self.model_id}'. Too many "
                f"consecutive failures — auto-retry in "
                f"{self._model_circuit_breaker.recovery_timeout:.0f}s. Check the "
                f"API key, quota, or network."
            )

        last_exc: Optional[BaseException] = None
        attempts = len(self._RETRY_BACKOFFS) + 1

        for attempt in range(attempts):
            if attempt:
                wait_s = self._RETRY_BACKOFFS[attempt - 1]
                self._log(
                    f"Transient error, backing off {wait_s}s "
                    f"(attempt {attempt + 1}/{attempts}): {last_exc}"
                )
                time.sleep(wait_s)
            try:
                # [stop-sequence-fix] ``</tool>`` stops the model from
                # hallucinating a fake ``User: ... Assistant: ...`` transcript
                # after the real tool tag; the speaker markers catch providers
                # that ignore it. The missing closing tag is repaired by the
                # caller. ROLLBACK: drop the ``stop=`` kwarg.
                result = self.backend.chat(
                    conversation=self.conversation_history,
                    max_tokens=self.max_tokens,
                    temperature=self.temperature,
                    tools=self.tool_registry.definitions,
                    stop=list(_TOOL_STOP_SEQUENCES),
                    thinking=self.thinking,
                    effort=self.effort,
                    on_thinking=emit_thinking,
                )
                self._model_circuit_breaker.record_success()
                text, finish_reason = result
                return text or "", finish_reason
            except Exception as exc:  # noqa: BLE001 - broad by design
                last_exc = exc
                if not self._is_retryable_error(exc):
                    # Auth errors, malformed input, connection refused: no
                    # retry, but still a failure for the breaker.
                    self._model_circuit_breaker.record_failure()
                    raise

        self._model_circuit_breaker.record_failure()
        raise RuntimeError(
            f"Model backend kept returning a rate-limit / transient error after "
            f"{attempts} attempts. Last error: {last_exc}. Try again shortly, "
            f"switch to a less-busy model, or check quota / daemon health."
        )
