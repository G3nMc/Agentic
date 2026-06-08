"""Agent implementations for the multi_mode single-loop workflow.

Active roles:
  - Reasoner: the brain (LLM-driven planning + tool selection)
  - Executor: deterministic tool runner (no LLM)
  - Summarizer: final-answer synthesis

The previous multi-agent pipeline (Router/Shaper/ExecutorAgent/etc.) was
removed; multi_mode now uses a single-loop architecture coordinated by
``multi_mode.loop.orchestrator.Orchestrator``.
"""

from executor import Executor
from reasoner import Reasoner, ReasonerOutput
from summarizer import Summarizer

__all__ = [
    "Reasoner",
    "ReasonerOutput",
    "Executor",
    "Summarizer",
]
