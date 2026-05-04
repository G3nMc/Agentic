"""Role-specialised agents that operate on a shared :class:`WorkflowState`.

Each role wraps its own backend instance so the user can mix tiers (cheap
local model for the Router, strong cloud model for the Reasoner). The
backends themselves are constructed by :mod:`agent.core.agent_config`.
"""
import sys as _sys
_sys.dont_write_bytecode = True

from .base import Agent
from .router import RouterAgent
from .shaper import ShaperAgent
from .reasoner import ReasonerAgent
from .executor import ExecutorAgent
from .summarizer import SummarizerAgent

__all__ = [
    "Agent",
    "RouterAgent",
    "ShaperAgent",
    "ReasonerAgent",
    "ExecutorAgent",
    "SummarizerAgent",
]
