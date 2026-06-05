"""Message and state types for the agent workflow."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Any, Dict, List, Optional


class TaskStatus(Enum):
    """Status of a task or subtask."""

    PENDING = auto()
    IN_PROGRESS = auto()
    COMPLETED = auto()
    FAILED = auto()
    NEEDS_REVISION = auto()


@dataclass
class ToolCall:
    """A structured tool call request.

    Attributes:
        id: Unique identifier for this tool call.
        name: Name of the tool to invoke.
        arguments: Arguments to pass to the tool (JSON-serializable dict).
    """

    id: str
    name: str
    arguments: Dict[str, Any] = field(default_factory=dict)


@dataclass
class ToolResult:
    """Result of a tool execution.

    Attributes:
        tool_call_id: ID of the corresponding ToolCall.
        name: Name of the tool that was executed.
        success: Whether the tool executed successfully.
        result: The result data if successful (JSON-serializable).
        error: Error message if unsuccessful.
        duration_ms: Execution time in milliseconds.
    """

    tool_call_id: str
    name: str
    success: bool
    result: Optional[Any] = None
    error: Optional[str] = None
    duration_ms: float = 0.0


@dataclass
class Message:
    """A message in the conversation.

    Attributes:
        role: One of 'system', 'user', 'assistant', 'tool'.
        content: Text content (may be empty if tool_calls present).
        tool_calls: Tool calls made by the assistant (only for role='assistant').
        tool_call_id: ID of the tool call this message responds to (only for role='tool').
        metadata: Arbitrary metadata (e.g., token count, timestamp).
    """

    role: str
    content: str = ""
    tool_calls: Optional[List[ToolCall]] = None
    tool_call_id: Optional[str] = None
    metadata: Dict[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        """Validate message consistency."""
        valid_roles = {"system", "user", "assistant", "tool"}
        if self.role not in valid_roles:
            raise ValueError(f"Invalid role: {self.role}. Must be one of {valid_roles}")
        if self.role == "tool" and self.tool_call_id is None:
            raise ValueError("Messages with role='tool' must have a tool_call_id")
        if self.role != "assistant" and self.tool_calls is not None:
            raise ValueError(
                "tool_calls can only be present on messages with role='assistant'"
            )


@dataclass
class WorkflowState:
    """The full state of the agent workflow.

    Attributes:
        messages: Conversation history.
        pending_tools: Tool calls that have been made but not yet executed.
        token_count: Estimated total tokens in the conversation.
        iteration: Current iteration count.
        status: Overall task status.
        plan: Optional structured plan for the current task.
        metadata: Arbitrary workflow metadata.
    """

    messages: List[Message] = field(default_factory=list)
    pending_tools: List[ToolCall] = field(default_factory=list)
    token_count: int = 0
    iteration: int = 0
    status: TaskStatus = TaskStatus.PENDING
    plan: Optional[Dict[str, Any]] = None
    metadata: Dict[str, Any] = field(default_factory=dict)

    def is_terminal(self) -> bool:
        """Check if the workflow has reached a terminal state."""
        return self.status in {TaskStatus.COMPLETED, TaskStatus.FAILED}

    def add_message(self, message: Message) -> None:
        """Add a message to the history."""
        self.messages.append(message)

    def add_tool_result(self, result: ToolResult) -> None:
        """Add a tool result as a message."""
        content = (
            json.dumps(result.result) if result.success else f"Error: {result.error}"
        )
        self.messages.append(
            Message(
                role="tool",
                content=content,
                tool_call_id=result.tool_call_id,
                metadata={"duration_ms": result.duration_ms},
            )
        )

    def clear_pending_tools(self) -> None:
        """Clear the pending tools list."""
        self.pending_tools = []


import json  # noqa: E402 (placed here to avoid circular import issues)
