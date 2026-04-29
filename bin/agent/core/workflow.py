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
import uuid
from typing import Any, Dict, List, Optional

from .agent_config import build_agents, SecretsResolver
from .state import ROUTE_REASONING, ROUTE_TRIVIAL, WorkflowState
from ..policy import SecurityConfig
from ..tools.registry import ToolRegistry


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
                state.tool_calls = []
                last_failed_sig = None
                consecutive_failures = 0
                continue

            # FINAL
            if state.final_answer is not None:
                if not str(state.final_answer).strip():
                    self.logger.error("Empty final answer returned by model")
                    state.final_answer = "ERROR: Empty final answer"
                else:
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