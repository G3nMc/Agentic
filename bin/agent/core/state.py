"""Shared state passed between agent nodes in a single workflow turn.

A ``WorkflowState`` is created at the top of :meth:`agent.core.workflow.Workflow.run`
and then mutated in-place by each agent node (router → shaper → reasoner →
executor). The ``trace`` list is what the Flutter UI renders as the
"Step expansion" — one entry per agent activation.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional


# Route labels emitted by the Router. Kept as plain strings (not an Enum) so
# the JSON payload sent to Flutter stays trivially serialisable.
ROUTE_TRIVIAL = "trivial"
ROUTE_REASONING = "reasoning"
ROUTE_TOOL = "tool"
ALL_ROUTES = (ROUTE_TRIVIAL, ROUTE_REASONING, ROUTE_TOOL)


@dataclass
class TraceEntry:
    """One step in the execution trace — what the UI renders as a step tile."""

    agent: str  # "router" | "shaper" | "reasoner" | "executor"
    output: str = ""  # short human-readable summary (route label, plan title, tool result status, …)
    detail: Optional[str] = None  # optional longer body (full plan, full tool result)
    tokens: Optional[int] = None  # estimated/actual tokens spent on this step

    def to_dict(self) -> Dict[str, Any]:
        d: Dict[str, Any] = {"agent": self.agent, "output": self.output}
        if self.detail is not None:
            d["detail"] = self.detail
        if self.tokens is not None:
            d["tokens"] = self.tokens
        return d


@dataclass
class WorkflowState:
    """Mutable bundle of everything an agent might need or produce.

    Not every field is filled on every turn — e.g. ``shaped_prompt`` stays
    ``None`` when the router classifies the request as ``trivial``.
    """

    workflow_id: str
    user_input: str
    history: List[Dict[str, Any]] = field(default_factory=list)

    route: Optional[str] = None
    shaped_prompt: Optional[str] = None
    plan: Optional[str] = None

    # Tool call intents emitted by the Reasoner. Each entry: {"tool": str, "parameters": dict}.
    tool_calls: List[Dict[str, Any]] = field(default_factory=list)
    # Results from the most recent ToolAgent run, mirrored back to the Reasoner.
    tool_results: List[Dict[str, Any]] = field(default_factory=list)

    final_answer: Optional[str] = None
    trace: List[TraceEntry] = field(default_factory=list)

    # Set when an agent decides the workflow should short-circuit (e.g. router
    # → trivial). The dispatcher reads this as a fall-through hint.
    short_circuit: bool = False

    def add_trace(
        self,
        agent: str,
        output: str = "",
        detail: Optional[str] = None,
        tokens: Optional[int] = None,
    ) -> None:
        self.trace.append(
            TraceEntry(agent=agent, output=output, detail=detail, tokens=tokens)
        )

    def trace_to_list(self) -> List[Dict[str, Any]]:
        return [t.to_dict() for t in self.trace]
