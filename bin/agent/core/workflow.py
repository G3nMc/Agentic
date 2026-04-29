"""Workflow dispatcher — replaces the single-agent run-loop in multi-agent mode.

Hierarchy::

    Router (cheapest, gatekeeper)
       │
       ├── trivial  ──────────────►  Executor.run_no_tools  ──►  final answer
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
                    ├── yes ───►Executor.run ──┘
                    └── no  ───► final answer

The dispatcher owns the loop, the Reasoner owns the orchestration inside
the loop. Maximum iterations are capped so a misbehaving Reasoner can't
chew through quota indefinitely.
"""
from __future__ import annotations

import json
import logging
import re
import uuid
from typing import Any, Dict, List, Optional

from .agent_config import build_agents, SecretsResolver
from .state import ROUTE_REASONING, ROUTE_TRIVIAL, WorkflowState
from ..loop import tool_dispatch as _td
from ..policy import SecurityConfig
from ..tools.registry import ToolRegistry


_WRITE_TOOLS = frozenset({"write_file", "append_file", "patch_file"})
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
            max_iterations: int = 200,
            max_history_turns: int = 6,
            max_identical_failures: int = 10,
    ):
        self.agents = agents
        self.tool_registry = tool_registry
        self.max_iterations = max_iterations
        self.max_history_turns = max_history_turns
        self.max_identical_failures = max_identical_failures

        self.logger = logging.getLogger(f"{__name__}.Workflow")

        executor = self.agents.get("executor")
        if executor is not None:
            executor.tool_registry = tool_registry

        self.conversation_history: List[Dict[str, Any]] = []
        self._shaped_this_session: bool = False

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

        # 1. Route
        router = self.agents.get("router")
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

            # Safety net: if the cheap "trivial" model emits a tool-like
            # payload, do NOT leak it as plain text. Re-route to the normal
            # reasoning/tool loop so calls are parsed and executed.
            candidate = str(state.final_answer or "")
            cleaned = _td.clean_history_text(candidate)
            parsed_calls = _td.parse_all_tag_tool_calls(
                cleaned,
                self.tool_registry.definitions,
            )
            if parsed_calls or _td.looks_like_malformed_tool_call(cleaned):
                self.logger.warning(
                    "Trivial route emitted tool-like output; escalating to reasoning. "
                    "parsed_calls=%s",
                    parsed_calls,
                )
                state.add_trace(
                    "workflow",
                    output="route-corrected: trivial→reasoning",
                    detail=(cleaned[:400] + ("..." if len(cleaned) > 400 else "")),
                )
                state.route = ROUTE_REASONING
                state.final_answer = None
            else:
                return self.finalize(state, user_input)

        # 3. Shape
        shaper = self.agents.get("shaper")
        if shaper is not None and not self._shaped_this_session:
            try:
                self.logger.info("Running shaper once for this session")
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

        # Post-edit validation tracking — see _is_punted_dart above and the
        # MANDATORY POST-EDIT VALIDATION block in the system prompt.
        dart_edited = False
        py_edited = False
        dart_validated = False
        py_validated = False
        validation_nudges = 0
        max_validation_nudges = 2

        def looks_like_plan(text: str) -> bool:
            if not text:
                return False
            t = text.lower()
            return any(
                x in t
                for x in [
                    "i will",
                    "i'll",
                    "i am going to",
                    "next i will",
                    "let me",
                    "plan:",
                    "steps:",
                    "approach:",
                ]
            )

        for iteration in range(self.max_iterations):
            self.logger.debug(
                "Loop iteration start | iteration=%s history=%s tool_results=%s",
                iteration,
                len(state.history),
                len(getattr(state, "tool_results", []) or []),
            )

            # Clear stale values before each reasoner call so old state does not leak.
            state.tool_calls = []
            state.final_answer = None

            try:
                self.logger.debug(
                    "Calling reasoner=%s",
                    getattr(reasoner, "model_id", type(reasoner).__name__),
                )
                reasoner.run(state)
            except Exception as e:
                self.logger.exception("Reasoner failed: %s", e)
                state.final_answer = f"ERROR: Reasoner failed: {e}"
                break

            self.logger.debug(
                "Reasoner output | final_answer=%r tool_calls=%s",
                state.final_answer,
                len(state.tool_calls or []),
            )

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
            if state.final_answer and looks_like_plan(state.final_answer):
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

                    # Important: make the failure explicit in the next reasoning turn.
                    # This is what helps the model stop repeating the same bad call.
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

                    # Consume current batch so the next iteration does not
                    # accidentally re-run the same call.
                    state.tool_calls = []
                    continue

                self.logger.info("Tool batch succeeded")

                # Record what kind of work happened in this batch so the
                # post-edit validation gate can enforce flutter_analyze /
                # python_check before a final answer is accepted.
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

                state.tool_calls = []
                last_failed_sig = None
                consecutive_failures = 0
                continue

            # FINAL
            if state.final_answer is not None:
                if not str(state.final_answer).strip():
                    self.logger.error("Empty final answer returned by model")
                    state.final_answer = "ERROR: Empty final answer"
                    break

                # ── Post-edit validation gate ────────────────────────────
                # If the agent edited Dart/Python files but never called the
                # corresponding validator, OR its final answer punts the
                # validation back to the user, push the loop forward with a
                # corrective user turn instead of accepting the answer.
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

                    # Two failure modes need different corrective messages:
                    #  (a) Validator was NEVER called this turn → demand the call.
                    #  (b) Validator WAS called but the answer still punts to
                    #      the user (or invents excuses about CLI availability)
                    #      → just demand a rewrite without the punt phrase.
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

        self.logger.info(
            "Run completed | route=%s final_answer=%r history_messages=%s",
            state.route,
            state.final_answer,
            len(state.history),
        )
        return self.finalize(state, user_input)

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
        """
        Return True if the latest tool-result batch contains an error.

        This only inspects the results from the current executor run, not the
        entire accumulated history.
        """
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

        payload = {
            "response": answer,
            "trace": state.trace_to_list(),
            "route": state.route,
        }

        self.logger.debug(
            "Finalize payload ready | trace_len=%s route=%s",
            len(payload.get("trace", []) or []),
            payload.get("route"),
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
) -> Workflow:
    """One-call helper: parse the agent config, build everything, return a Workflow."""
    tool_registry = ToolRegistry(base_path=base_path, security_config=security_config)
    secrets = SecretsResolver(args)
    agents = build_agents(
        args.agent_config,
        secrets,
        tool_definitions=tool_registry.definitions,
        tools_catalog_text=tool_registry.get_system_prompt(),
    )
    return Workflow(agents, tool_registry)
