"""The Orchestrator class — runs the iterate-call-tool-call-call loop."""

from __future__ import annotations

import json
import re
import sys
import time
from typing import Any, Dict, List, Optional

from . import history as _history
from . import tool_dispatch as _td
from .tool_detector import ToolIntentDetector
from ..backends.backend_base import ModelBackend
from ..policy import SecurityConfig
from ..tools.registry import ToolRegistry
from ..utils.circuit_breaker import CircuitBreaker
from ..utils.token_estimator import chars_for_tokens, estimate_messages_tokens

# Default cap on tool-result chars. Used as a floor when the backend
# doesn't expose a context_limit; the Orchestrator scales this up at
# runtime via ``self._max_tool_result_chars`` so a 128K cloud model
# isn't throttled by the 12K value sized for 8K Ollama.
_MAX_TOOL_RESULT_CHARS_FALLBACK = 12_000
_MAX_TRUNCATION_RETRY = 10
# Idempotent validation tools. Calling these more than twice in a row
# without intervening edits almost always means the model is stalling
# rather than making progress — we nudge it to finalize before the
# repeat-call detector trips and bails the whole turn.
_IDEMPOTENT_VALIDATORS = frozenset(
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

# Task-flow nudges
_MAX_ITERS_WITHOUT_STATUS = 3  # tool calls without <task_status> emission
_MAX_ITERS_WITHOUT_PLAN = 1    # compliance iters without <tasks> plan
_MAX_ITERS_WITH_EMPTY_REPLY = 2  # empty cleaned reply (post-strip)

# Bare confirmations / continuations that mean "execute the prior plan", not
# "open-ended exploration". Mirrors workflow.py's _FOLLOWUP_RE so the
# single-agent path gets the same intent-recovery the multi-agent Shaper
# provides.
_FOLLOWUP_RE = re.compile(
    r"^\s*(?:"
    r"ok(?:ay)?(?:\s+(?:proceed|go|do\s+it|continue|good))?"
    r"|yes(?:\s+(?:proceed|go|do\s+it|continue|please))?"
    r"|sure(?:\s+(?:do\s+it|go|proceed))?"
    r"|proceed|continue|go\s+ahead|do\s+it|fix\s+it|please\s+continue"
    r")[\s!.?]*$",
    re.IGNORECASE,
)

# Pure affirmations that should trigger immediate final response without
# further processing. These are distinct from mixed messages that combine
# praise with additional instructions.
_AFFIRMATION_RE = re.compile(
    r"^\s*(?:"
    r"great\s+work"
    r"|well\s+done"
    r"|perfect"
    r"|excellent"
    r"|awesome"
    r"|fantastic"
    r"|amazing"
    r"|outstanding"
    r"|brilliant"
    r"|superb"
    r"|incredible"
    r"|wonderful"
    r"|terrific"
    r"|fabulous"
    r"|marvelous"
    r"|impressive"
    r"|remarkable"
    r"|extraordinary"
    r"|phenomenal"
    r"|exceptional"
    r")[\s!.?]*$",
    re.IGNORECASE,
)

# Action-intent verbs. When the user's request contains one of these, the
# loop expects at least one write_file/patch_file/append_file before a final
# answer. Used to gate dynamic-iteration extension and progressive pressure.
_ACTION_VERB_RE = re.compile(
    r"\b(implement|fix|write|create|edit|update|modify|refactor|add|delete|"
    r"remove|rename|build|generate|patch|change|apply|install|setup|"
    r"configure|migrate|port|replace)\b",
    re.IGNORECASE,
)


def _is_short_followup(text: str) -> bool:
    if not text:
        return False
    # Check for pure affirmations first - these should always trigger final response
    # Pure affirmations are those that don't contain action words
    if _AFFIRMATION_RE.match(text):
        # Make sure it's not a mixed message with action words
        lower_text = text.lower()
        action_words = (
            "proceed",
            "continue",
            "go",
            "do it",
            "next",
            "step",
            "follow",
            "execute",
            "run",
            "implement",
        )
        if not any(word in lower_text for word in action_words):
            return True
    if _FOLLOWUP_RE.match(text):
        return True
    stripped = text.strip()
    return len(stripped) <= 25 and not any(
        m in stripped.lower() for m in (".dart", ".py", "lib/", "bin/", "git ")
    )


# ======================================================================
# PROMPT DIRECTIVES
# ----------------------------------------------------------------------
# All model-facing prompt text lives here. Static prompts are module-level
# constants; dynamic prompts (those interpolating runtime values) are
# `_get_*_directive(...)` helpers. The Orchestrator class itself contains
# no prompt strings — it only references these names.
# ======================================================================

# Confirmation-reply preamble. Prepended after _AGENT_DIRECTIVE when the
# user's message is a bare "yes / proceed / do it" against a prior plan.
_FOLLOWUP_DIRECTIVE = (
    "[CONTEXT: This is a confirmation reply. The user is confirming the plan "
    "from your IMMEDIATELY PRECEDING assistant turn. Execute the FIRST "
    "concrete action from that plan now. Do NOT re-explain the plan. Do NOT "
    "re-research the codebase if you already have enough context. If the "
    "plan involves editing files, START EDITING with patch_file..]\n\n "
)


_AGENT_DIRECTIVE = (
    "[You have filesystem tools available. "
    "If this request requires any file access, inspection, editing, execution, or verification, you MUST emit exactly ONE tool call: "
    '<tool>{"tool":"NAME","parameters":{...}}</tool>. '
    "- Do not add any explanation, preamble, or follow-up text before or after the tool call. "
    "- Prefer dedicated tools first (read_files/search_in_files/list_files/flutter_analyze/python_check/"
    "python_lint/python_test/git_*) and use run_command only as a last resort. "
    "- The tool JSON must remain strictly valid under the initial system prompt; prefer single quotes inside shell commands. "
    "After any code change, you MUST run the highest-scope validator available before responding. "
    "Flutter validation scope priority: "
    "1. Entire project/workspace. "
    "2. Package/module. "
    "3. Single file. "
    "Always choose the highest available scope unless the user explicitly requests a narrower scope. "
    "Workspace validation defaults: "
    "- Flutter/Dart validation is PROJECT-SCOPED by default. "
    "- Treat every source file as part of an interconnected codebase. "
    "- Assume changes may affect imports, dependencies, generated code, tests, build configuration, and runtime behavior outside the modified file. "
    "- Never limit validation to the edited file unless the user explicitly requests file-only validation. "
    "Flutter rules: "
    "- Whenever any .dart file, pubspec.yaml, analysis_options.yaml, build configuration, generated source, asset configuration, or test is created, modified, analyzed, reviewed, refactored, or verified, run flutter_analyze against the project root. "
    "- The purpose of flutter_analyze is to detect cross-file errors, type issues, dependency problems, build issues, and regressions that cannot be detected from a single file. "
    "- Passing a specific file path to flutter_analyze is prohibited unless the user explicitly requests file-specific analysis. "
    "- If both a modified file path and project root are available, always prefer the project root. "
    "- After any Flutter/Dart code change, project-wide flutter_analyze is mandatory before reporting success. "
    "- If Flutter tests exist or are affected by the change, run project-wide flutter_test after flutter_analyze. "
    "- When running flutter_analyze or flutter_test, always prefer the working directory and never pass a specific file unless explicitly requested by the user. "
    "Python rules: "
    "- Whenever any .py file, package configuration, dependency definition, generated source, or test is created or modified, run python_check passing the directory of each affected file as the target path. "
    "- If multiple modified files span different directories, run python_check once per affected directory. "
    "- After python_check passes, if tests exist in or near the affected directory, run python_test passing that same directory as the target path. "
    "- Never run project-wide Python validation unless the user explicitly requests it. "
    "Shared validation rules: "
    "- Never use cd to change directory before any command. "
    "- Never claim validation passed unless the required validators were actually executed. "
    "- Never skip validation when a validator exists. "
    "- If the request is not file-related, reply normally.]\n"
    "[- You are an excellent software analyst and an excellent software engineer. "
    "- You have access to all tools and capabilities. Do not hold back. "
    "- Use every resource available and all your power to complete the task as thoroughly and efficiently as possible. "
    "- If this task requires a lot of effort, you must break it down into separate, numbered tasks. "
    "- Upon confirmation of running the tasks, if there is more than one task, run them one at a time and wait for confirmation for the next task. "
    "- If you need to create tests on use cases, you need to place the test files in the tests/ folder. If the folder doesn't exist, create it. "
    "Do not use phrases like: 'I will ...', 'I need to see ...', 'We need to ...', "
    "'Let me proceed ...', 'Let me search...', 'Is there anything specific ...', "
    "'Would you like me to proceed ...?', 'Would you like me to implement ...?'. "
    "Instead, perform the action immediately or give the final answer.]\n\n"
)

# Final synthesis directive injected as a final user turn before the
# synthesis call. Tells the model to stop tool-using and write the answer
# (or ask one clarifying question) using only what's already in history.
# Coding-aware: explicitly asks for a recap of files modified + validation
# status, which is what most coding sessions actually want.
_SYNTHESIS_DIRECTIVE = (
    "[FINAL SYNTHESIS] Stop. The tool loop is over — no more tool "
    "calls will be executed, and any you emit will be ignored.\n"
    "\n"
    "Using ONLY the conversation above, write the user's final "
    "answer. Structure it as:\n"
    "  1. A 1-2 sentence summary of what was accomplished (what "
    "     question was answered, OR what files were modified and how).\n"
    "  2. If files were edited: list each file path that was "
    "     write_file/patch_file/append_file'd this turn, one per line.\n"
    "  3. If validators ran (python_check, flutter_analyze, etc.): "
    "     state pass/fail for each.\n"
    "  4. If anything is left undone or uncertain, say so explicitly "
    "     in one sentence.\n"
    "\n"
    "Rules:\n"
    "  - No <tool> tags. No JSON tool calls. Plain text or markdown.\n"
    "  - Do not say 'I will' or 'let me' — describe what already "
    "    happened.\n"
    "  - Do not echo this directive.\n"
    "  - If you genuinely have nothing useful to report, ask EXACTLY "
    "    ONE clarifying question instead."
)


# Pressure-injection: 20+ iterations of reads with zero writes on an
# action-task. Forces the model to either patch or finalize next turn.
_ACTION_FINAL_WARNING_DIRECTIVE = (
    "[FINAL WARNING] You have used 20+ iterations reading files but have written nothing. "
    "The request asked for an action.\n "
    "Your IMMEDIATE next message MUST be either:\n "
    "  1) A single  patch_file/append_file tool call, OR \n "
    "  2) Your final plain-text answer (no more tool calls).\n "
    "Stop researching. Act or answer."
)


# Pressure-injection: 10+ iterations of reads with zero writes on an
# action-task. Softer than the final warning above.
_ACTION_NUDGE_DIRECTIVE = (
    "[NUDGE] You have read several files but have not modified anything. "
    "The original request asked for an action (implementing a change). "
    " Either:\n "
    "  1) Make a patch_file/append_file call NOW, OR\n "
    "  2) Give your final plain-text answer if the task is already complete.\n "
    "Avoid reading files unless strictly necessary."
)


# Sent when the model emits a recognizable refusal ("I can't access
# files...") despite having tool access. Forces a concrete tool call.
_REFUSAL_DIRECTIVE = (
    "STOP. That is a refusal and it is wrong. You DO have "
    "filesystem access through the tools. Your entire next "
    "message must be exactly one line, e.g.:\n"
    '<tool>{"tool":"list_files","parameters":{"path":"."}}</tool>\n'
    "No apology, no explanation, no markdown fences. Just "
    "the tool call tag."
)


# Sent when the model returns an empty reply.
_EMPTY_REPLY_DIRECTIVE = (
    "Your reply was empty. Emit a single "
    '<tool>{"tool":"...","parameters":{...}}</tool> '
    "call or the final plain-text answer."
)


# Sent when the model hands work back to the user mid-task ("Would you
# like me to proceed?", "Now I'll examine X.").
_CLIFFHANGER_DIRECTIVE = (
    "[AUTONOMY] Your previous reply ended with a "
    "cliffhanger or a request for confirmation. The "
    "user already approved the work — do NOT ask "
    "again. Your IMMEDIATE next message must be "
    "either:\n"
    "  1. A tool call performing the next concrete "
    "step (a <tool>...</tool> tag), OR\n"
    "  2. A real final answer that summarizes what "
    'you completed (not accepted: "would you like me to...", '
    'no "shall I...", no "let me continue...").\n'
    "Do not announce intent without acting. Do not "
    "split the remaining work across more user "
    "turns.\n\n"
    "The following phrases and equivalent variants "
    "are forbidden because they indicate deferred "
    "action instead of execution:\n"
    "  * 'I will ...'\n"
    "  * 'I need to see ...'\n"
    "  * 'We need to ...'\n"
    "  * 'Let me proceed ...'\n"
    "  * 'Let me search ...'\n"
    "  * 'Is there anything specific ...'\n"
    "  * 'Would you like me to proceed ...?'\n"
    "  * 'Would you like me to implement ...?'\n"
    "  * Any equivalent wording that asks for "
    "permission, announces future work, requests "
    "confirmation, or describes intended actions "
    "instead of immediately performing them."
)


# Sent when a final answer follows a file-modifying call but omits the
# mandatory STEP REPORT block.
_STEP_REPORT_DIRECTIVE = (
    "[STEP REPORT REQUIRED] Your previous reply was a "
    "final answer after modifying files, but it did not "
    "include the mandatory STEP REPORT. You MUST include "
    "a step report in this format:\n\n"
    "STEP REPORT\n"
    "-----------\n"
    "Done:\n"
    "  - [what you completed]\n\n"
    "Pending:\n"
    "  - [what remains, or 'None']\n\n"
    "Current state:\n"
    "  - [1-3 sentences describing current state]\n\n"
    "Add this report to your final answer now. Do NOT "
    "call any more tools.\n\n"
    "NOTE: In TASK COMPLIANCE modes, this is MANDATORY. "
    "The model MUST emit step reports after any file-modifying operation."
)

# Sent when the model fails to emit a <task_status> tag in task compliance modes.
# This directive is added in iteration 1+ when no status was emitted.
_TASK_STATUS_FORCE_DIRECTIVE = (
    "[TASK STATUS REQUIRED] You are in TASK COMPLIANCE mode. "
    "You MUST emit a <task_status>{\"id\":<int>,\"status\":\"pending|in_progress|done|partial|blocked|failed|skipped\",\"note\":\"<short>\"}</task_status> "
    "tag in your next reply so the UI checklist can show your progress. "
    "The status must match the actual state of the task you are working on. "
    "Do NOT emit only a tool call without the status tag. "
    "Do NOT echo this instruction back to the user."
)


# Sent when the model fails to emit a <tasks> plan in task compliance modes.
_TASKS_FORCE_DIRECTIVE = (
    "[TASK PLAN REQUIRED] You are in TASK COMPLIANCE mode. "
    "Your FIRST reply MUST begin with a <tasks>[{\"id\":1,\"name\":\"...\",\"description\":\"...\"}, ...]</tasks> "
    "block enumerating every step needed for this request. "
    "Do NOT call any tool until the plan has been emitted. "
    "Do NOT echo this instruction back to the user."
)


# Fallback message returned when the model fails to emit a valid tool
# call even after retries. Used by both the retry-exhausted and
# consecutive-malformed-cap branches.
_MALFORMED_GIVE_UP_MESSAGE = (
    "The model failed to emit a valid tool call after multiple "
    "attempts. The request may be too ambiguous or the model may "
    "not support tool-use. Try rephrasing your request or using "
    "a different model."
)


def _get_malformed_directive(malformed_error: str) -> Dict[str, str]:
    """Corrective feedback for a malformed tool call.

    Also reused for the truncated-tool-call case (caller passes a
    short description in ``malformed_error`` like " Was CUT OFF
    before the closing </tool> tag. ").
    """
    return {
        "role": "user",
        "content": (
            f"Your previous reply attempted a tool call but the format was invalid. {malformed_error}\n "
            "Reply with EXACTLY ONE valid tool call on a single line in this format:\n "
            '<tool>{"tool":"NAME","parameters":{...}}</tool>\n '
            "No explanation, no markdown, no backticks. Keep the JSON valid. "
            "If a shell command contains quotes, prefer single quotes inside the command string. "
            "--- CORRECT examples (these pass, no need to execute examples to be sure these pass) ---\n"
            "\n"
            '<tool>{"tool":"read_file","parameters":{"path":"src/main.py"}}</tool>\n'
            '<tool>{"tool":"read_files","parameters":{"paths":["a.py","b.py","c.py"]}}</tool>\n'
            '<tool>{"tool":"search_in_files","parameters":{"pattern":"error","file_glob":"*.log"}}</tool>\n'
            '<tool>{"tool":"write_file","parameters":{"path":"out.txt","content":"hello"}}</tool>\n'
            '<tool>{"tool":"patch_file","parameters":{"path":"src/main.py","old_content":"old","new_content":"new"}}</tool>\n'
            '<tool>{"tool":"delete_file","parameters":{"path":"obsolete.py"}}</tool>\n'
            '<tool>{"tool":"list_files","parameters":{"path":"lib"}}</tool>\n'
            '<tool>{"tool":"flutter_analyze","parameters":{}}</tool>\n'
            '<tool>{"tool":"python_check","parameters":{}}</tool>\n'
            '<tool>{"tool":"run_command","parameters":{"command":"git status"}}</tool>\n'
            '<tool>{"tool":"git_commit","parameters":{"message":"fix: resolve null check"}}</tool>\n'
        ),
    }


def _get_schema_feedback_directive(drop_lines: List[str]) -> Dict[str, str]:
    """Sent when the tool-call sanitizer dropped unknown keys. Surfaces
    the drop so the model doesn't silently re-emit the now-identical call
    and trip the repeat-call detector."""
    return {
        "role": "user",
        "content": (
                "[SCHEMA FEEDBACK] Your last tool call(s) included parameters that aren't part of the tool's schema. "
                "Those keys were stripped before execution:\n "
                + "\n".join(drop_lines) + "\n\n "
                                          "Do NOT re-emit the same call - it would be "
                                          "identical to one you already ran. Either call the "
                                          "tool again with ONLY the accepted keys (changing the values that were in the rejected keys to supported alternatives), "
                                          "pick a different tool, or give your final answer."
        ),
    }


def _get_repeat_call_directive(summary: str) -> Dict[str, str]:
    """Sent when the same (tool, params) appears twice in the recent
    window. Steers the model toward a different call or a final answer."""
    return {
        "role": "user",
        "content": (
            f"You already called: {summary} earlier this turn. "
            "Calling the same tool with the same arguments will return the same result. "
            "Either:\n "
            "  1. Call a DIFFERENT tool, or\n "
            "  2. Call the same tool with DIFFERENT arguments, or\n "
            "  3. Give your final plain-text answer to the user now (no more tool calls).\n "
            "Pick one."
        ),
    }


def _get_tool_result_followup(
        name: str, display_result: str, is_last_chance: bool
) -> Dict[str, str]:
    """Standard follow-up after a tool execution. ``is_last_chance``
    forces a finalize directive when the iteration budget is almost gone."""
    if is_last_chance:
        content = (
            f"Tool `{name}` returned:\n{display_result}\n\n"
            "[INTERNAL: FINAL ANSWER REQUIRED. Do NOT call any more tools. "
            "Write only your plain-text answer to the user now. "
            "Do NOT echo this instruction back to the user.]"
        )
    else:
        content = (
            f"Tool `{name}` returned:\n{display_result}\n\n"
            "[INTERNAL: Continue. Either call another tool or give the final answer. "
            "Do NOT echo this instruction back to the user.]"
        )
    return {"role": "user", "content": content}


def _get_validation_complete_directive(count: int) -> Dict[str, str]:
    """Sent when N consecutive idempotent validators ran clean. Catches
    the 'validate forever' stall pattern before it trips the repeat-call
    cap."""
    return {
        "role": "user",
        "content": (
            "[VALIDATION COMPLETE] "
            f"You have run {count} idempotent validators (python_check / flutter_analyze / etc.) clean in a row. "
            "The work is done.\n "
            "Your IMMEDIATE next message MUST be the final plain-text answer to the user a report/summary of what was changed and that validation passed.\n "
            "Do NOT call another validator. Do NOT call any tool. "
            "No <tool> tags. Just the answer. "
        ),
    }


def _get_truncated_answer_directive(tail: str) -> Dict[str, str]:
    """Sent when a plain-text final answer was truncated by max_tokens.
    Embeds the last ~800 chars so the model can continue mid-sentence."""
    return {
        "role": "user",
        "content": (
            "Your previous reply was CUT OFF by the token "
            "limit. Continue EXACTLY from where you left off. "
            "Do NOT repeat what you already wrote. Do NOT "
            "start over. Just continue the text.\n\n"
            "--- LAST 800 CHARS OF YOUR PREVIOUS REPLY ---\n"
            f"{tail}\n"
            "--- END OF PREVIOUS REPLY ---\n\n"
            "Continue from here. Pick up mid-sentence if "
            "necessary. Do NOT add any preamble."
        ),
    }


# Short description passed to _get_malformed_directive when the
# truncation detector sees an unclosed <tool> tag.
_TRUNCATED_TOOL_ERROR = " Was CUT OFF before the closing </tool> tag. "


class Orchestrator:
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
            task_mode: str = "open",
            thinking: bool = False,
            effort: Optional[str] = None,
    ):
        self._action_intent = None
        self._writes_this_turn = None
        self._action_pressure_nudges = None
        self._pending_step_report = None
        self.backend = backend
        # Task-flow mode: open / task_compliance / task_compliance_auto.
        # Drives whether the system prompt advertises the <tasks>
        # protocol and whether the loop emits task_status events on
        # stdout. See :mod:`common.loop.task_protocol`.
        from . import task_protocol as _tp
        self.task_mode = _tp.TaskMode.parse(task_mode)
        # Consecutive iterations the model used a tool but failed to
        # emit a ``<task_status>``. After ``_MAX_ITERS_WITHOUT_STATUS``
        # the loop injects a corrective internal note pushing the
        # model to report progress -- otherwise the UI checklist
        # stays at 0/N forever even while work is actually done.
        self._iters_without_status: int = 0
        # Consecutive iterations whose visible reply was empty AFTER
        # stripping reasoning / task tags / hallucinated transcripts.
        # The fact that the model is producing only stripped content
        # means it's "talking to itself" without doing real work --
        # we inject a corrective nudge.
        self._iters_with_empty_reply: int = 0
        # Per-request flag: was a ``<tasks>`` plan emitted yet?
        # Reset at the start of each ``run()`` call. In compliance
        # modes the orchestrator forces an initial plan when this is
        # still False at the end of iteration 0 (Fix 6).
        self._plan_emitted_this_request: bool = False
        # Per-request flag: was the incoming prompt a ``<task_action>``
        # envelope (Proceed / Retry / Skip / Abort / Replan)? In that
        # case the plan was already emitted in an earlier turn -- we
        # do NOT force a re-plan.
        self._is_task_action_request: bool = False
        # When True, every request is routed as a plain chat call — the
        # tool-decision heuristic and the tool loop are bypassed. Useful
        # for reasoning-only models (phi-4, plain Mistral, etc.) that
        # can't emit valid tool calls.
        self.disable_tools = disable_tools
        # Expose model_id for logging/diagnostics; both backends carry one.
        self.model_id = getattr(backend, "model_id", "(unknown)")
        self.tool_registry = ToolRegistry(
            base_path=base_path,
            security_config=security_config,
            path_filter=path_filter,
            db_connections=db_connections,
        )
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
        # Thinking ON/OFF master switch + Effort level. Updated per-request
        # by the interactive loop so the Flutter UI controls take effect
        # immediately without restarting the orchestrator process.
        self.thinking = thinking
        self.effort = effort
        # Cap tool-chain length. Each iteration is potentially a 60–120 s
        # model call, so 30 bounds a single /sendPrompt at ~60 min worst case,
        # comfortably inside the Dart-side absolute timeout (120 min).
        # Dynamic scaling: starts at 30, can extend to 100+ for complex tasks.
        self.max_iterations = 100
        self._initial_max_iterations = 100
        self._max_iteration_cap = 150  # Absolute ceiling to prevent runaway costs
        self._successful_tool_count = 0  # Track progress for dynamic extension
        self._files_modified = set()  # Track unique files touched

        # Derive history/result caps from the backend's actual context window
        # so a 128K cloud model isn't throttled to ~50K by constants sized
        # for 8K Ollama. Tuned for "use as much context as the model offers"
        # — coding sessions specifically benefit from preserving full file
        # bodies across many turns. Falls back to the original tight
        # defaults when the backend doesn't report context_limit.
        ctx_tokens = int(getattr(backend, "context_limit", 0) or 0)
        ctx_chars = chars_for_tokens(
            ctx_tokens, "code"
        )  # conservative code-aware budget
        if ctx_tokens > 0:
            # 1 turn = 1 user + 1 assistant msg. ~2_000 tokens per pair
            # (the average after the assistant's tool round-trips collapse
            # to the final answer between turns) means at 128K we keep
            # ~64 turns = 128 messages — effectively a full session.
            self.max_history_turns = max(30, ctx_tokens // 2_000)
            # Single tool result allowed to occupy up to ~20% of the window.
            # That fits a typical large source file (e.g. 1700-line Dart
            # widget ≈ 100K chars) without head+tail truncation.
            self._max_tool_result_chars = max(40_000, ctx_chars // 5)
            # Total prompt char budget — 85% of the window. Leaves enough
            # room for system prompt (~5%) + reply budget (~3%) + safety
            # margin. The compactor still catches anything past 75%.
            self._history_char_budget = int(ctx_chars * 0.85)
            # Token budget for the in-loop estimator. Using tokens instead
            # of raw chars avoids underestimating code-heavy prompts.
            self._history_token_budget = int(ctx_tokens * 0.85)
        else:
            self.max_history_turns = 6
            self._max_tool_result_chars = _MAX_TOOL_RESULT_CHARS_FALLBACK
            self._history_char_budget = 200_000
            self._history_token_budget = 50_000
        # Preserve the init-time ceiling so dynamic recomputation never
        # grows past it (it only shrinks when free space is tight).
        self._init_max_tool_result_chars = self._max_tool_result_chars

    # ------------------------------------------------------------------
    # Session management
    # ------------------------------------------------------------------
    def reset(self) -> None:
        self.conversation_history = []

    def import_history(self, history: List[Dict[str, Any]]) -> None:
        self._ensure_system_prompt()
        _history.import_external_history(self.conversation_history, history)

    def _ensure_system_prompt(self) -> None:
        # Load per-project agent context (.agent.md / context.md) when present.
        from ..core.project_context import load_project_context

        project_context = load_project_context(str(self.tool_registry.base_path))
        _history.ensure_system_prompt(
            self.conversation_history,
            self.tool_registry.get_system_prompt(
                project_context=project_context,
                task_mode=self.task_mode.value,
            ),
        )

    def _recompute_tool_budget(self) -> None:
        """Dynamically scale the tool-result char cap based on free space.

        Called once per iteration before the model call. If history is
        small we let tool results grow up to the init-time ceiling; if
        history is large we shrink proportionally so the prompt never
        exceeds the token budget.
        """
        ctx_tokens = int(getattr(self.backend, "context_limit", 0) or 0)
        if ctx_tokens <= 0:
            return
        used = estimate_messages_tokens(
            self.conversation_history,
            content_type="code",
            per_message_overhead=10,
        )
        free_tokens = max(0, self._history_token_budget - used)
        # Reserve 15% of free space for the model's reply + safety margin.
        alloc_tokens = int(free_tokens * 0.85)
        # Convert token allocation to chars using the code-aware multiplier.
        alloc_chars = chars_for_tokens(alloc_tokens, "code")
        # Never grow past the init-time ceiling, never drop below 12K.
        self._max_tool_result_chars = max(
            12_000,
            min(self._init_max_tool_result_chars, alloc_chars),
        )

    def _trim_history(self) -> None:
        # Token-aware trimming: derive per-message and total budgets from
        # the backend's actual context window. Using tokens instead of raw
        # chars avoids underestimating code-heavy prompts (code tokenizes
        # at ~3.0 chars/tok vs prose at ~4.0).
        ctx_tokens = int(getattr(self.backend, "context_limit", 0) or 0)
        if ctx_tokens > 0:
            # Per-message cap: ~20% of the window, generous enough for a
            # full source file while preventing one runaway message from
            # dominating the budget.
            per_msg_tokens = max(2_500, ctx_tokens // 5)
            # Use token-budget packing newest-first for accurate accounting.
            self.conversation_history = _history.trim_history_by_tokens(
                self.conversation_history,
                token_budget=self._history_token_budget,
                content_type="code",
                max_msg_tokens=per_msg_tokens,
            )
        else:
            # Fallback for backends that don't report context_limit.
            ctx_chars = chars_for_tokens(ctx_tokens, "code") if ctx_tokens > 0 else 0
            per_msg_cap = (ctx_chars // 5) if ctx_chars > 0 else _history.MAX_MSG_CHARS
            per_msg_cap = max(_history.MAX_MSG_CHARS, per_msg_cap)
            self.conversation_history = _history.trim_history(
                self.conversation_history,
                self.max_history_turns,
                max_msg_chars=per_msg_cap,
            )

    # ------------------------------------------------------------------
    # Tool-intent heuristic
    # ------------------------------------------------------------------
    def _should_escalate_chat_to_tools(self, user_input: str, model_reply: str) -> bool:
        """True when a chat-mode response should be retried in tool mode."""
        if ToolIntentDetector.needs_tools(user_input):
            return True
        if _td.parse_all_tag_tool_calls(model_reply, self.tool_registry.definitions):
            return True
        is_malformed, _ = _td.looks_like_malformed_tool_call(model_reply)
        if is_malformed:
            return True
        if _td.looks_like_refusal(model_reply):
            return True
        return False

    # ------------------------------------------------------------------
    # Main loop
    # ------------------------------------------------------------------
    def run(self, user_input: str) -> str:
        self._ensure_system_prompt()
        self._trim_history()

        # Task-flow: when the incoming user prompt is itself a
        # ``<task_action>{...}</task_action>`` envelope (sent by the
        # Flutter UI's Proceed / Retry / Skip / Abort / Replan
        # buttons), log it on stderr so the log panel mirrors the
        # manual-mode control loop. The envelope is still forwarded to
        # the model verbatim -- the model interprets the directive in
        # the context of the active task list.
        # Reset per-request task-flow flags before the action-detection
        # below so the plan-emission check (Fix 6) is in a known state.
        self._plan_emitted_this_request = False
        self._is_task_action_request = False
        if self.task_mode.is_task_flow:
            from . import task_protocol as _tp
            action_ev = _tp.parse_task_action(user_input or "")
            if action_ev is not None:
                _tp.log_task_action_received(action_ev)
                # Continuation of an existing plan: do NOT force a re-plan.
                self._is_task_action_request = True

        # Detect a bare confirmation ("Yes", "Proceed", "Do it"). When found
        # AND there's a prior assistant turn to inherit context from, treat
        # the request as the action-intent of that prior plan — otherwise
        # the model interprets "Yes" as open-ended exploration and burns
        # the whole iteration budget reading files.
        has_prior_assistant = any(
            m.get("role") == "assistant" for m in self.conversation_history
        )
        is_followup = _is_short_followup(user_input) and has_prior_assistant

        # Treat as action-task when the user used an action verb OR is
        # confirming a prior plan. Used downstream to gate dynamic-iteration
        # extension and progressive pressure on read-only loops.
        self._action_intent = bool(
            is_followup or _ACTION_VERB_RE.search(user_input or "")
        )
        # Reset per-turn write tracking — `_files_modified` is cumulative
        # across the session for telemetry, but pressure decisions need a
        # turn-local view.
        self._writes_this_turn = 0
        self._pending_step_report = False
        self._action_pressure_nudges = 0

        use_tools = (not self.disable_tools) and ToolIntentDetector.needs_tools(
            user_input
        )
        # Force tool mode for bare confirmations — the prior plan almost
        # always required tools, and chat-mode would lose that intent.
        if is_followup and not self.disable_tools:
            use_tools = True

        if use_tools:
            decorated = _AGENT_DIRECTIVE + user_input
        else:
            decorated = user_input

        if is_followup and use_tools:
            decorated = _AGENT_DIRECTIVE + _FOLLOWUP_DIRECTIVE + user_input

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
                    thinking=self.thinking,
                    effort=self.effort,
                )
            except Exception as e:
                # Pop the just-added user turn so a retry doesn't end up
                # with two consecutive user messages, and so the failed
                # error string never leaks into model context on the next
                # turn (some models will parrot it back).
                if (
                        self.conversation_history
                        and self.conversation_history[-1].get("role") == "user"
                ):
                    self.conversation_history.pop()
                return f"Model error: {e}"
            text_clean = _td.clean_history_text(text or "")
            if self._should_escalate_chat_to_tools(user_input, text_clean):
                print(
                    "[orch] Chat-mode reply looked tool-related; retrying in tool mode.",
                    file=sys.stderr,
                )
                if (
                        self.conversation_history
                        and self.conversation_history[-1].get("role") == "user"
                ):
                    self.conversation_history[-1]["content"] = (
                            _AGENT_DIRECTIVE + user_input
                    )
                use_tools = True
            else:
                self.conversation_history.append(
                    {
                        "role": "assistant",
                        "content": text_clean,
                    }
                )
                return _td.clean_final_answer(text or "")

        refusal_retries = 0
        empty_retries = 0
        truncation_retries = 0
        cliffhanger_retries = 0
        step_report_retries = 0
        malformed_tool_retries = 0
        # Cumulative count of consecutive malformed iterations with no
        # successful tool call between them. A model that keeps emitting
        # broken syntax even after corrective feedback is unlikely to
        # recover — bail with the canned message before burning the full
        # iteration budget.
        consecutive_malformed = 0
        _MAX_CONSECUTIVE_MALFORMED = 5

        # Sliding window of canonical "(name, sorted-params)" keys for
        # tool calls already executed this turn. Used to detect the model
        # looping on the same call (a common failure mode for smaller
        # models — they fixate on one file and re-read it). When the same
        # key appears twice we warn the model; a second warning bails
        # with a synthesized recap of the tool results so far.
        recent_calls: List[str] = []
        repeat_warnings = 0
        _MAX_REPEAT_WARNINGS = 2
        _RECENT_WINDOW = 8

        # Consecutive successful idempotent-validator runs (python_check,
        # flutter_analyze, etc.). Once the model runs two of these clean,
        # the next loop catches the pattern and force-finalizes — heads off
        # the "validate forever" stalling pattern that otherwise trips the
        # repeat-call cap.
        consecutive_validations = 0

        # Total-history char budget. Derived from backend.context_limit at
        # __init__ (see self._history_char_budget); a local alias keeps the
        # in-loop logic readable.
        _HISTORY_CHAR_BUDGET = self._history_char_budget

        iteration = 0
        while iteration < self.max_iterations:
            print(f"Iteration: {iteration}", file=sys.stderr)

            # === PROGRESSIVE PRESSURE FOR READ-ONLY LOOPS ===
            # When the user asked for an action ("implement", "fix", or
            # "yes, proceed"), we expect at least one write before a final
            # answer. If the model is burning iterations on reads/searches
            # without ever editing, escalate pressure rather than waiting
            # for max-iterations to expire.
            in_read_only_loop = (
                    getattr(self, "_action_intent", False)
                    and self._writes_this_turn == 0
                    and self._successful_tool_count >= 4
            )
            if in_read_only_loop:
                if iteration >= 28:
                    print(
                        f"[orch] Action-task with no writes after "
                        f"{iteration} iterations; bailing to recap.",
                        file=sys.stderr,
                    )
                    return self._build_recap_answer(
                        reason=f"action-task stalled at iter {iteration} "
                               f"with zero writes despite "
                               f"{self._successful_tool_count} successful reads"
                    )
                if iteration >= 20 and self._action_pressure_nudges < 2:
                    self._action_pressure_nudges = 2
                    self.conversation_history.append(
                        {"role": "user", "content": _ACTION_FINAL_WARNING_DIRECTIVE}
                    )
                elif iteration >= 10 and self._action_pressure_nudges < 1:
                    self._action_pressure_nudges = 1
                    self.conversation_history.append(
                        {"role": "user", "content": _ACTION_NUDGE_DIRECTIVE}
                    )

            # === DYNAMIC ITERATION LIMIT ===
            # Extend budget proactively when progress is detected, not just at the end.
            # Check every 5 iterations and when approaching the limit.
            should_check_extension = (
                    iteration % 5 == 0  # Periodic check
                    or iteration >= self.max_iterations - 3  # Approaching limit
            )
            if should_check_extension and self.max_iterations < self._max_iteration_cap:
                # Measure progress: count successful tool calls in recent history
                recent_history = "".join(
                    [m.get("content", "") for m in self.conversation_history[-8:]]
                )
                success_count = recent_history.count('"status": "success"')
                error_count = recent_history.count('"status": "error"')

                # Distinct calls in the recent window — extending the
                # budget when the model is just repeating itself only
                # delays the inevitable bail.
                distinct_recent = len(set(recent_calls)) if recent_calls else 0

                # Read-only loop guard: if the user asked for an action
                # (implement / fix / "yes, proceed") and we've burned a
                # bunch of successful reads without writing anything, do
                # NOT extend — that just rewards the model for refusing
                # to act. Pressure (below) will steer it instead.
                read_only_loop = (
                        getattr(self, "_action_intent", False)
                        and self._writes_this_turn == 0
                        and self._successful_tool_count >= 6
                )
                if read_only_loop:
                    print(
                        f"[orch] Read-only loop on action-task | "
                        f"iter={iteration} successes={self._successful_tool_count} "
                        f"writes=0 — extension suppressed",
                        file=sys.stderr,
                    )
                    # Skip both extension branches; fall through to the
                    # rest of the iteration so pressure-injection runs.
                # Calculate extension multiplier based on progress rate
                elif (
                        success_count > 0
                        and success_count > error_count
                        and distinct_recent >= 3
                ):
                    # Good progress: extend by 5-15 based on success rate
                    extension = min(
                        5 + (success_count * 2),  # More successes = larger extension
                        self._max_iteration_cap
                        - self.max_iterations,  # Don't exceed cap
                    )
                    old_limit = self.max_iterations
                    self.max_iterations += extension
                    print(
                        f"[orch] Progress detected | iter={iteration} | "
                        f"successes={success_count} errors={error_count} | "
                        f"Extending max_iterations {old_limit} -> {self.max_iterations}",
                        file=sys.stderr,
                    )
                    iteration += 1
                    continue

                # Detect complex multi-file operations: extend more aggressively.
                # Also suppressed by the read-only-loop guard: "files touched"
                # for an action-task with zero writes is just files re-read.
                files_touched = len(
                    set(
                        re.findall(
                            r"\b[a-zA-Z_][\w/.-]*\.(?:dart|py|yaml|json|md)\b",
                            recent_history,
                        )
                    )
                )
                if (
                        not read_only_loop
                        and files_touched >= 3
                        and self._successful_tool_count >= 5
                ):
                    extension = min(20, self._max_iteration_cap - self.max_iterations)
                    old_limit = self.max_iterations
                    self.max_iterations += extension
                    print(
                        f"[orch] Complex multi-file operation detected | "
                        f"files={files_touched} | Extending max_iterations {old_limit} -> {self.max_iterations}",
                        file=sys.stderr,
                    )
                    iteration += 1
                    continue

            # Enforce the token budget: if history has grown past the
            # limit, trim older non-system messages so the next model call
            # stays within context. Token-aware trimming is more accurate
            # than raw char counting for code-heavy prompts.
            current_tokens = estimate_messages_tokens(
                self.conversation_history,
                content_type="code",
                per_message_overhead=10,
            )
            if current_tokens > self._history_token_budget:
                self.conversation_history = _history.trim_history_by_tokens(
                    self.conversation_history,
                    token_budget=self._history_token_budget,
                    content_type="code",
                    max_msg_tokens=max(2_500, self._history_token_budget // 10),
                )
                print(
                    f"[orch] History over token budget; trimmed to fit "
                    f"~{self._history_token_budget} tokens.",
                    file=sys.stderr,
                )

            # Recompute the per-tool-result char cap based on how much
            # budget is still free after trimming. This lets large file
            # bodies pass through untouched when history is small, and
            # shrinks gracefully as the session grows.
            self._recompute_tool_budget()

            try:
                text, finish_reason = self._call_model()
            except Exception as e:
                return f"Model error: {e}"

            # [stop-sequence-fix] If we requested generation to stop at
            # ``</tool>`` (see _call_model), some APIs strip the stop
            # token from the reply -- leaving an unclosed ``<tool>{...``
            # that the parser would treat as malformed. Detect that here
            # and re-append ``</tool>`` so the parser sees a complete
            # tag. To roll back this behavior, search for
            # ``[stop-sequence-fix]`` across the codebase.
            if text and _td.looks_like_unclosed_tool(text):
                text = text + "</tool>"

            # Task-flow event extraction: when in task_compliance(_auto)
            # mode, parse the reply for <tasks>/<task_status> tags and
            # broadcast them on stdout as structured JSON envelopes so
            # the Flutter side can update its task panel + DB live.
            # Tags are then stripped from the visible reply so the user
            # never sees the raw protocol noise. See
            # :mod:`common.loop.task_protocol`.
            # ``_iters_without_status`` counts consecutive iterations
            # that produced a tool call but no ``<task_status>``. Used
            # below to nudge the model when it forgets to report
            # progress and the checklist UI stays frozen.
            saw_status_this_iter = False
            if text and self.task_mode.is_task_flow:
                from . import task_protocol as _tp

                proposed = _tp.parse_tasks(text)
                if proposed:
                    _tp.emit_tasks_proposed(proposed)
                    # Fix 6: any time the model emits a plan, mark
                    # the request as "planned" so the no-plan nudge
                    # below stops firing.
                    self._plan_emitted_this_request = True
                status_events = _tp.parse_task_status(text)
                for ev in status_events:
                    _tp.emit_task_status(ev)
                if status_events:
                    saw_status_this_iter = True
                text = _tp.strip_task_tags(text)
                # Reset the no-status counter when we did see a status.
                if saw_status_this_iter:
                    self._iters_without_status = 0

                # Fix 6: in compliance(_auto) modes the FIRST iteration
                # of a brand-new request (i.e. not a continuation of a
                # prior plan via <task_action>) MUST emit a <tasks>
                # plan. If iter 0 didn't, inject a corrective nudge
                # and skip dispatch so the next iteration re-attempts.
                # The UI checklist depends on this plan -- without it
                # the panel stays empty and the user has nothing to
                # confirm.
                if (
                    iteration <= _MAX_ITERS_WITHOUT_PLAN
                    and self.task_mode.is_task_flow
                    and not self._plan_emitted_this_request
                    and not self._is_task_action_request
                ):
                    print(
                        f"[orch] iter {iteration} in {self.task_mode.value} "
                        f"mode did not emit a <tasks> plan -- injecting "
                        f"plan-first nudge",
                        file=sys.stderr,
                    )
                    self.conversation_history.append(
                        {
                            "role": "user",
                            "content": (
                                "[INTERNAL: TASK FLOW PROTOCOL is active "
                                "but you have not emitted a <tasks> plan "
                                "yet. Your NEXT reply MUST begin with a "
                                "<tasks>[{\"id\":1,\"name\":\"...\","
                                "\"description\":\"...\"}, ...]</tasks> "
                                "block enumerating every step needed for "
                                "this request. Do NOT call any tool until "
                                "the plan has been emitted. Do NOT echo "
                                "this instruction back to the user.]"
                            ),
                        }
                    )
                    iteration += 1
                    continue

            preview = (text or "").replace("\n", " ")[:800]
            print(
                f"[orch] Model reply (iter {iteration}, finish={finish_reason}, "
                f"len={len(text or '')}): {preview!r}",
                file=sys.stderr,
            )

            # Strip <think> blocks AND chat-template control tokens before
            # storing in history — they waste context and confuse the tool
            # parser. The raw `text` (with thinking intact) is still used
            # for the final answer so the Flutter UI can render the
            # reasoning section.
            text_clean = _td.clean_history_text(text or "")
            self.conversation_history.append(
                {"role": "assistant", "content": text_clean}
            )

            # Parse tool calls from the cleaned text to avoid false positives
            # when a model embeds JSON examples inside its <tool_call> block.
            tag_calls = _td.parse_all_tag_tool_calls(
                text_clean, self.tool_registry.definitions
            )

            # Drain any keys the sanitizer dropped while parsing this
            # batch of calls. If we don't surface this to the model, it
            # will silently re-emit the same call (now identical to a
            # previous one because the unknown keys vanished) and the
            # repeat-call detector will kill the turn. See fs_read.py
            # for the read_file start_line/end_line case that motivated
            # this fix.
            sanitization_drops = _td.drain_recent_drops()
            sanitized_tools = {name for name, _, _ in sanitization_drops}
            if sanitization_drops:
                drop_lines = []
                for tname, dropped, kept in sanitization_drops:
                    drop_lines.append(
                        f"  - {tname}: rejected keys {dropped}; "
                        f"the only accepted keys are {kept or '[none — see schema]'}"
                    )
                self.conversation_history.append(
                    _get_schema_feedback_directive(drop_lines)
                )

            if tag_calls:
                # Reset the consecutive-malformed guard: a parseable call
                # means the model has recovered.
                consecutive_malformed = 0
                # Reset the empty-reply counter -- the model is producing
                # actual structured output again.
                self._iters_with_empty_reply = 0

                # Task-flow no-status nudge: when we're in task_compliance(_auto)
                # mode AND the model used a tool without reporting a
                # ``<task_status>``, bump the counter. Once it crosses
                # the threshold inject a corrective user message so the
                # next iteration has explicit pressure to emit the tag.
                # We also enforce this from iteration 1+ even without
                # a tool call - the model MUST emit task_status tags.
                if self.task_mode.is_task_flow and not saw_status_this_iter:
                    self._iters_without_status += 1
                    
                    # Force status tag from iteration 1 if no plan was emitted,
                    # or from iteration 2+ after any tool call without status
                    if iteration >= 1 or (
                        iteration >= 2 and self._iters_without_status >= 1
                    ):
                        # Check if status tag is missing despite tool usage
                        if saw_status_this_iter is False and self._iters_without_status >= 1:
                            print(
                                f"[orch] Iteration {iteration} in {self.task_mode.value} "
                                f"mode without <task_status> emission -- injecting "
                                f"TASK STATUS DIRECTIVE",
                                file=sys.stderr,
                            )
                            self.conversation_history.append(
                                {
                                    "role": "user",
                                    "content": _TASK_STATUS_FORCE_DIRECTIVE,
                                }
                            )
                            self._iters_without_status = 0  # consumed by the nudge
                            continue
                    elif self._iters_without_status >= _MAX_ITERS_WITHOUT_STATUS:
                        print(
                            f"[orch] {self._iters_without_status} tool iterations "
                            f"without a <task_status> emission -- injecting "
                            f"corrective nudge",
                            file=sys.stderr,
                        )
                        self.conversation_history.append(
                            {
                                "role": "user",
                                "content": (
                                    "[INTERNAL: You have used the tool protocol "
                                    "for several iterations without emitting a "
                                    "<task_status>. The UI checklist is frozen "
                                    "because the orchestrator cannot tell which "
                                    "task is progressing. Your NEXT reply must "
                                    "include a <task_status>{\"id\":<int>,"
                                    "\"status\":\"<value>\",\"note\":\"<short>\"}"
                                    "</task_status> tag describing the work "
                                    "completed so far. Do NOT echo this "
                                    "instruction back to the user.]"
                                ),
                            }
                        )
                        self._iters_without_status = 0  # consumed by the nudge

                # --- Repeat-call detection -----------------------------
                # Same (tool, params) called more than once in the recent
                # window means the model is looping. Warn once; if it
                # happens again, bail with a recap rather than burn
                # iterations on the identical call.
                #
                # EXCEPTION: if this iteration also had keys sanitized
                # away from the SAME tool, the duplicate is an artifact
                # of stripping — the model emitted something different,
                # we just erased the difference. Don't count it as a
                # repeat; the schema-feedback message above will steer
                # the next attempt.
                repeat_keys: List[tuple] = []
                for name, params in tag_calls:
                    if name in sanitized_tools:
                        continue
                    key = (
                        f"{name}::"
                        f"{json.dumps(params, sort_keys=True, ensure_ascii=False)}"
                    )
                    if key in recent_calls:
                        repeat_keys.append((name, params, key))

                if repeat_keys:
                    repeat_warnings += 1
                    print(
                        f"[orch] Repeat tool call detected "
                        f"(warning {repeat_warnings}/{_MAX_REPEAT_WARNINGS}): "
                        f"{[(n, p) for n, p, _ in repeat_keys]}",
                        file=sys.stderr,
                    )
                    if repeat_warnings >= _MAX_REPEAT_WARNINGS:
                        print(
                            "[orch] Repeat-call cap reached; bailing with recap.",
                            file=sys.stderr,
                        )
                        return self._build_recap_answer(
                            reason=f"repeat-call cap after {repeat_warnings} "
                                   f"warnings on {[n for n, _, _ in repeat_keys]}"
                        )

                    summary = ", ".join(
                        f"{n}({json.dumps(p, ensure_ascii=False)[:120]})"
                        for n, p, _ in repeat_keys
                    )
                    self.conversation_history.append(
                        _get_repeat_call_directive(summary)
                    )
                    iteration += 1
                    continue

                for name, params in tag_calls:
                    key = (
                        f"{name}::"
                        f"{json.dumps(params, sort_keys=True, ensure_ascii=False)}"
                    )
                    recent_calls.append(key)
                    if len(recent_calls) > _RECENT_WINDOW:
                        recent_calls = recent_calls[-_RECENT_WINDOW:]

                    print(f"[orch] -> tool {name}({params})", file=sys.stderr)
                    result = self.tool_registry.execute(name, params)

                    # Track successful tool executions for dynamic iteration extension
                    if (
                            '"status": "success"' in result
                            or '"status":"success"' in result
                    ):
                        self._successful_tool_count += 1
                        # Track modified files for complexity detection
                        if name in ("write_file", "patch_file", "append_file"):
                            file_path = params.get("path", "")
                            if file_path:
                                self._files_modified.add(file_path)
                            self._writes_this_turn += 1
                            self._pending_step_report = True
                        # Track consecutive successful idempotent validators —
                        # if the model ran two of these in a row clean, it
                        # almost always wants to "make sure once more" and
                        # then trips the repeat-call cap. Cut that off here:
                        # after 2 successful validations, force the next reply
                        # to be the final answer.
                        if name in _IDEMPOTENT_VALIDATORS:
                            consecutive_validations += 1
                        else:
                            consecutive_validations = 0
                    else:
                        consecutive_validations = 0

                    # Truncate oversized tool results before they bloat the
                    # conversation history and blow the model's context window.
                    # Head+tail strategy: keep the first and last halves so the
                    # model sees both file headers/imports AND the implementation
                    # at the bottom — the middle is usually less critical.
                    max_tool_result_chars = self._max_tool_result_chars
                    display_result = result
                    if len(display_result) > max_tool_result_chars:
                        half = max_tool_result_chars // 2
                        trunc_len = len(display_result) - max_tool_result_chars
                        display_result = (
                                display_result[:half]
                                + f"\n[... {trunc_len} chars truncated from middle ...]\n"
                                + display_result[-half:]
                        )

                    # On the last two iterations force a final answer — no more tools.
                    is_last_chance = iteration >= self.max_iterations - 2
                    self.conversation_history.append(
                        _get_tool_result_followup(name, display_result, is_last_chance)
                    )

                # Validation-stall guard: if the model just ran the Nth+
                # idempotent validator clean in a row, replace the generic
                # follow-up with a hard finalize directive. This catches the
                # "I just ran python_check, let me run it once more to be
                # sure" pattern before the repeat-call cap fires.
                if (
                        consecutive_validations >= _MAX_CONSECUTIVE_VALIDATIONS
                        and self.conversation_history
                        and self.conversation_history[-1].get("role") == "user"
                ):
                    print(
                        f"[orch] {consecutive_validations} clean validations "
                        f"in a row; forcing finalize.",
                        file=sys.stderr,
                    )
                    self.conversation_history[-1]["content"] = (
                        _get_validation_complete_directive(consecutive_validations)[
                            "content"
                        ]
                    )
                iteration += 1
                continue

            # Empty-cleaned-reply guard: the raw reply may have been
            # large (reasoning, hallucinated transcript, task tags)
            # but after stripping nothing remained. Without this
            # guard the loop interprets the empty text as "no tool
            # call, also no final answer" and silently loops; the
            # user just sees empty chat bubbles.
            if not text_clean.strip():
                self._iters_with_empty_reply += 1
                print(
                    f"[orch] WARNING: cleaned reply empty after stripping "
                    f"(iter={iteration}, "
                    f"streak={self._iters_with_empty_reply}). The raw model "
                    f"reply was {len(text or '')} chars; everything was "
                    f"reasoning / task tags / fake transcript.",
                    file=sys.stderr,
                )
                # Fix 8b: plan-emitted-but-no-work nudge. When task-flow
                # mode is active AND a <tasks> plan was already emitted
                # for this request AND the model just produced an empty
                # reply (typically only ``<tasks>...</tasks>`` that got
                # stripped, or a re-plan that the user did NOT ask for),
                # inject a targeted directive. The generic empty-reply
                # nudge below is too vague for this case -- the model
                # would just re-emit yet another plan and stall again.
                # Fires immediately (no streak) because every wasted
                # iteration here costs a full round-trip.
                if (
                    self.task_mode.is_task_flow
                    and self._plan_emitted_this_request
                ):
                    print(
                        f"[orch] plan was already emitted but reply has no "
                        f"task_status + tool -- injecting plan-then-start "
                        f"nudge",
                        file=sys.stderr,
                    )
                    self.conversation_history.append(
                        {
                            "role": "user",
                            "content": (
                                "[INTERNAL: The <tasks> plan has already "
                                "been saved by the orchestrator. Do NOT "
                                "re-emit a new <tasks> block. Your NEXT "
                                "reply must contain, in this exact order: "
                                "(1) <task_status>{\"id\":1,"
                                "\"status\":\"in_progress\",\"note\":\""
                                "<one line>\"}</task_status>, then "
                                "(2) the FIRST <tool>{...}</tool> call "
                                "needed to start task #1. Nothing else. "
                                "Do NOT echo this instruction back.]"
                            ),
                        }
                    )
                    # Reset the generic empty-reply counter so the
                    # generic nudge does not also fire on the same iter.
                    self._iters_with_empty_reply = 0
                    iteration += 1
                    continue
                if self._iters_with_empty_reply >= _MAX_ITERS_WITH_EMPTY_REPLY:
                    self.conversation_history.append(
                        {
                            "role": "user",
                            "content": (
                                "[INTERNAL: Your last reply was empty after "
                                "the orchestrator removed reasoning, task "
                                "tags, and simulated tool transcripts. Emit "
                                "ONLY the single <tool>{...}</tool> call OR "
                                "the user-facing final answer. No preamble, "
                                "no fake 'User:' / 'Assistant:' lines, no "
                                "'[INTERNAL: ...]' tags from you. Do NOT "
                                "echo this instruction back.]"
                            ),
                        }
                    )
                    self._iters_with_empty_reply = 0
                iteration += 1
                continue

            is_malformed, malformed_error = _td.looks_like_malformed_tool_call(
                text_clean
            )
            if is_malformed:
                # When the malformed error is an unclosed JSON and the reply
                # is long (>2000 chars), it's almost certainly a truncation
                # (the model ran out of generation budget mid-JSON) rather
                # than a genuine syntax error. Route it to the truncation
                # path below, which gives 10 retries with tail context
                # instead of only 2 malformed retries with generic feedback.
                # This fixes models like glm-5.2 that generate massive
                # patch_files calls and get cut off mid-JSON.
                if "Unclosed JSON" in malformed_error and len(text_clean) > 2000:
                    print(
                        f"[orch] Malformed call looks like truncation "
                        f"(unclosed JSON, {len(text_clean)} chars); "
                        f"routing to truncation path.",
                        file=sys.stderr,
                    )
                    # Fall through to truncation detection below — do NOT
                    # increment consecutive_malformed or consume a retry.
                else:
                    consecutive_malformed += 1

                    if malformed_tool_retries < 2:
                        # Still have correction retries — send feedback regardless
                        # of consecutive count. Only bail after retries are gone.
                        malformed_tool_retries += 1
                        print(
                            f"[orch] Malformed tool call detected (retry {malformed_tool_retries}): {malformed_error}",
                            file=sys.stderr,
                        )
                        print(
                            f"[orch] Unparseable reply (first 500 chars): "
                            f"{text_clean[:500]!r}",
                            file=sys.stderr,
                        )
                        self.conversation_history.append(
                            _get_malformed_directive(malformed_error)
                        )
                        iteration += 1
                        continue

                    # Retries exhausted. Hard cap on consecutive malformed runs.
                    if consecutive_malformed >= _MAX_CONSECUTIVE_MALFORMED:
                        print(
                            f"[orch] Consecutive malformed cap reached "
                            f"({consecutive_malformed}); bailing.",
                            file=sys.stderr,
                        )
                        # Skip synthesis — history contains only broken calls,
                        # not useful work; synthesis would likely fail too.
                        return _MALFORMED_GIVE_UP_MESSAGE

                    # Retries exhausted but consecutive cap not yet reached —
                    # return the direct error.
                    print(
                        f"[orch] Malformed tool call: retries exhausted. "
                        f"Error: {malformed_error}",
                        file=sys.stderr,
                    )
                    return _MALFORMED_GIVE_UP_MESSAGE

            # --- Truncation detection ---
            # The reply was cut off by max_tokens. Two shapes:
            #   1. A tool call was truncated (<tool> or JSON opened but not
            #      closed) — retry with a tool-call-specific nudge.
            #   2. A final answer was truncated (plain text, no tool syntax)
            #      — retry asking the model to continue from where it left
            #      off. This is the fix for "parts that are cutted" in long
            #      explanations: the old code always assumed a tool call,
            #      wasting retries on a continuation prompt that made no sense.
            looks_truncated = finish_reason == "length" or _td.looks_like_unclosed_tool(
                text_clean
            )
            if looks_truncated and truncation_retries < _MAX_TRUNCATION_RETRY:
                truncation_retries += 1
                # Determine whether this is a truncated tool call or a
                # truncated final answer. A tool call has <tool> tags or
                # JSON tool syntax; a final answer is plain text.
                is_tool_truncation = _td.looks_like_unclosed_tool(text_clean) or (
                    _td.parse_all_tag_tool_calls(
                        text_clean, self.tool_registry.definitions
                    )
                )
                if is_tool_truncation:
                    print(
                        f"[orch] Truncated tool call detected "
                        f"(retry {truncation_retries}).",
                        file=sys.stderr,
                    )
                    # Reuse the malformed-directive helper — a truncated
                    # tool call is functionally a malformed one, and the
                    # canonical example set helps the model recover.
                    self.conversation_history.append(
                        _get_malformed_directive(_TRUNCATED_TOOL_ERROR)
                    )
                else:
                    print(
                        f"[orch] Truncated final answer detected "
                        f"(retry {truncation_retries}).",
                        file=sys.stderr,
                    )
                    # For a truncated final answer, give the model the last
                    # ~800 chars of its own output so it can continue
                    # seamlessly instead of starting over.
                    tail = text_clean[-800:] if len(text_clean) > 800 else text_clean
                    self.conversation_history.append(
                        _get_truncated_answer_directive(tail)
                    )
                iteration += 1
                continue

            # No tool call. Classify the response.
            if _td.looks_like_refusal(text_clean) and refusal_retries < 2:
                refusal_retries += 1
                print(
                    f"[orch] Refusal detected (retry {refusal_retries}).",
                    file=sys.stderr,
                )
                self.conversation_history.append(
                    {"role": "user", "content": _REFUSAL_DIRECTIVE}
                )
                iteration += 1
                continue

            if not text_clean and empty_retries < 1:
                empty_retries += 1
                self.conversation_history.append(
                    {"role": "user", "content": _EMPTY_REPLY_DIRECTIVE}
                )
                iteration += 1
                continue

            # Cliffhanger detection: replies like "Now I'll examine X" or
            # "Would you like me to proceed with the next step?" hand the
            # work back to the user mid-task. The system prompt forbids
            # them, but instruct-tuned models (qwen-coder especially)
            # emit them anyway. Catch the obvious shapes here and feed
            # the model a hard nudge instead of returning the stub to
            # the user. Two retries, then give up — we don't want to
            # loop forever if the model genuinely has nothing more to
            # do but phrases its conclusion awkwardly.
            if cliffhanger_retries < 2 and self._looks_like_cliffhanger(text_clean):
                cliffhanger_retries += 1
                print(
                    f"[orch] Cliffhanger reply detected "
                    f"(retry {cliffhanger_retries}); nudging model to "
                    f"continue autonomously.",
                    file=sys.stderr,
                )
                self.conversation_history.append(
                    {"role": "user", "content": _CLIFFHANGER_DIRECTIVE}
                )
                iteration += 1
                continue

            # Step-report enforcement: after a write/patch/append, the model
            # must include a STEP REPORT in its final answer. If missing,
            # nudge and retry.
            # In task compliance modes, step reports are MANDATORY
            # and enforced more strictly - the model MUST emit step reports
            # in task_compliance and task_compliance_auto modes
            is_in_step_report_mode = (
                self.task_mode.is_task_flow  # Task compliance modes
                and self._writes_this_turn > 0
            )
            
            if (
                self._pending_step_report
                and step_report_retries < 2
                and not self._looks_like_step_report(text_clean)
            ) or (
                is_in_step_report_mode
                and step_report_retries < 2
                and not self._looks_like_step_report(text_clean)
            ):
                step_report_retries += 1
                mode_note = " (TASK COMPLIANCE MODE - MANDATORY)" if is_in_step_report_mode else ""
                print(
                    f"[orch] Missing step report after write "
                    f"(retry {step_report_retries}){mode_note}; nudging model.",
                    file=sys.stderr,
                )
                self.conversation_history.append(
                    {"role": "user", "content": _STEP_REPORT_DIRECTIVE}
                )
                iteration += 1
                continue

            # Reset the flag after a successful step report or after giving up.
            self._pending_step_report = False

            # Otherwise treat as final answer.
            return _td.clean_final_answer(text or "")

        # If we reach here, we've exhausted all iterations without a final answer.
        print(
            "[orch] Max iterations reached. Saving session to session_dump.json",
            file=sys.stderr,
        )
        try:
            with open("session_dump.json", "w", encoding="utf-8") as f:
                json.dump(self.conversation_history, f, indent=2)
        except Exception as e:
            print(f"[orch] Failed to save session: {e}", file=sys.stderr)

        return self._build_recap_answer(
            reason=f"max iterations ({self.max_iterations}) reached without "
                   f"a synthesized answer"
        )

    # ------------------------------------------------------------------
    # Recap synthesis (used when the loop has to bail)
    # ------------------------------------------------------------------
    @staticmethod
    def _strip_internal_marker(body: str) -> str:
        """Drop the trailing `[INTERNAL: ...]` directive we appended to
        the tool-result follow-up message; the user shouldn't see it."""
        idx = body.find("[INTERNAL:")
        if idx == -1:
            return body
        return body[:idx].rstrip()

    def _attempt_synthesis(self) -> Optional[str]:
        """Make one last non-tool model call asking for a final answer.

        Returns the cleaned text on success, or None when the call fails
        / returns something that still looks like a tool attempt. The
        caller falls back to the raw-result recap when this returns None.
        """
        # Defensive copy so we don't pollute the live history with the
        # synthesis directive (the next turn shouldn't see it).
        synth_history = list(self.conversation_history)
        synth_history.append({"role": "user", "content": _SYNTHESIS_DIRECTIVE})

        try:
            text, _ = self.backend.chat(
                messages=synth_history,
                max_tokens=self.max_tokens,
                temperature=self.temperature,
                tools=None,
                thinking=self.thinking,
                effort=self.effort,
            )
        except Exception as e:  # noqa: BLE001
            print(f"[orch] Synthesis call failed: {e}", file=sys.stderr)
            return None

        raw_len = len(text or "")
        cleaned = _td.clean_final_answer(text or "").strip()
        if not cleaned:
            print(
                f"[orch] Synthesis returned empty text "
                f"(raw_len={raw_len}); falling back to raw recap.",
                file=sys.stderr,
            )
            return None

        # Reject replies that are still trying to call tools — we asked
        # for plain text, anything else is the same failure mode under
        # a different costume.
        if _td.parse_all_tag_tool_calls(cleaned, self.tool_registry.definitions):
            print(
                f"[orch] Synthesis reply still contained tool calls "
                f"(len={len(cleaned)}); falling back to raw recap.",
                file=sys.stderr,
            )
            return None

        is_malformed, _ = _td.looks_like_malformed_tool_call(cleaned)
        if is_malformed:
            print(
                f"[orch] Synthesis reply looks like a malformed tool "
                f"call (len={len(cleaned)}); falling back to raw recap.",
                file=sys.stderr,
            )
            return None

        print(
            f"[orch] Synthesis succeeded (raw_len={raw_len}, "
            f"clean_len={len(cleaned)}).",
            file=sys.stderr,
        )
        return cleaned

    # Cliffhanger phrases the model uses to hand work back to the user
    # mid-task. Match generously — the model paraphrases. We accept some
    # false positives because the cost is just one extra iteration; the
    # cost of returning a stub to the UI is the user typing "continue"
    # again like they're herding a 9-year-old.
    _CLIFFHANGER_RE = re.compile(
        r"\b(?:"
        # explicit confirmation requests
        r"would\s+you\s+like\s+me\s+to\s+(?:proceed|continue|move|go|start|next)"
        r"|shall\s+i\s+(?:proceed|continue|move|go|start)"
        r"|should\s+i\s+(?:now|next|proceed|continue)"
        r"|(?:are\s+you\s+)?ready\s+to\s+proceed"
        r"|let\s+me\s+know\s+if\s+(?:you|i|we)"
        r"|want\s+me\s+to\s+(?:keep|continue|proceed)"
        r"|do\s+you\s+want\s+me\s+to\s+(?:proceed|continue|move|go)"
        r"|(?:i'?ll|i\s+will|i\s+can)\s+wait\s+for\s+your\s+(?:input|confirmation|approval|go)"
        r"|please\s+confirm\s+(?:if|whether|to)"
        # announce-without-doing stubs ("now I'll examine X" / "let me check Y")
        # only flag when the message is short — long messages with these
        # phrases usually do also include real content / a tool call.
        r")\b",
        re.IGNORECASE,
    )

    _ANNOUNCE_STUB_RE = re.compile(
        r"^(?:\s*)(?:"
        r"now\s+i'?ll|"
        r"let\s+me\s+(?:examine|read|check|look\s+(?:at|into)|continue|proceed|see|verify|inspect|review|analyze|investigate|explore|search|scan)|"
        r"i'?ll\s+(?:examine|read|check|look\s+(?:at|into)|continue|proceed|see|verify|inspect|review|analyze|investigate|explore|search|scan|now)|"
        r"next,?\s+i'?ll|"
        r"next,?\s+let\s+me"
        r")\b",
        re.IGNORECASE,
    )

    _STEP_REPORT_MARKER_RE = re.compile(
        r"^\s*[_*]*STEP\s+REPORT[_*]*\s*$",
        re.IGNORECASE | re.MULTILINE,
        )

    def _looks_like_step_report(self, text: str) -> bool:
        """True when the text contains the mandatory step-report marker."""
        if not text:
            return False
        return bool(self._STEP_REPORT_MARKER_RE.search(text))

    def _looks_like_cliffhanger(self, text: str) -> bool:
        """True when a plain-text reply hands work back to the user
        instead of either calling another tool or finishing the task.

        Two shapes:
          * explicit confirmation request ("Would you like me to proceed
            with step 2?") — always cliffhanger.
          * announce-stub ("Now I'll examine the executor.") with no
            tool call and very little body — model promised work but
            stopped. Long messages that contain these phrases AND real
            content are not flagged.
        """
        if not text:
            return False
        stripped = text.strip()
        if not stripped:
            return False

        if self._CLIFFHANGER_RE.search(stripped):
            return True

        # Short announce-stubs only. A long final answer that happens
        # to start with "Let me explain..." is fine.
        if len(stripped) <= 200 and self._ANNOUNCE_STUB_RE.search(stripped):
            return True

        return False

    def _build_recap_answer(self, reason: str = "") -> str:
        """Produce a final answer when the loop has to abandon.

        Tries hardest to give the user something useful, in this order:
          1. Ask the model for a final synthesis using everything already
             in history (one non-tool call).
          2. If that fails, stitch the last ~6 tool results together so
             the user at least sees what was learned.
          3. If no tool results exist either, return a short error.
        """
        # 1. Synthesis attempt.
        synthesized = self._attempt_synthesis()
        if synthesized:
            return synthesized

        # 2. Raw recap fallback. Format as readable markdown so the
        # user sees a coherent summary instead of a JSON dump.
        results: List[str] = []
        for msg in self.conversation_history:
            if msg.get("role") != "user":
                continue
            content = msg.get("content", "")
            if not content.startswith("Tool `"):
                continue

            split = content.split("\n", 1)
            header = split[0].rstrip(":")
            body = split[1] if len(split) > 1 else ""
            body = self._strip_internal_marker(body).strip()

            # Try to pull the human-meaningful field out of the JSON
            # tool envelope so the recap shows the actual content
            # instead of `{"status": "success", "content": "..."}`.
            pretty_body = self._extract_tool_payload(body)

            # Bound each result so the recap doesn't itself blow
            # context. 1500 chars (~3x the old 600) is enough for a
            # useful snippet of a file/search result without dumping
            # the whole 100 KB.
            if len(pretty_body) > 1500:
                pretty_body = pretty_body[:1500].rstrip() + "\n… (truncated)"

            results.append(f"### {header}\n\n```\n{pretty_body}\n```")

        prefix_lines = [
            "**I couldn't compose a single synthesized answer"
            + (f" ({reason})" if reason else "")
            + ".**",
            "",
            ]

        if not results:
            return "\n".join(prefix_lines) + (
                "No tool results were collected before bailing — the request "
                "may be too ambiguous, or the model may not support tool use. "
                "Try rephrasing or use a different model."
            )

        # Most recent results are usually the most relevant; cap at 6.
        # Dedupe consecutive identical results — six empty searches in a
        # row add no information and bury anything useful that came
        # before.
        deduped: List[str] = []
        for r in results:
            if not deduped or deduped[-1] != r:
                deduped.append(r)
        if len(deduped) > 6:
            deduped = deduped[-6:]

        return (
                "\n".join(prefix_lines)
                + "Here's a recap of what I found while investigating:\n\n"
                + "\n\n".join(deduped)
        )

    @staticmethod
    def _extract_tool_payload(body: str) -> str:
        """Pull the human-readable field out of a JSON tool envelope.

        Tool results land in history as ``{"status": "...", "content":
        "...", ...}``. Dumping that JSON verbatim into the recap is
        what made past bailouts unreadable. Try to surface ``content``
        / ``matches`` / ``message`` / ``tree`` directly.
        """
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
                return "\n".join(str(v) for v in value[:50])

        return body

    # ------------------------------------------------------------------
    # Backend call w/ retry + circuit breaker
    # ------------------------------------------------------------------
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
                # [stop-sequence-fix] Pass ``</tool>`` as a stop
                # sequence so the model cannot generate past the first
                # tool call. Some models (deepseek-v4-pro on Ollama
                # cloud, etc.) hallucinate an entire fake transcript of
                # ``User: Tool returned: ... Assistant: ...`` turns
                # after the real tool tag if not stopped; the
                # orchestrator then dispatches the hallucinated calls
                # and loops forever. With the stop sequence the model
                # emits one call, we execute it, the next iteration
                # gives the model real tool results, and it can either
                # call another tool or produce a final answer (plain
                # text, no ``<tool>`` -> existing final-answer path
                # triggers). The reply truncation (missing closing
                # ``</tool>``) is repaired in the caller above.
                #
                # ROLLBACK: drop the ``stop=`` kwarg from this call.
                #
                # Multiple stop strings: not every provider honors
                # ``</tool>`` (Ollama Cloud + nemotron-* notably do
                # not). Adding the speaker markers that the model
                # hallucinates lets us catch the failure via a
                # different stop sequence -- whichever one the
                # provider actually respects fires first.
                result = self.backend.chat(
                    messages=self.conversation_history,
                    max_tokens=self.max_tokens,
                    temperature=self.temperature,
                    tools=self.tool_registry.definitions,
                    stop=[
                        "</tool>",
                        "\nUser:",
                        "\nAssistant:",
                        "\n[INTERNAL:",
                    ],
                    thinking=self.thinking,
                    effort=self.effort,
                )
                # Successful call: reset the circuit breaker failure count.
                self._model_circuit_breaker.record_success()
                return result
            except Exception as e:  # noqa: BLE001 - broad by design
                last_exc = e
                if not self._is_retryable_error(e):
                    # Auth errors, malformed input, Ollama connection refused,
                    # etc. Do not retry -- but still count as a failure.
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
