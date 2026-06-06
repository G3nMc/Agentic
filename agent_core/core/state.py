"""Workflow state management."""

from dataclasses import dataclass, field
from typing import List, Dict, Any, Optional
from enum import Enum
from datetime import datetime

from agent_core.core.message import Message, ToolCall, ToolResult


class TaskStatus(Enum):
    PENDING = "pending"
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"
    FAILED = "failed"
    NEEDS_REVISION = "needs_revision"


@dataclass
class TraceEntry:
    """One step in the execution trace."""

    agent: str  # "router" | "reasoner" | "executor" | "summarizer"
    output: str = ""  # short human-readable summary
    detail: Optional[str] = None  # optional longer body
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
    """Mutable bundle of everything an agent might need or produce."""

    messages: List[Message] = field(default_factory=list)
    pending_tool_calls: List[ToolCall] = field(default_factory=list)
    tool_results: List[ToolResult] = field(default_factory=list)
    token_count: int = 0
    iteration: int = 0
    status: TaskStatus = TaskStatus.PENDING
    current_plan: Optional[str] = None
    completed_subtasks: List[str] = field(default_factory=list)
    failed_subtasks: List[str] = field(default_factory=list)
    metadata: Dict[str, Any] = field(default_factory=dict)
    created_at: datetime = field(default_factory=datetime.now)
    updated_at: datetime = field(default_factory=datetime.now)
    trace: List[TraceEntry] = field(default_factory=list)
    
    def is_terminal(self) -> bool:
        return self.status in (TaskStatus.COMPLETED, TaskStatus.FAILED)
    
    def add_message(self, message: Message) -> None:
        self.messages.append(message)
        self.updated_at = datetime.now()
    
    def add_tool_call(self, tool_call: ToolCall) -> None:
        self.pending_tool_calls.append(tool_call)
        self.updated_at = datetime.now()
    
    def add_tool_result(self, result: ToolResult) -> None:
        self.tool_results.append(result)
        self.updated_at = datetime.now()
    
    def clear_pending_tools(self) -> None:
        self.pending_tool_calls.clear()
        self.updated_at = datetime.now()
    
    def mark_completed(self) -> None:
        self.status = TaskStatus.COMPLETED
        self.updated_at = datetime.now()
    
    def mark_failed(self, error: str) -> None:
        self.status = TaskStatus.FAILED
        self.metadata["error"] = error
        self.updated_at = datetime.now()
    
    def mark_in_progress(self) -> None:
        self.status = TaskStatus.IN_PROGRESS
        self.updated_at = datetime.now()
    
    def add_trace(self, agent: str, output: str = "", detail: Optional[str] = None, tokens: Optional[int] = None) -> None:
        self.trace.append(TraceEntry(agent=agent, output=output, detail=detail, tokens=tokens))
    
    def get_trace(self) -> List[Dict[str, Any]]:
        return [t.to_dict() for t in self.trace]
    
    @classmethod
    def initial(cls, task: str, config) -> "WorkflowState":
        """Create initial state for a new task."""
        state = cls()
        from agent_core.core.message import Message, MessageRole
        state.add_message(Message(role=MessageRole.USER, content=task))
        state.mark_in_progress()
        return state
