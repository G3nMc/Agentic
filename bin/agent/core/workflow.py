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

The dispatcher owns the loop, the Reasoner owns the orchestration *inside*
the loop. Maximum iterations are capped so a misbehaving Reasoner can't
chew through quota indefinitely.
"""
from __future__ import annotations

import sys
import uuid
from typing import Any, Dict, List, Optional

from ..policy import SecurityConfig
from ..tools.registry import ToolRegistry
from .agent_config import build_agents, SecretsResolver
from .state import (ROUTE_REASONING, ROUTE_TRIVIAL, WorkflowState)


class Workflow:
    """Multi-agent dispatcher. Drop-in replacement for ``Orchestrator.run()``."""

    def __init__(self, agents: Dict[str, Any], tool_registry: ToolRegistry,
                 *, max_iterations: int = 8,
                 max_history_turns: int = 6):
        self.agents = agents
        self.tool_registry = tool_registry
        self.max_iterations = max_iterations
        self.max_history_turns = max_history_turns

        # The Executor needs a handle to the registry so it can run tools.
        # Attached here (rather than in the constructor) because the registry
        # can outlive any single agent rebuild.
        executor = self.agents.get("executor")
        if executor is not None:
            executor.tool_registry = tool_registry

        # Shared per-conversation history. The single-agent Orchestrator has
        # this on itself; we mirror the pattern so the protocol stays the
        # same on the Flutter side.
        self.conversation_history: List[Dict[str, Any]] = []
        # Tracks whether the Shaper has already run for this conversation —
        # we shape once, not on every follow-up.
        self._shaped_this_session: bool = False

    # ------------------------------------------------------------------
    # Session management (mirrors Orchestrator's API for orchestrator.py).
    # ------------------------------------------------------------------
    @property
    def model_id(self) -> str:
        reasoner = self.agents.get("reasoner")
        return getattr(reasoner, "model_id", "(unknown)")

    def reset(self) -> None:
        self.conversation_history = []
        self._shaped_this_session = False

    def import_history(self, history: List[Dict[str, Any]]) -> None:
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
        # If a non-empty history is being seeded we assume shaping already
        # happened in the prior turn(s).
        if self.conversation_history:
            self._shaped_this_session = True

    def _trim_history(self) -> None:
        # Keep system + last (max_history_turns * 2) messages — same policy as
        # the single-agent loop.
        non_system = [m for m in self.conversation_history
                      if m.get("role") != "system"]
        keep = self.max_history_turns * 2
        if len(non_system) > keep:
            self.conversation_history = non_system[-keep:]

    # ------------------------------------------------------------------
    # Main entry — called once per user prompt by orchestrator.py.
    # ------------------------------------------------------------------
    def run(self, user_input: str) -> Dict[str, Any]:
        """Execute one workflow turn. Returns ``{"response": str, "trace": [...]}``.

        Note the return *shape* is intentionally different from the single-agent
        ``Orchestrator.run`` (which returns a bare string). The orchestrator
        shim is responsible for serialising both shapes consistently for the
        Flutter side.
        """
        self._trim_history()
        state = WorkflowState(
            workflow_id=str(uuid.uuid4()),
            user_input=user_input,
            history=list(self.conversation_history),
        )

        # 1. Route -----------------------------------------------------
        router = self.agents.get("router")
        if router is not None:
            try:
                router.run(state)
            except Exception as e:  # noqa: BLE001
                print(f"[workflow] router crashed: {e}", file=sys.stderr)
                state.route = ROUTE_REASONING
                state.add_trace("router", output=ROUTE_REASONING,
                                detail=f"crash fallback: {e}")
        else:
            state.route = ROUTE_REASONING

        # 2. Trivial short-circuit ------------------------------------
        if state.route == ROUTE_TRIVIAL:
            executor = self.agents.get("executor") or self.agents["reasoner"]
            try:
                if hasattr(executor, "run_no_tools"):
                    executor.run_no_tools(state)
                else:
                    executor.run(state)
            except Exception as e:  # noqa: BLE001
                print(f"[workflow] trivial path crashed: {e}", file=sys.stderr)
                state.final_answer = f"Sorry, something went wrong: {e}"
            return self._finalize(state, user_input)

        # 3. Shape (once per session) ----------------------------------
        shaper = self.agents.get("shaper")
        if shaper is not None and not self._shaped_this_session:
            try:
                shaper.run(state)
            except Exception as e:  # noqa: BLE001
                print(f"[workflow] shaper crashed: {e}", file=sys.stderr)
                state.shaped_prompt = state.user_input
                state.add_trace("shaper", output="(failed, raw input kept)",
                                detail=str(e))
            self._shaped_this_session = True
        elif state.shaped_prompt is None:
            # Either no shaper configured, or already shaped earlier — feed
            # the reasoner with the raw input.
            state.shaped_prompt = state.user_input

        # 4. Reasoner / Executor loop ---------------------------------
        reasoner = self.agents["reasoner"]  # required (validated at build time)
        executor = self.agents.get("executor")

        for iteration in range(self.max_iterations):
            try:
                reasoner.run(state)
            except Exception as e:  # noqa: BLE001
                print(f"[workflow] reasoner crashed: {e}", file=sys.stderr)
                state.final_answer = f"Reasoner error: {e}"
                break

            if state.tool_calls:
                if executor is None:
                    state.final_answer = (
                        "Reasoner requested a tool but no Executor is "
                        "configured. Configure the executor role in Settings."
                    )
                    state.add_trace("workflow", output="(executor missing)")
                    break
                try:
                    executor.run(state)
                except Exception as e:  # noqa: BLE001
                    print(f"[workflow] executor crashed: {e}", file=sys.stderr)
                    state.final_answer = f"Executor error: {e}"
                    break
                # Loop back to the reasoner with the fresh tool results.
                continue

            # No tool calls → reasoner produced a final answer.
            if state.final_answer is not None:
                break
        else:
            # Loop exhausted without a final answer.
            if state.final_answer is None:
                state.final_answer = (
                    "Reached max workflow iterations "
                    f"({self.max_iterations}) without a final answer. "
                    "Try a more focused question or reduce tool usage."
                )
                state.add_trace("workflow", output="(max iterations)")

        return self._finalize(state, user_input)

    # ------------------------------------------------------------------
    def _finalize(self, state: WorkflowState, user_input: str) -> Dict[str, Any]:
        """Persist the turn into history and return the protocol payload."""
        answer = state.final_answer or ""
        # Keep the conversation history simple — the same shape the
        # single-agent orchestrator produces, so downstream code that reads
        # `conversation_history` continues to work.
        self.conversation_history.append({"role": "user", "content": user_input})
        if answer.strip():
            self.conversation_history.append({"role": "assistant", "content": answer})
        return {
            "response": answer,
            "trace": state.trace_to_list(),
            "route": state.route,
        }


# ----------------------------------------------------------------------
# Convenience builder for orchestrator.py.
# ----------------------------------------------------------------------
def build_workflow_from_args(args, *, security_config: SecurityConfig,
                             base_path: str = ".") -> Workflow:
    """One-call helper: parse the agent config, build everything, return a Workflow."""
    tool_registry = ToolRegistry(base_path=base_path,
                                 security_config=security_config)
    secrets = SecretsResolver(args)
    agents = build_agents(
        args.agent_config,
        secrets,
        tool_definitions=tool_registry.definitions,
        tools_catalog_text=tool_registry.get_system_prompt(),
    )
    return Workflow(agents, tool_registry)
