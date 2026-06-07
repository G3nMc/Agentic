"""Message types for the workflow."""

from dataclasses import dataclass, field
from typing import List, Optional, Dict, Any
from enum import Enum
import json


class MessageRole(Enum):
    SYSTEM = "system"
    USER = "user"
    ASSISTANT = "assistant"
    TOOL = "tool"


@dataclass
class ToolCall:
    id: str
    name: str
    arguments: Dict[str, Any]
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "arguments": self.arguments,
        }
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "ToolCall":
        return cls(
            id=data["id"],
            name=data["name"],
            arguments=data.get("arguments", {}),
        )


@dataclass
class ToolResult:
    tool_call_id: str
    name: str
    content: str
    error: Optional[str] = None
    metadata: Dict[str, Any] = field(default_factory=dict)
    
    def is_success(self) -> bool:
        return self.error is None
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "tool_call_id": self.tool_call_id,
            "name": self.name,
            "content": self.content,
            "error": self.error,
            "metadata": self.metadata,
        }
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "ToolResult":
        return cls(
            tool_call_id=data["tool_call_id"],
            name=data["name"],
            content=data["content"],
            error=data.get("error"),
            metadata=data.get("metadata", {}),
        )


@dataclass
class Message:
    role: MessageRole
    content: str
    tool_calls: List[ToolCall] = field(default_factory=list)
    tool_call_id: Optional[str] = None
    metadata: Dict[str, Any] = field(default_factory=dict)
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "role": self.role.value,
            "content": self.content,
            "tool_calls": [tc.to_dict() for tc in self.tool_calls],
            "tool_call_id": self.tool_call_id,
            "metadata": self.metadata,
        }
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "Message":
        return cls(
            role=MessageRole(data["role"]),
            content=data["content"],
            tool_calls=[ToolCall.from_dict(tc) for tc in data.get("tool_calls", [])],
            tool_call_id=data.get("tool_call_id"),
            metadata=data.get("metadata", {}),
        )
    
    def to_openai_format(self) -> Dict[str, Any]:
        """Convert to OpenAI API format."""
        msg = {"role": self.role.value, "content": self.content}
        if self.tool_calls:
            msg["tool_calls"] = [tc.to_dict() for tc in self.tool_calls]
        if self.tool_call_id:
            msg["tool_call_id"] = self.tool_call_id
        return msg
    
    def to_anthropic_format(self) -> Dict[str, Any]:
        """Convert to Anthropic API format."""
        if self.role == MessageRole.TOOL:
            return {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": self.tool_call_id,
                        "content": self.content,
                        "is_error": self.metadata.get("error", False),
                    }
                ],
            }
        msg = {"role": self.role.value, "content": self.content}
        if self.tool_calls:
            msg["tool_use"] = [tc.to_dict() for tc in self.tool_calls]
        return msg
