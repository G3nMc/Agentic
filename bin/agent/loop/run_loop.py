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
from ..utils.token_estimator import chars_for_tokens, estimate_tokens, estimate_messages_tokens

# Default cap on tool-result chars. Used as a floor when the backend
# doesn't expose a context_limit; the Orchestrator scales this up at
# runtime via ``self._max_tool_result_chars`` so a 128K cloud model
# isn't throttled by the 12K value sized for 8K Ollama.
_MAX_TOOL_RESULT_CHARS_FALLBACK = 12_000

# Idempotent validation tools. Calling these more than twice in a row
# without intervening edits almost always means the model is stalling
# rather than making progress — we nudge it to finalize before the
# repeat-call detector trips and bails the whole turn.
_IDEMPOTENT_VALIDATORS = frozenset({
    "python_check", "python_lint", "python_test",
    "flutter_analyze", "flutter_test",
    "git_status", "git_diff", "git_log",
})
_MAX_CONSECUTIVE_VALIDATIONS = 2

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
        action_words = ("proceed", "continue", "go", "do it", "next", "step", "follow", "execute", "run", "implement")
        if not any(word in lower_text for word in action_words):
            return True
    if _FOLLOWUP_RE.match(text):
        return True
    stripped = text.strip()
    return len(stripped) <= 25 and not any(
        m in stripped.lower() for m in (".dart", ".py", "lib/", "bin/", "git ")
    )


_FOLLOWUP_DIRECTIVE = (
    "[CONTEXT: This is a confirmation reply. The user is confirming the plan "
    "from your IMMEDIATELY PRECEDING assistant turn. Execute the FIRST "
    "concrete action from that plan now. Do NOT re-explain the plan. Do NOT "
    "re-research the codebase if you already have enough context. If the "
    "plan involves editing files, START EDITING with write_file/patch_file. "
    "If you genuinely need to read one more file first, read EXACTLY ONE, "
    "then act.]\n\n"
)


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
    ):
        self.backend = backend
        # When True, every request is routed as a plain chat call — the
        # tool-decision heuristic and the tool loop are bypassed. Useful
        # for reasoning-only models (phi-4, plain Mistral, etc.) that
        # can't emit valid tool calls.
        self.disable_tools = disable_tools
        # Expose model_id for logging/diagnostics; both backends carry one.
        self.model_id = getattr(backend, "model_id", "(unknown)")
        self.tool_registry = ToolRegistry(base_path=base_path,
                                          security_config=security_config,
                                          path_filter=path_filter)
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
        ctx_chars = chars_for_tokens(ctx_tokens, "code")  # conservative code-aware budget
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

    # ------------------------------------------------------------------
    # Session management
    # ------------------------------------------------------------------
    def reset(self) -> None:
        self.conversation_history = []

    def import_history(self, history: List[Dict[str, Any]]) -> None:
        self._ensure_system_prompt()
        _history.import_external_history(self.conversation_history, history)

    def _ensure_system_prompt(self) -> None:
        _history.ensure_system_prompt(
            self.conversation_history,
            self.tool_registry.get_system_prompt(),
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
    # Short reminder prepended to the first user turn. Many HF-router providers
    # silently drop the `system` role (Qwen via hyperbolic is a known offender)
    # so embedding the contract in the user message guarantees the model sees
    # it. Kept short so small Ollama models don't waste prompt-eval time.
    # Injected only when the request is clearly a code/file task.
    _TOOL_REMINDER = (
        "[You have filesystem tools available. "
        "If this request needs file access or a command, emit ONE tool call: "
        '<tool>{"tool":"NAME","parameters":{...}}</tool>. '
        "No explanation before or after it. Prefer dedicated tools "
        "(read_file/search_in_files/list_files/flutter_analyze/python_check/"
        "python_lint/python_test/git_*) and use run_command only as a fallback. "
        "Keep the JSON valid; prefer single quotes inside shell commands. "
        "Otherwise reply normally.]\n\n"
    )

    # Patterns that indicate file/code intent — trigger tool-enabled mode.

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
        self._action_pressure_nudges = 0

        use_tools = (not self.disable_tools) and ToolIntentDetector.needs_tools(user_input)
        # Force tool mode for bare confirmations — the prior plan almost
        # always required tools, and chat-mode would lose that intent.
        if is_followup and not self.disable_tools:
            use_tools = True

        if use_tools:
            decorated = self._TOOL_REMINDER + user_input
        else:
            decorated = user_input

        if is_followup and use_tools:
            decorated = self._TOOL_REMINDER + _FOLLOWUP_DIRECTIVE + user_input

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
                # Pop the just-added user turn so a retry doesn't end up
                # with two consecutive user messages, and so the failed
                # error string never leaks into model context on the next
                # turn (some models will parrot it back).
                if self.conversation_history and \
                        self.conversation_history[-1].get("role") == "user":
                    self.conversation_history.pop()
                return f"Model error: {e}"
            text_clean = _td.clean_history_text(text or "")
            if self._should_escalate_chat_to_tools(user_input, text_clean):
                print(
                    "[orch] Chat-mode reply looked tool-related; retrying in tool mode.",
                    file=sys.stderr,
                )
                if self.conversation_history and \
                        self.conversation_history[-1].get("role") == "user":
                    self.conversation_history[-1]["content"] = (
                            self._TOOL_REMINDER + user_input
                    )
                use_tools = True
            else:
                self.conversation_history.append({
                    "role": "assistant",
                    "content": text_clean,
                })
                return _td.clean_final_answer(text or "")

        refusal_retries = 0
        empty_retries = 0
        truncation_retries = 0
        cliffhanger_retries = 0
        malformed_tool_retries = 0
        # Cumulative count of consecutive malformed iterations with no
        # successful tool call between them. A model that keeps emitting
        # broken syntax even after corrective feedback is unlikely to
        # recover — bail with the canned message before burning the full
        # iteration budget.
        consecutive_malformed = 0
        _MAX_CONSECUTIVE_MALFORMED = 2

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
                    self.conversation_history.append({
                        "role": "user",
                        "content": (
                            "[FINAL WARNING] You have used 20+ iterations "
                            "reading files but have written nothing. The "
                            "request asked for an action.\n"
                            "Your IMMEDIATE next message MUST be either:\n"
                            "  1) A single write_file / patch_file / "
                            "append_file tool call, OR\n"
                            "  2) Your final plain-text answer (no more "
                            "tool calls).\n"
                            "Stop researching. Act or answer."
                        ),
                    })
                elif iteration >= 10 and self._action_pressure_nudges < 1:
                    self._action_pressure_nudges = 1
                    self.conversation_history.append({
                        "role": "user",
                        "content": (
                            "[NUDGE] You have read several files but "
                            "have not modified anything. The original "
                            "request asked for an action (implementing "
                            "a change). Either:\n"
                            "  1) Make a write_file / patch_file / "
                            "append_file call NOW, or\n"
                            "  2) Give your final plain-text answer if "
                            "the task is already complete.\n"
                            "Avoid more read_file/search_in_files calls "
                            "unless strictly necessary."
                        ),
                    })

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
                elif (success_count > 0
                        and success_count > error_count
                        and distinct_recent >= 3):
                    # Good progress: extend by 5-15 based on success rate
                    extension = min(
                        5 + (success_count * 2),  # More successes = larger extension
                        self._max_iteration_cap - self.max_iterations  # Don't exceed cap
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
                files_touched = len(set(re.findall(r'\b[a-zA-Z_][\w/.-]*\.(?:dart|py|yaml|json|md)\b', recent_history)))
                if (not read_only_loop
                        and files_touched >= 3
                        and self._successful_tool_count >= 5):
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

            try:
                text, finish_reason = self._call_model()
            except Exception as e:
                return f"Model error: {e}"

            preview = (text or "").replace("\n", " ")[:800]
            print(f"[orch] Model reply (iter {iteration}, finish={finish_reason}, "
                  f"len={len(text or '')}): {preview!r}", file=sys.stderr)

            # Strip <think> blocks AND chat-template control tokens before
            # storing in history — they waste context and confuse the tool
            # parser. The raw `text` (with thinking intact) is still used
            # for the final answer so the Flutter UI can render the
            # reasoning section.
            text_clean = _td.clean_history_text(text or "")
            self.conversation_history.append({"role": "assistant", "content": text_clean})

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
                self.conversation_history.append({
                    "role": "user",
                    "content": (
                        "[SCHEMA FEEDBACK] Your last tool call(s) included "
                        "parameters that aren't part of the tool's schema. "
                        "Those keys were stripped before execution:\n"
                        + "\n".join(drop_lines)
                        + "\n\nDo NOT re-emit the same call — it would be "
                        "identical to one you already ran. Either call the "
                        "tool again with ONLY the accepted keys (changing "
                        "the values that were in the rejected keys to "
                        "supported alternatives), pick a different tool, "
                        "or give your final answer."
                    ),
                })

            if tag_calls:
                # Reset the consecutive-malformed guard: a parseable call
                # means the model has recovered.
                consecutive_malformed = 0

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
                    self.conversation_history.append({
                        "role": "user",
                        "content": (
                            f"You already called: {summary} earlier this turn. "
                            "Calling the same tool with the same arguments will "
                            "return the same result. Either:\n"
                            "  1. Call a DIFFERENT tool, or\n"
                            "  2. Call the same tool with DIFFERENT arguments, or\n"
                            "  3. Give your final plain-text answer to the user "
                            "now (no more tool calls).\n"
                            "Pick one."
                        ),
                    })
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
                    if '"status": "success"' in result or '"status":"success"' in result:
                        self._successful_tool_count += 1
                        # Track modified files for complexity detection
                        if name in ("write_file", "patch_file", "append_file"):
                            file_path = params.get("path", "")
                            if file_path:
                                self._files_modified.add(file_path)
                            self._writes_this_turn += 1
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
                    if is_last_chance:
                        follow_up = (
                            f"Tool `{name}` returned:\n{display_result}\n\n"
                            "[INTERNAL: FINAL ANSWER REQUIRED. Do NOT call any more tools. "
                            "Write only your plain-text answer to the user now. "
                            "Do NOT echo this instruction back to the user.]"
                        )
                    else:
                        follow_up = (
                            f"Tool `{name}` returned:\n{display_result}\n\n"
                            "[INTERNAL: Continue. Either call another tool or give the final answer. "
                            "Do NOT echo this instruction back to the user.]"
                        )
                    self.conversation_history.append({"role": "user", "content": follow_up})

                # Validation-stall guard: if the model just ran the Nth+
                # idempotent validator clean in a row, replace the generic
                # follow-up with a hard finalize directive. This catches the
                # "I just ran python_check, let me run it once more to be
                # sure" pattern before the repeat-call cap fires.
                if (consecutive_validations >= _MAX_CONSECUTIVE_VALIDATIONS
                        and self.conversation_history
                        and self.conversation_history[-1].get("role") == "user"):
                    print(
                        f"[orch] {consecutive_validations} clean validations "
                        f"in a row; forcing finalize.",
                        file=sys.stderr,
                    )
                    self.conversation_history[-1]["content"] = (
                        "[VALIDATION COMPLETE] You have run "
                        f"{consecutive_validations} idempotent validators "
                        "(python_check / flutter_analyze / etc.) clean in a "
                        "row. The work is done.\n"
                        "Your IMMEDIATE next message MUST be the final "
                        "plain-text answer to the user — a 2-3 sentence "
                        "summary of what was changed and that validation "
                        "passed.\n"
                        "Do NOT call another validator. Do NOT call any "
                        "tool. No <tool> tags. Just the answer."
                    )
                iteration += 1
                continue

            is_malformed, malformed_error = _td.looks_like_malformed_tool_call(text_clean)
            if is_malformed:
                consecutive_malformed += 1
                # Hard cap: even within the per-call retry budget, if the
                # model keeps producing malformed calls back-to-back, bail
                # before consuming dozens of iterations.
                if consecutive_malformed >= _MAX_CONSECUTIVE_MALFORMED:
                    print(
                        f"[orch] Consecutive malformed cap reached "
                        f"({consecutive_malformed}); bailing.",
                        file=sys.stderr,
                    )
                    return self._build_recap_answer(
                        reason="model emitted malformed tool calls repeatedly"
                    )
            if is_malformed and malformed_tool_retries < 2:
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
                self.conversation_history.append({
                    "role": "user",
                    "content": (
                        f"Your previous reply attempted a tool call but the "
                        f"format was invalid. {malformed_error}\n"
                        "Reply with EXACTLY ONE valid tool call on a single "
                        "line in this format:\n"
                        '<tool>{"tool":"NAME","parameters":{...}}</tool>\n'
                        "No explanation, no markdown, no backticks. Keep the "
                        "JSON valid. If a shell command contains quotes, "
                        "prefer single quotes inside the command string."
                    ),
                })
                iteration += 1
                continue

            # If malformed but retries exhausted, do NOT treat as final answer.
            # Return an error message instead of leaking broken tool-call syntax.
            if is_malformed:
                print(
                    f"[orch] Malformed tool call: retries exhausted. "
                    f"Error: {malformed_error}",
                    file=sys.stderr,
                )
                return (
                    "The model failed to emit a valid tool call after multiple "
                    "attempts. The request may be too ambiguous or the model may "
                    "not support tool-use. Try rephrasing your request or using "
                    "a different model."
                )

            # --- Truncation detection ---
            # The reply claims to start a tool call (`<tool>` or fenced JSON)
            # but was cut off by max_tokens before the matching `</tool>` /
            # closing brace arrived. Without this branch we'd dump the raw
            # half-written JSON back to the UI.
            looks_truncated = (
                    finish_reason == "length"
                    or _td.looks_like_unclosed_tool(text_clean)
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
                iteration += 1
                continue

            # No tool call. Classify the response.
            if _td.looks_like_refusal(text_clean) and refusal_retries < 2:
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
                iteration += 1
                continue

            if not text_clean and empty_retries < 1:
                empty_retries += 1
                self.conversation_history.append({
                    "role": "user",
                    "content": "Your reply was empty. Emit a single "
                               '<tool>{"tool":"...","parameters":{...}}</tool> '
                               "call or the final plain-text answer.",
                })
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
            if (
                cliffhanger_retries < 2
                and self._looks_like_cliffhanger(text_clean)
            ):
                cliffhanger_retries += 1
                print(
                    f"[orch] Cliffhanger reply detected "
                    f"(retry {cliffhanger_retries}); nudging model to "
                    f"continue autonomously.",
                    file=sys.stderr,
                )
                self.conversation_history.append({
                    "role": "user",
                    "content": (
                        "[AUTONOMY] Your previous reply ended with a "
                        "cliffhanger or a request for confirmation. The "
                        "user already approved the work — do NOT ask "
                        "again. Your IMMEDIATE next message must be "
                        "either:\n"
                        "  1. A tool call performing the next concrete "
                        "step (a <tool>...</tool> tag), OR\n"
                        "  2. A real final answer that summarizes what "
                        "you completed (no \"would you like me to...\", "
                        "no \"shall I...\", no \"let me continue...\").\n"
                        "Do not announce intent without acting. Do not "
                        "split the remaining work across more user "
                        "turns."
                    ),
                })
                iteration += 1
                continue

            # Otherwise treat as final answer.
            return _td.clean_final_answer(text or "")

        # If we reach here, we've exhausted all iterations without a final answer.
        print("[orch] Max iterations reached. Saving session to session_dump.json",
              file=sys.stderr)
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

    # Directive injected as a final user turn before the synthesis call.
    # Tells the model to stop tool-using and write the answer (or ask one
    # clarifying question) using only what's already in history. Coding-
    # aware: explicitly asks for a recap of files modified + validation
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

    def _attempt_synthesis(self) -> Optional[str]:
        """Make one last non-tool model call asking for a final answer.

        Returns the cleaned text on success, or None when the call fails
        / returns something that still looks like a tool attempt. The
        caller falls back to the raw-result recap when this returns None.
        """
        # Defensive copy so we don't pollute the live history with the
        # synthesis directive (the next turn shouldn't see it).
        synth_history = list(self.conversation_history)
        synth_history.append({
            "role": "user",
            "content": self._SYNTHESIS_DIRECTIVE,
        })

        try:
            text, _ = self.backend.chat(
                messages=synth_history,
                max_tokens=self.max_tokens,
                temperature=self.temperature,
                tools=None,
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
        if _td.parse_all_tag_tool_calls(
                cleaned, self.tool_registry.definitions
        ):
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
        r"let\s+me\s+(?:examine|read|check|look\s+at|continue|proceed|see|verify|inspect|review)|"
        r"i'?ll\s+(?:examine|read|check|look\s+at|continue|proceed|see|verify|inspect|review|now)|"
        r"next,?\s+i'?ll|"
        r"next,?\s+let\s+me"
        r")\b",
        re.IGNORECASE,
    )

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
        if len(stripped) <= 400 and self._ANNOUNCE_STUB_RE.search(stripped):
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
