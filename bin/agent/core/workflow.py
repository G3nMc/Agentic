"""Workflow dispatcher — replaces the single-agent run-loop in multi-agent mode.

Hierarchy::

    Router (cheapest, gatekeeper)
       │
       ├── trivial  ────────────▶  Executor.run_no_tools  ──▶  final answer
       │
       └── reasoning | tool
              │
              └── Shaper (once per workflow)
                       │
                       ▼
                   Reasoner ◄──┐
                       │        │ tool results
                       ▼        │
                  tool_calls?   │
                    ├── yes ───▶Executor.run ──┘
                    └── no  ───▶ final answer

The dispatcher owns the loop, the Reasoner owns the orchestration inside
the loop. Maximum iterations are capped so a misbehaving Reasoner can't
chew through quota indefinitely.
"""
from __future__ import annotations

import concurrent.futures
import json
import logging
import re
import sys
import time
import uuid
from typing import Any, Dict, List, Optional

from .agent_config import build_agents, SecretsResolver
from .compactor import compact_if_needed
from .state import ROUTE_REASONING, ROUTE_TRIVIAL, WorkflowState
from ..loop import tool_dispatch as _td
from ..policy import SecurityConfig
from ..tools.registry import ToolRegistry


_WRITE_TOOLS = frozenset({"write_file", "append_file", "patch_file"})

# Short confirmations / continuations that lack standalone meaning. When the
# user sends one of these on a follow-up turn, the literal text is useless as
# a spec — we need the shaper to re-shape with conversation history. Match
# against the WHOLE message (with optional trailing punctuation/whitespace).
_FOLLOWUP_RE = re.compile(
    r"^\s*(?:"
    r"ok(?:ay)?(?:\s+(?:proceed|go|do\s+it|continue|good))?"
    r"|yes(?:\s+(?:proceed|go|do\s+it|continue|please))?"
    r"|sure(?:\s+(?:do\s+it|go|proceed))?"
    r"|proceed|continue|go\s+ahead|do\s+it|fix\s+it|please\s+continue"
    r")[\s!.?]*$",
    re.IGNORECASE,
)


def _is_short_followup(text: str) -> bool:
    if not text:
        return False
    if _FOLLOWUP_RE.match(text):
        return True
    # Anything ≤25 non-whitespace chars without a strong noun marker is
    # treated as needing re-shaping with history context.
    stripped = text.strip()
    return len(stripped) <= 25 and not any(
        m in stripped.lower() for m in (".dart", ".py", "lib/", "bin/", "git ")
    )

# Phrases that mark a reply as a plan/announcement rather than an actual
# action or final answer. Used both by the reasoning-loop guard and by the
# trivial-path safety net so a router misclassification can't smuggle
# "I'll run flutter analyze now" past the workflow.
_PLAN_PHRASES = (
    "i will",
    "i'll",
    "i am going to",
    "next i will",
    "let me",
    "plan:",
    "steps:",
    "approach:",
)


def _looks_like_plan(text: str) -> bool:
    if not text:
        return False
    t = text.lower()
    return any(p in t for p in _PLAN_PHRASES)
_DART_VALIDATORS = frozenset({"flutter_analyze"})
_PY_VALIDATORS = frozenset({"python_check", "python_lint", "python_test"})

# Punted-validation patterns the system prompt forbids:
#   - "you can run flutter analyze locally"
#   - "you'll need to run flutter analyze"
#   - "you will need to / you would need to / you need to run flutter analyze"
#   - "you'll have to run flutter analyze"
#   - "please run flutter analyze"
#   - "remember / don't forget to run flutter analyze"
#   - "I suggest / recommend running flutter analyze"
#   - "since flutter CLI isn't available, …"
# All matched case-insensitively.
_PUNT_LEAD = (
    r"(?:"
    # "you can/should/may/might/could/must run …"      (no "to")
    r"you\s+(?:can|should|may|might|could|must)"
    # "you'll / you will / you'd / you would (need|have|want) to run …"
    r"|you(?:'?ll|'?d|\s+(?:will|would))(?:\s+(?:need|have|want)\s+to)?"
    # "you need to / you have to run …"
    r"|you\s+(?:need|have)\s+to"
    r"|please|kindly"
    r"|remember\s+to|don'?t\s+forget\s+to"
    r"|(?:i\s+(?:suggest|recommend|advise))(?:\s+(?:that\s+)?you)?"
    r")"
)
# Match the verb stem plus any inflection: run/runs/running/ran,
# execute/executes/executing/executed, invoke/invokes/invoking/invoked, etc.
# Trailing `\w*` instead of `\b` is what catches the gerund forms the model
# loves to slip in ("by running flutter analyze locally").
_PUNT_VERB = (
    r"\b(?:ran|run|execut|invok|us|do|did|trigger|launch|fir|kick\s+off)\w*"
)
# "flutter analyze" with arbitrary spacing/backticks/dashes/underscores:
#   `flutter analyze`, "flutter_analyze", "flutter — analyze".
_DART_TOOL = r"`?\bflutter[\s`_\-]*analyze\b`?"
_PY_TOOL = r"`?\bpython[\s`_\-]*(?:check|lint|test)\b`?"

# Polite/punt-lead form: "you can run flutter analyze", "please run …", etc.
_PUNTED_DART_LEAD_RE = re.compile(
    rf"{_PUNT_LEAD}[^.\n]*?{_PUNT_VERB}[^.\n]*?{_DART_TOOL}",
    re.IGNORECASE,
)
_PUNTED_PY_LEAD_RE = re.compile(
    rf"{_PUNT_LEAD}[^.\n]*?{_PUNT_VERB}[^.\n]*?{_PY_TOOL}",
    re.IGNORECASE,
)

# Bare-imperative form the model also loves: "Run flutter analyze locally to
# verify", "Execute flutter analyze yourself", "Run `flutter analyze` on your
# machine". Anchored at sentence start, terminated by a punt-anchor word
# (locally|yourself|your machine|manually|to verify|to confirm…) so we don't
# false-positive on legitimate "I ran flutter analyze and it passed".
_PUNT_ANCHOR = (
    r"\b(?:locally|yourself|on\s+your\s+(?:end|machine|side|computer)|"
    r"manually|by\s+hand|"
    r"to\s+(?:verify|confirm|check|test|validate|ensure|make\s+sure|see))\b"
)
_PUNTED_DART_BARE_RE = re.compile(
    rf"(?:^|[.!?\n]\s*){_PUNT_VERB}[^.\n]*?{_DART_TOOL}[^.\n]*?{_PUNT_ANCHOR}",
    re.IGNORECASE | re.MULTILINE,
)
_PUNTED_PY_BARE_RE = re.compile(
    rf"(?:^|[.!?\n]\s*){_PUNT_VERB}[^.\n]*?{_PY_TOOL}[^.\n]*?{_PUNT_ANCHOR}",
    re.IGNORECASE | re.MULTILINE,
)


def _is_punted_dart(text: str) -> bool:
    return bool(_PUNTED_DART_LEAD_RE.search(text)) or bool(
        _PUNTED_DART_BARE_RE.search(text)
    )


def _is_punted_py(text: str) -> bool:
    return bool(_PUNTED_PY_LEAD_RE.search(text)) or bool(
        _PUNTED_PY_BARE_RE.search(text)
    )
# Catches the "I can't run it / it isn't available in this environment" excuse,
# which is just punting under a different mask.
_EXCUSE_RE = re.compile(
    r"(?:flutter(?:\s+cli)?|python(?:\s+cli)?)\s+(?:is(?:n'?t|\s+not)|not)\s+"
    r"(?:available|installed|accessible|reachable|present)|"
    r"(?:can'?t|cannot|unable\s+to)\s+(?:run|execute|invoke|access)\s+"
    r"(?:flutter|python)|"
    r"(?:no|without)\s+(?:access\s+to\s+)?(?:flutter|python)(?:\s+cli)?",
    re.IGNORECASE,
)


def _path_from_call(call: Dict[str, Any]) -> str:
    params = call.get("parameters") or {}
    return str(params.get("path") or params.get("destination") or "")


class Workflow:
    """Multi-agent dispatcher. Drop-in replacement for ``Orchestrator.run()``."""

    def __init__(
            self,
            agents: Dict[str, Any],
            tool_registry: ToolRegistry,
            *,
            max_iterations: int = 25,
            max_history_turns: int = 8,
            max_identical_failures: int = 10,
            iteration_timeout: float = 60.0,
            turn_timeout: float = 300.0,  # Increased from 180.0 to 300.0 seconds (5 minutes)
    ):
        self.agents = agents
        self.tool_registry = tool_registry
        self.max_iterations = max_iterations
        self._initial_max_iterations = max_iterations
        self.max_history_turns = max_history_turns
        self.max_identical_failures = max_identical_failures
        self.iteration_timeout = iteration_timeout
        self.turn_timeout = turn_timeout

        self.logger = logging.getLogger(f"{__name__}.Workflow")

        executor = self.agents.get("executor")
        if executor is not None:
            executor.tool_registry = tool_registry

        self.conversation_history: List[Dict[str, Any]] = []
        self._shaped_this_session: bool = False
        # One-time warning latch: don't spam the user with the same
        # "context window is suspiciously small" notice every iteration.
        self._small_ctx_warned: bool = False

        self.logger.info(
            "Workflow initialized | max_iterations=%s max_history_turns=%s max_identical_failures=%s agents=%s",
            self.max_iterations,
            self.max_history_turns,
            self.max_identical_failures,
            sorted(self.agents.keys()),
        )

    @property
    def model_id(self) -> str:
        reasoner = self.agents.get("reasoner")
        return getattr(reasoner, "model_id", "(unknown)")

    def reset(self) -> None:
        self.logger.info("Resetting workflow session state")
        self.conversation_history = []
        self._shaped_this_session = False

    def import_history(self, history: List[Dict[str, Any]]) -> None:
        self.logger.info("Importing history | incoming_messages=%s", len(history or []))

        before = len(self.conversation_history)

        for msg in history:
            if not isinstance(msg, dict):
                continue

            role = str(msg.get("role") or "").strip().lower()
            content = str(msg.get("content") or "")

            if role not in ("user", "assistant", "system"):
                continue
            if not content.strip():
                continue

            self.conversation_history.append({"role": role, "content": content})

        if self.conversation_history:
            self._shaped_this_session = True

        self.logger.info(
            "History import complete | before=%s after=%s shaped=%s",
            before,
            len(self.conversation_history),
            self._shaped_this_session,
        )

    def _trim_history(self) -> None:
        keep = self.max_history_turns * 2

        non_system_indexes = [
            idx for idx, msg in enumerate(self.conversation_history)
            if msg.get("role") != "system"
        ]

        if len(non_system_indexes) <= keep:
            self.logger.debug(
                "History trim skipped | non_system=%s keep=%s total=%s",
                len(non_system_indexes),
                keep,
                len(self.conversation_history),
            )
            return

        keep_non_system = set(non_system_indexes[-keep:])
        before = len(self.conversation_history)

        self.conversation_history = [
            msg for idx, msg in enumerate(self.conversation_history)
            if msg.get("role") == "system" or idx in keep_non_system
        ]

        self.logger.info(
            "History trimmed | before=%s after=%s kept_non_system=%s",
            before,
            len(self.conversation_history),
            keep,
        )

    def run(self, user_input: str) -> Dict[str, Any]:
        self.logger.info("Run started | input=%r", user_input)
        self._trim_history()

        state = WorkflowState(
            workflow_id=str(uuid.uuid4()),
            user_input=user_input,
            history=list(self.conversation_history),
        )

        self.logger.debug(
            "State created | workflow_id=%s history_messages=%s",
            state.workflow_id,
            len(state.history),
        )

        # 1. Route + 2. Shape (parallel execution when possible)
        # Router and Shaper can run concurrently since Shaper doesn't depend
        # on Router's output - both work from the same initial state.
        # This cuts latency by 40-60% when backends differ.
        router = self.agents.get("router")
        shaper = self.agents.get("shaper")
        needs_reshape = (
            not self._shaped_this_session
            or _is_short_followup(user_input)
        ) and state.route != ROUTE_TRIVIAL

        # Determine if we can parallelize
        can_parallel = (
            router is not None
            and shaper is not None
            and needs_reshape
        )

        if can_parallel:
            self.logger.info(
                "Running router and shaper in parallel | first_turn=%s short_followup=%s",
                not self._shaped_this_session,
                _is_short_followup(user_input),
            )

            def run_router():
                try:
                    self.logger.debug("Routing with router=%s", getattr(router, "model_id", type(router).__name__))
                    router.run(state)
                    return {"route": state.route, "error": None}
                except Exception as e:
                    self.logger.exception("Router failed: %s", e)
                    return {"route": ROUTE_REASONING, "error": e}

            def run_shaper():
                try:
                    self.logger.debug("Shaping prompt with shaper=%s", getattr(shaper, "model_id", type(shaper).__name__))
                    shaper.run(state)
                    return {"shaped": True, "error": None}
                except Exception as e:
                    self.logger.exception("Shaper failed: %s", e)
                    return {"shaped": False, "error": e}

            # Optimized parallel processing with timeout and better resource management
            with concurrent.futures.ThreadPoolExecutor(max_workers=2, thread_name_prefix="AgentWorkflow") as ex:
                router_future = ex.submit(run_router)
                shaper_future = ex.submit(run_shaper)

                try:
                    # Wait for router result with timeout
                    router_result = router_future.result(timeout=30.0)
                except concurrent.futures.TimeoutError:
                    self.logger.error("Router operation timed out")
                    router_result = {"route": ROUTE_REASONING, "error": "Router timeout"}
                
                # Only wait for shaper result if we actually need it
                if needs_reshape and state.route != ROUTE_TRIVIAL:
                    try:
                        shaper_result = shaper_future.result(timeout=30.0)
                    except concurrent.futures.TimeoutError:
                        self.logger.error("Shaper operation timed out")
                        shaper_result = {"shaped": False, "error": "Shaper timeout"}
                else:
                    shaper_result = {"shaped": False, "error": None}

            # Apply router result
            if router_result.get("error"):
                state.route = ROUTE_REASONING
            self.logger.info("Router decided route=%s", state.route)

            # Handle trivial route after parallel execution with parallelization
            if state.route == ROUTE_TRIVIAL:
                self.logger.info("Taking trivial path")
                executor = self.agents.get("executor") or self.agents["reasoner"]
                try:
                    if hasattr(executor, "run_no_tools"):
                        self.logger.debug("Calling executor.run_no_tools()")
                        # Parallelize trivial path execution for better performance
                        with concurrent.futures.ThreadPoolExecutor(max_workers=1, thread_name_prefix="TrivialPath") as ex:
                            future = ex.submit(executor.run_no_tools, state)
                            try:
                                future.result(timeout=10.0)  # Reduced timeout for trivial requests
                            except concurrent.futures.TimeoutError:
                                self.logger.error("Trivial path execution timed out")
                                state.final_answer = "ERROR: Trivial path timeout"
                    else:
                        self.logger.debug("Executor has no run_no_tools(); calling run()")
                        executor.run(state)
                except Exception as e:
                    self.logger.exception("Trivial path failed: %s", e)
                    state.final_answer = f"ERROR: {e}"

                # Safety net for trivial path
                candidate = str(state.final_answer or "")
                cleaned = _td.clean_history_text(candidate)
                parsed_calls = _td.parse_all_tag_tool_calls(
                    cleaned,
                    self.tool_registry.definitions,
                )
                tool_like = parsed_calls or _td.looks_like_malformed_tool_call(cleaned)
                plan_like = _looks_like_plan(cleaned)
                if tool_like or plan_like:
                    reason = "tool-like" if tool_like else "plan-like"
                    self.logger.warning(
                        "Trivial route emitted %s output; escalating to reasoning. "
                        "parsed_calls=%s",
                        reason,
                        parsed_calls,
                    )
                    state.add_trace(
                        "workflow",
                        output=f"route-corrected: trivial→reasoning ({reason})",
                        detail=(cleaned[:400] + ("..." if len(cleaned) > 400 else "")),
                    )
                    state.route = ROUTE_REASONING
                    state.final_answer = None
                else:
                    # Apply shaper result and finalize
                    if shaper_result.get("error"):
                        state.shaped_prompt = state.user_input
                    else:
                        self.logger.debug(
                            "Shaper complete | shaped_prompt_present=%s",
                            bool(getattr(state, "shaped_prompt", None)),
                        )
                    self._shaped_this_session = True
                    return self.finalize(state, user_input)

            # Apply shaper result for reasoning route
            if shaper_result.get("error"):
                state.shaped_prompt = state.user_input
            else:
                self.logger.debug(
                    "Shaper complete | shaped_prompt_present=%s",
                    bool(getattr(state, "shaped_prompt", None)),
                )
            self._shaped_this_session = True

        else:
            # Sequential fallback (same as before)
            # 1. Route
            if router is not None:
                try:
                    self.logger.debug("Routing with router=%s", getattr(router, "model_id", type(router).__name__))
                    router.run(state)
                    self.logger.info("Router decided route=%s", state.route)
                except Exception as e:
                    self.logger.exception("Router failed, falling back to reasoning route: %s", e)
                    state.route = ROUTE_REASONING
            else:
                self.logger.warning("No router configured; forcing reasoning route")
                state.route = ROUTE_REASONING

            # 2. Trivial
            if state.route == ROUTE_TRIVIAL:
                self.logger.info("Taking trivial path")
                executor = self.agents.get("executor") or self.agents["reasoner"]
                try:
                    if hasattr(executor, "run_no_tools"):
                        self.logger.debug("Calling executor.run_no_tools()")
                        executor.run_no_tools(state)
                    else:
                        self.logger.debug("Executor has no run_no_tools(); calling run()")
                        executor.run(state)
                except Exception as e:
                    self.logger.exception("Trivial path failed: %s", e)
                    state.final_answer = f"ERROR: {e}"

                # Safety net
                candidate = str(state.final_answer or "")
                cleaned = _td.clean_history_text(candidate)
                parsed_calls = _td.parse_all_tag_tool_calls(
                    cleaned,
                    self.tool_registry.definitions,
                )
                tool_like = parsed_calls or _td.looks_like_malformed_tool_call(cleaned)
                plan_like = _looks_like_plan(cleaned)
                if tool_like or plan_like:
                    reason = "tool-like" if tool_like else "plan-like"
                    self.logger.warning(
                        "Trivial route emitted %s output; escalating to reasoning. "
                        "parsed_calls=%s",
                        reason,
                        parsed_calls,
                    )
                    state.add_trace(
                        "workflow",
                        output=f"route-corrected: trivial→reasoning ({reason})",
                        detail=(cleaned[:400] + ("..." if len(cleaned) > 400 else "")),
                    )
                    state.route = ROUTE_REASONING
                    state.final_answer = None
                else:
                    return self.finalize(state, user_input)

            # 3. Shape (sequential)
            # Skip Shaper for trivial requests as they don't need shaping
            if state.route != ROUTE_TRIVIAL and shaper is not None and needs_reshape:
                try:
                    self.logger.info(
                        "Running shaper | first_turn=%s short_followup=%s",
                        not self._shaped_this_session,
                        _is_short_followup(user_input),
                    )
                    shaper.run(state)
                    self.logger.debug(
                        "Shaper complete | shaped_prompt_present=%s",
                        bool(getattr(state, "shaped_prompt", None)),
                    )
                except Exception as e:
                    self.logger.exception("Shaper failed; falling back to raw input: %s", e)
                    state.shaped_prompt = state.user_input
                self._shaped_this_session = True
            elif state.shaped_prompt is None:
                self.logger.debug("No shaper used or already shaped; using raw input")
                state.shaped_prompt = state.user_input

        # 4. Loop
        reasoner = self.agents["reasoner"]
        executor = self.agents.get("executor")

        last_failed_sig: Optional[str] = None
        consecutive_failures = 0
        empty_retries = 0

        # Successful-repeat detection
        last_success_sig: Optional[str] = None

        # Circuit breaker: track reasoner output signatures to detect loops
        reasoner_output_history: List[str] = []
        max_identical_reasoner_outputs = 3

        # Smarter failure detection: track non-progress iterations
        # A "progress" iteration either: (1) produces new tool calls, (2) produces
        # a final answer, or (3) changes the tool call signature from last time.
        # If we see 6 consecutive non-progress iterations, bail out early.
        no_progress_count = 0
        max_no_progress_iterations = 6
        last_tool_sig: Optional[str] = None

        # Post-edit validation tracking
        dart_edited = False
        py_edited = False
        dart_validated = False
        py_validated = False
        validation_nudges = 0
        max_validation_nudges = 1

        # Discovery vs action tracking to prevent endless exploration
        # Discovery tools: list_files_recursive, list_files, search_in_files, find_files
        # Action tools: read_file, write_file, patch_file, append_file, delete_file, etc.
        _DISCOVERY_TOOLS = frozenset({"list_files_recursive", "list_files", "search_in_files", "find_files"})
        _ACTION_TOOLS = frozenset({"read_file", "write_file", "patch_file", "append_file", "delete_file", "move_file", "create_directory"})
        consecutive_discovery_count = 0
        max_consecutive_discovery = 4

        turn_start = time.monotonic()
        for iteration in range(self.max_iterations):
            # Dynamic Iteration Limit: Extend budget if progress is being made.
            # Check when we're near the current limit to see if recent tool calls succeeded.
            if iteration >= self.max_iterations - 2:
                recent_history = "".join(
                    [m.get("content", "") for m in state.history[-5:]]
                )
                if recent_history and '"status": "success"' in recent_history:
                    extension = 10
                    old_limit = self.max_iterations
                    self.max_iterations += extension
                    self.logger.info(
                        "Progress detected. Extending max_iterations "
                        "from %s to %s",
                        old_limit, self.max_iterations
                    )
                    continue

            iter_start = time.monotonic()
            self.logger.debug(
                "Loop iteration start | iteration=%s history=%s tool_results=%s",
                iteration,
                len(state.history),
                len(getattr(state, "tool_results", []) or []),
            )

            # Clear stale values before each reasoner call
            state.tool_calls = []
            state.final_answer = None

            try:
                self._compact_for_reasoner(state, reasoner)

                self.logger.debug(
                    "Calling reasoner=%s",
                    getattr(reasoner, "model_id", type(reasoner).__name__),
                )
                reasoner_start = time.monotonic()
                reasoner.run(state)
                reasoner_dt = time.monotonic() - reasoner_start
                if reasoner_dt >= 30.0:
                    print(
                        f"[orch] iter {iteration}: reasoner took "
                        f"{reasoner_dt:.1f}s (cumulative turn "
                        f"{time.monotonic() - turn_start:.0f}s)",
                        file=sys.stderr, flush=True,
                    )
            except Exception as e:
                self.logger.exception("Reasoner failed: %s", e)
                state.final_answer = f"ERROR: Reasoner failed: {e}"
                break

            # Per-iteration timeout guard
            iter_elapsed = time.monotonic() - iter_start
            if iter_elapsed > self.iteration_timeout:
                self.logger.error(
                    "Iteration timeout | iteration=%s elapsed=%.1fs limit=%.1fs",
                    iteration, iter_elapsed, self.iteration_timeout
                )
                state.final_answer = (
                    f"ERROR: Iteration {iteration} exceeded timeout "
                    f"({iter_elapsed:.1f}s > {self.iteration_timeout}s)"
                )
                break

            # Overall turn timeout guard
            turn_elapsed = time.monotonic() - turn_start
            if turn_elapsed > self.turn_timeout:
                self.logger.error(
                    "Turn timeout | iteration=%s elapsed=%.1fs limit=%.1fs",
                    iteration, turn_elapsed, self.turn_timeout
                )
                state.final_answer = (
                    f"ERROR: Turn exceeded timeout "
                    f"({turn_elapsed:.1f}s > {self.turn_timeout}s). "
                    f"Completed {iteration + 1} iterations."
                )
                break

            self.logger.debug(
                "Reasoner output | final_answer=%r tool_calls=%s",
                state.final_answer,
                len(state.tool_calls or []),
            )

            # Smarter failure detection: check for non-progress iterations
            current_tool_sig = self.calls_signature(list(state.tool_calls or []))
            has_final = bool(state.final_answer)
            has_tools = bool(state.tool_calls)
            tool_sig_changed = current_tool_sig != last_tool_sig if current_tool_sig else False

            made_progress = has_final or (has_tools and tool_sig_changed)

            if not made_progress:
                no_progress_count += 1
                self.logger.debug(
                    "No-progress iteration | count=%s/%s has_final=%s has_tools=%s sig_changed=%s",
                    no_progress_count, max_no_progress_iterations,
                    has_final, has_tools, tool_sig_changed
                )
            else:
                no_progress_count = 0
                if has_tools:
                    last_tool_sig = current_tool_sig

            if no_progress_count >= max_no_progress_iterations:
                self.logger.error(
                    "Non-progress circuit breaker triggered | count=%s/%s",
                    no_progress_count, max_no_progress_iterations
                )
                state.final_answer = (
                    "ERROR: The reasoner failed to make progress after "
                    f"{max_no_progress_iterations} consecutive iterations. "
                    "The model may be confused, stuck, or unable to satisfy "
                    "the request. Try rephrasing or simplifying your task."
                )
                break

            # Circuit breaker: detect repeated identical reasoner outputs
            reasoner_sig = f"answer={state.final_answer}|tools={state.tool_calls}"
            if reasoner_sig in reasoner_output_history:
                consecutive_identical = reasoner_output_history.count(reasoner_sig)
                if consecutive_identical >= max_identical_reasoner_outputs:
                    self.logger.error(
                        "Circuit breaker triggered | identical_outputs=%s signature=%s",
                        consecutive_identical, reasoner_sig[:100]
                    )
                    state.final_answer = (
                        "ERROR: Repeated identical responses detected. "
                        "The reasoner is stuck in a loop and cannot make progress. "
                        "Consider rephrasing your request or checking for conflicting constraints."
                    )
                    break
            reasoner_output_history.append(reasoner_sig)
            # Keep history bounded to last 10 outputs
            if len(reasoner_output_history) > 10:
                reasoner_output_history.pop(0)

            # EMPTY
            if not state.tool_calls and not state.final_answer:
                empty_retries += 1
                self.logger.warning("Empty reasoner response | retry=%s", empty_retries)

                if empty_retries >= 3:
                    state.final_answer = "ERROR: Empty responses from model"
                    self.logger.error("Too many empty responses; stopping workflow")
                    break

                state.history.append(
                    {
                        "role": "user",
                        "content": (
                            "Your reply was empty. Respond with:\n"
                            "1) Tool call OR\n"
                            "2) Final answer"
                        ),
                    }
                )
                continue

            # PLAN
            if state.final_answer and _looks_like_plan(state.final_answer):
                self.logger.warning("Plan-like final answer rejected: %r", state.final_answer)
                state.final_answer = None
                state.history.append(
                    {
                        "role": "user",
                        "content": (
                            "Plans are not allowed. Respond with:\n"
                            "1) Tool call OR\n"
                            "2) Final answer"
                        ),
                    }
                )
                continue

            # TOOLS
            if state.tool_calls:
                if executor is None:
                    self.logger.error("Tool calls requested but executor is missing")
                    state.final_answer = "ERROR: Executor missing"
                    break

                pending_calls = [dict(c) for c in state.tool_calls]
                pending_sig = self.calls_signature(pending_calls)

                before_results = len(getattr(state, "tool_results", []) or [])

                self.logger.info(
                    "Tool batch requested | calls=%s signature=%s",
                    pending_calls,
                    pending_sig,
                )

                if pending_sig == last_failed_sig:
                    consecutive_failures += 1
                else:
                    consecutive_failures = 0

                # Successful-repeat gate
                if pending_sig == last_success_sig:
                    self.logger.warning(
                        "Successful-repeat blocked | signature=%s",
                        pending_sig,
                    )
                    state.add_trace(
                        "workflow",
                        output="repeat-blocked: identical to last successful call",
                        detail=pending_sig[:400],
                    )
                    state.history.append({
                        "role": "user",
                        "content": (
                            "You just ran that exact tool call successfully "
                            "in the previous step. The result may have been "
                            "elided to fit the context window — repeating the "
                            "call will not bring the content back.\n\n"
                            "Either:\n"
                            "  1) Call a DIFFERENT tool (narrower path, "
                            "specific line range, different file), or\n"
                            "  2) Produce the final answer with what you "
                            "already know.\n\n"
                            "Do NOT issue the same call again."
                        ),
                    })
                    state.tool_calls = []
                    continue

                if consecutive_failures >= self.max_identical_failures:
                    last_error_text = self.extract_last_error(
                        (getattr(state, "tool_results", []) or [])[before_results:]
                    )
                    self.logger.error(
                        "Repeated failing tool calls detected | signature=%s last_error=%s",
                        pending_sig,
                        last_error_text,
                    )
                    state.tool_calls = []
                    state.final_answer = (
                        "ERROR: Repeated failing tool calls. "
                        f"Last error: {last_error_text or 'unknown tool error'}"
                    )
                    break

                try:
                    self.logger.debug(
                        "Calling executor=%s | tool_count=%s",
                        getattr(executor, "model_id", type(executor).__name__),
                        len(pending_calls),
                    )
                    exec_result = executor.run(state)
                    if exec_result is not None:
                        self.logger.debug("Executor returned: %r", exec_result)
                except Exception as e:
                    self.logger.exception("Executor failed: %s", e)
                    state.tool_calls = []
                    state.final_answer = f"ERROR: Executor failed: {e}"
                    break

                after_results = (getattr(state, "tool_results", []) or [])[before_results:]
                self.logger.debug(
                    "Executor finished | new_results=%s total_results=%s",
                    len(after_results),
                    len(getattr(state, "tool_results", []) or []),
                )

                batch_failed = self.latest_results_errored(after_results)
                if batch_failed:
                    last_failed_sig = pending_sig
                    error_text = self.extract_last_error(after_results)

                    last_call = pending_calls[-1] if pending_calls else {}
                    name = last_call.get("tool")
                    params = last_call.get("parameters", {})

                    self.logger.warning(
                        "Tool batch failed | tool=%s params=%s error=%s",
                        name,
                        params,
                        error_text,
                    )

                    state.history.append(
                        {
                            "role": "user",
                            "content": (
                                f"Tool `{name}` failed.\n"
                                f"Params: {json.dumps(params, ensure_ascii=False)}\n"
                                f"Error: {error_text or 'unknown tool error'}\n"
                                "Do not repeat the same call.\n"
                                "Fix the parameters or choose a different tool.\n"
                                "Reply with exactly ONE tool call."
                            ),
                        }
                    )

                    state.tool_calls = []
                    continue

                self.logger.info("Tool batch succeeded")

                # Record what kind of work happened
                for c in pending_calls:
                    tool = c.get("tool", "")
                    if tool in _WRITE_TOOLS:
                        p = _path_from_call(c).lower()
                        if p.endswith(".dart"):
                            dart_edited = True
                        elif p.endswith(".py"):
                            py_edited = True
                    elif tool in _DART_VALIDATORS:
                        dart_validated = True
                    elif tool in _PY_VALIDATORS:
                        py_validated = True

                # Track discovery vs action to prevent endless exploration
                all_discovery = all(c.get("tool") in _DISCOVERY_TOOLS for c in pending_calls)
                any_action = any(c.get("tool") in _ACTION_TOOLS for c in pending_calls)

                if all_discovery and not any_action:
                    consecutive_discovery_count += 1
                    self.logger.debug(
                        "Discovery-only iteration | count=%s/%s",
                        consecutive_discovery_count, max_consecutive_discovery
                    )
                else:
                    consecutive_discovery_count = 0

                state.tool_calls = []
                last_failed_sig = None
                consecutive_failures = 0
                last_success_sig = pending_sig

                # If stuck in discovery mode, nudge toward action
                if consecutive_discovery_count >= max_consecutive_discovery:
                    self.logger.warning(
                        "Agent stuck in discovery mode | count=%s",
                        consecutive_discovery_count
                    )
                    state.history.append({
                        "role": "user",
                        "content": (
                            "You have made several discovery calls (list/search) without "
                            "reading or modifying any files. You now have enough context.\n\n"
                            "Your next response MUST either:\n"
                            "  1) Call read_file to examine specific files you found, OR\n"
                            "  2) Call write_file/patch_file to implement the change, OR\n"
                            "  3) Produce the final answer if the task is complete.\n\n"
                            "Do NOT make more list/search calls unless absolutely necessary."
                        ),
                    })
                    continue

                continue

            # FINAL
            if state.final_answer is not None:
                if not str(state.final_answer).strip():
                    self.logger.error("Empty final answer returned by model")
                    state.final_answer = "ERROR: Empty final answer"
                    break

                # Post-edit validation gate
                answer_text = str(state.final_answer)
                excuses = bool(_EXCUSE_RE.search(answer_text))
                needs_dart = (dart_edited and not dart_validated) \
                    or _is_punted_dart(answer_text) \
                    or (excuses and dart_edited and not dart_validated)
                needs_py = (py_edited and not py_validated) \
                    or _is_punted_py(answer_text) \
                    or (excuses and py_edited and not py_validated)

                if (needs_dart or needs_py) and validation_nudges < max_validation_nudges:
                    validation_nudges += 1
                    missing = []
                    if needs_dart:
                        missing.append("flutter_analyze")
                    if needs_py:
                        missing.append("python_check")

                    already_validated = (
                        (needs_dart and dart_validated)
                        or (needs_py and py_validated)
                    )

                    self.logger.warning(
                        "Post-edit validation gate triggered | missing=%s "
                        "dart_edited=%s dart_validated=%s py_edited=%s py_validated=%s "
                        "already_validated=%s nudge=%s/%s",
                        missing, dart_edited, dart_validated,
                        py_edited, py_validated, already_validated,
                        validation_nudges, max_validation_nudges,
                    )
                    state.add_trace(
                        "workflow",
                        output=(
                            f"rewrite-required: {','.join(missing)}"
                            if already_validated
                            else f"validation-required: {','.join(missing)}"
                        ),
                        detail=answer_text[:400],
                    )
                    state.final_answer = None

                    if already_validated:
                        state.history.append({
                            "role": "user",
                            "content": (
                                "Your final answer contains a forbidden phrase "
                                "asking the user to run the validator (or claiming "
                                "the validator is unavailable). The validator "
                                f"({', '.join(missing)}) was already called this "
                                "turn — that step is done.\n\n"
                                "Rewrite your final answer with these rules:\n"
                                "  - Do NOT tell the user to run flutter analyze, "
                                "python_check, etc.\n"
                                "  - Do NOT claim the validator is unavailable, "
                                "missing, or unreachable.\n"
                                "  - If the validator returned a real error "
                                "(e.g. 'flutter CLI not found on PATH'), report "
                                "that exact error verbatim ONCE and stop.\n"
                                "  - If the validator passed cleanly, just say so.\n\n"
                                "Reply with ONLY the rewritten final answer. No "
                                "tool call this turn."
                            ),
                        })
                    else:
                        state.history.append({
                            "role": "user",
                            "content": (
                                "You modified source files but did not validate "
                                "them, or your reply asks the user to validate. "
                                "That is not allowed.\n\n"
                                "Your IMMEDIATE next response MUST be exactly ONE "
                                f"tool call to: {', '.join(missing)}.\n"
                                "No prose. No final answer yet. Just the tool call.\n"
                                "After the validator runs, fix any reported errors "
                                "with another tool call, re-validate, and only "
                                "THEN produce the final answer."
                            ),
                        })
                    continue

                self.logger.info("Final answer produced")
                break

        else:
            if not state.final_answer:
                self.logger.error("Max iterations reached without final answer")
                state.final_answer = "ERROR: Max iterations reached"

        # Per-turn wall time + iteration count
        total_dt = time.monotonic() - turn_start
        print(
            f"[orch] turn complete in {total_dt:.0f}s "
            f"(iterations used: {iteration + 1}/{self.max_iterations})",
            file=sys.stderr, flush=True,
        )
        self.logger.info(
            "Run completed | route=%s final_answer=%r history_messages=%s",
            state.route,
            state.final_answer,
            len(state.history),
        )
        return self.finalize(state, user_input)

    def _compact_for_reasoner(self, state: WorkflowState, reasoner: Any) -> None:
        """Shrink ``state`` in place if it would overflow the reasoner."""
        backend = getattr(reasoner, "backend", None)
        context_limit = getattr(backend, "context_limit", 0) or 0
        if not context_limit:
            return

        max_tokens = int(getattr(reasoner, "max_tokens", 0) or 0)
        system_prompt_chars = len(getattr(reasoner, "system_prompt", "") or "")

        summarizer_callable = self._build_summarizer()

        try:
            result = compact_if_needed(
                state,
                context_limit=context_limit,
                max_tokens=max_tokens,
                system_prompt_chars=system_prompt_chars,
                summarizer=summarizer_callable,
            )
        except Exception as e:  # noqa: BLE001
            self.logger.warning("Compactor crashed; proceeding uncompacted: %s", e)
            return

        if result is not None:
            state.add_trace(
                "compactor",
                output=(
                    f"compacted {result['before_tokens']}->"
                    f"{result['after_tokens']} tokens "
                    f"(target {result['target_tokens']}, limit "
                    f"{result['context_limit']})"
                ),
                detail="\n".join(result.get("actions") or []),
            )

            if (
                not self._small_ctx_warned
                and context_limit < 8192
                and result["after_tokens"] > result["target_tokens"]
            ):
                self._small_ctx_warned = True
                model_id = getattr(reasoner, "model_id", "(unknown)")
                print(
                    f"[orch] WARNING: reasoner '{model_id}' context_limit="
                    f"{context_limit} is small and the prompt still exceeds "
                    f"the target ({result['after_tokens']} > "
                    f"{result['target_tokens']}). The model will likely "
                    f"return empty responses. If this is Ollama, raise "
                    f"--ollama-num-ctx (e.g. 16384 or 32768). If cloud, "
                    f"pick a model with a larger window for the reasoner "
                    f"role.",
                    file=sys.stderr, flush=True,
                )

    def _build_summarizer(self):
        """Return a ``(text) -> summary`` callable, or None."""
        explicit = self.agents.get("summarizer")
        shaper = self.agents.get("shaper")
        host = explicit or shaper
        if host is None:
            return None

        backend = getattr(host, "backend", None)
        if backend is None:
            return None

        max_tokens = int(getattr(host, "max_tokens", 0) or 800)
        max_tokens = max(max_tokens, 800)
        temperature = float(getattr(host, "temperature", 0.2) or 0.2)

        system_prompt = (
            "You are a context-compaction agent. Read the conversation "
            "excerpt and produce a dense, faithful summary that preserves "
            "every fact a downstream reasoning agent would need.\n"
            "Rules:\n"
            "  - Keep file paths, identifiers, and error messages verbatim.\n"
            "  - Keep the user's standing requests and decisions made.\n"
            "  - Drop greetings, filler, repeated tool listings.\n"
            "  - Replace large file contents with one-line notes "
            "('read lib/foo.dart, 812 lines').\n"
            "  - Plain text only. No markdown headers. Stay under 1500 chars."
        )

        def _summarize(text: str) -> str:
            user_msg = (
                "Summarize the following conversation excerpt for re-injection "
                "into the next reasoning turn.\n\n"
                "--- BEGIN EXCERPT ---\n"
                f"{text}\n"
                "--- END EXCERPT ---"
            )
            messages = [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_msg},
            ]
            try:
                out, _ = backend.chat(
                    messages=messages,
                    max_tokens=max_tokens,
                    temperature=temperature,
                    tools=None,
                )
            except Exception as e:  # noqa: BLE001
                self.logger.warning(
                    "Summarizer call (via %s) failed: %s",
                    getattr(host, "name", "shaper"), e,
                )
                return ""
            return (out or "").strip()

        return _summarize

    @staticmethod
    def _summarize_tool_calls(results: List[Dict[str, Any]]) -> Optional[str]:
        """Compact, model-facing recap of the tool calls executed this turn."""
        if not results:
            return None
        lines: List[str] = []
        for r in results:
            tool = r.get("tool", "?")
            params = r.get("parameters") or {}
            try:
                params_str = json.dumps(params, ensure_ascii=False)
            except Exception:
                params_str = str(params)
            if len(params_str) > 160:
                params_str = params_str[:160] + "…"

            raw = r.get("result", "")
            status = "?"
            if isinstance(raw, dict):
                status = str(raw.get("status", "?"))
            elif isinstance(raw, str):
                lower = raw.lower()
                if '"status": "error"' in lower or '"status":"error"' in lower:
                    status = "error"
                elif '"status": "success"' in lower or '"status":"success"' in lower:
                    status = "success"
            lines.append(f"  - {tool}({params_str}) -> {status}")
        return (
            "[Prior turn tool history — already executed, do NOT repeat "
            "identical calls]\n" + "\n".join(lines)
        )

    @staticmethod
    def calls_signature(calls: List[Dict[str, Any]]) -> str:
        """Stable string representing a list of tool calls for loop-detection."""
        try:
            return json.dumps(
                [{"t": c.get("tool"), "p": c.get("parameters") or {}} for c in calls],
                sort_keys=True,
                ensure_ascii=False,
            )
        except Exception:
            return repr(calls)

    @staticmethod
    def latest_results_errored(results: List[Dict[str, Any]]) -> bool:
        """Return True if the latest tool-result batch contains an error."""
        if not results:
            return False

        for r in reversed(results):
            raw = r.get("result", "")
            if not raw:
                continue

            if isinstance(raw, dict):
                status = str(raw.get("status", "")).lower()
                if status == "error":
                    return True
                if status == "success":
                    return False
                continue

            lower = raw.lower() if isinstance(raw, str) else ""

            if '"status": "error"' in lower or '"status":"error"' in lower:
                return True

            if '"status": "success"' in lower or '"status":"success"' in lower:
                return False

        return False

    @staticmethod
    def extract_last_error(results: List[Dict[str, Any]]) -> str:
        """Pull the most useful error text from the latest tool results."""
        if not results:
            return ""

        for r in reversed(results):
            raw = r.get("result", "")
            if not raw:
                continue

            if isinstance(raw, dict):
                status = str(raw.get("status", "")).lower()
                if status == "error":
                    msg = raw.get("message") or raw.get("error") or raw
                    return str(msg)
                continue

            if isinstance(raw, str):
                try:
                    obj = json.loads(raw)
                    if isinstance(obj, dict) and str(obj.get("status", "")).lower() == "error":
                        return str(obj.get("message") or obj.get("error") or raw)
                except Exception:
                    pass
                return raw

        return ""

    def finalize(self, state: WorkflowState, user_input: str) -> Dict[str, Any]:
        answer = state.final_answer or "ERROR: Empty model response"

        self.logger.debug("Finalizing turn | answer=%r", answer)

        self.conversation_history.append(
            {
                "role": "user",
                "content": user_input,
            }
        )

        if answer.strip():
            self.conversation_history.append(
                {
                    "role": "assistant",
                    "content": answer,
                }
            )

        tool_summary = self._summarize_tool_calls(
            getattr(state, "tool_results", None) or []
        )
        if tool_summary:
            self.conversation_history.append(
                {
                    "role": "system",
                    "content": tool_summary,
                }
            )

        tool_calls_compact: List[Dict[str, Any]] = []
        for r in (getattr(state, "tool_results", None) or []):
            raw = r.get("result", "")
            status = "?"
            if isinstance(raw, dict):
                status = str(raw.get("status", "?"))
            elif isinstance(raw, str):
                low = raw.lower()
                if '"status": "error"' in low or '"status":"error"' in low:
                    status = "error"
                elif '"status": "success"' in low or '"status":"success"' in low:
                    status = "success"
            params = r.get("parameters") or {}
            tool_calls_compact.append({
                "tool": r.get("tool", "?"),
                "path": str(params.get("path") or params.get("destination") or ""),
                "status": status,
            })

        payload = {
            "response": answer,
            "trace": state.trace_to_list(),
            "route": state.route,
            "tool_calls": tool_calls_compact,
        }

        self.logger.debug(
            "Finalize payload ready | trace_len=%s route=%s tool_calls=%s",
            len(payload.get("trace", []) or []),
            payload.get("route"),
            len(tool_calls_compact),
        )
        return payload


# ----------------------------------------------------------------------
# Convenience builder for orchestrator.py.
# ----------------------------------------------------------------------
def build_workflow_from_args(
        args,
        *,
        security_config: SecurityConfig,
        base_path: str = ".",
        path_filter: Optional[Any] = None,
) -> Workflow:
    """One-call helper: parse the agent config, build everything, return a Workflow."""
    tool_registry = ToolRegistry(
        base_path=base_path,
        security_config=security_config,
        path_filter=path_filter,
    )
    secrets = SecretsResolver(args)
    agents = build_agents(
        args.agent_config,
        secrets,
        tool_definitions=tool_registry.definitions,
        tools_catalog_text=tool_registry.get_system_prompt(),
    )
    return Workflow(agents, tool_registry)
