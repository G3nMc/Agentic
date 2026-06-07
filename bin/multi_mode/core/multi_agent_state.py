"""Multi-agent state and routing constants."""

from __future__ import annotations

from .state import WorkflowState  # noqa: F401

ROUTE_REASONING = "reasoning"
ROUTE_TOOL = "tool"
ROUTE_TRIVIAL = "trivial"

ALL_ROUTES = (ROUTE_REASONING, ROUTE_TOOL, ROUTE_TRIVIAL)
