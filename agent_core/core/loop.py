"""Loop types and data structures."""

from dataclasses import dataclass
from typing import Optional, List

from agent_core.core.state import WorkflowState
from agent_core.core.message import Message


@dataclass
class ReasonerOutput:
    """Output from the reasoner."""
    tool_calls: List[Dict[str, Any]] = None
    final_answer: Optional[str] = None
    plan: Optional[str] = None
    reasoning: Optional[str] = None
    
    def __post_init__(self):
        if self.tool_calls is None:
            self.tool_calls = []


@dataclass
class LoopIteration:
    """Result of a single loop iteration."""
    state: WorkflowState
    reasoner_output: Optional[ReasonerOutput] = None
    tool_results: Optional[List] = None
    summarized: bool = False
    error: Optional[str] = None
