"""Agent implementations - both single-loop and multi-agent."""

# New-style agents (single loop)
from multi_mode.agents.reasoner import Reasoner, ReasonerOutput
from multi_mode.agents.executor import Executor
from multi_mode.agents.summarizer import Summarizer

# Old-style multi-agent roles
from .base import Agent
from .router import RouterAgent
from .shaper import ShaperAgent
from .reasoner_agent import ReasonerAgent
from .executor_agent import ExecutorAgent
from .summarizer_agent import SummarizerAgent

__all__ = [
    "Reasoner",
    "ReasonerOutput",
    "Executor",
    "Summarizer",
    "Agent",
    "RouterAgent",
    "ShaperAgent",
    "ReasonerAgent",
    "ExecutorAgent",
    "SummarizerAgent",
]
