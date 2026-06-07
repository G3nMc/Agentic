"""Agent Core - Multi-Agent Workflow"""

__version__ = "0.3.0"

from .config.agent import AgentConfig, load_config_from_env
from .config.models import ModelConfig, ModelRole
from .core.message import Message, MessageRole, ToolCall, ToolResult
from .core.state import WorkflowState, TaskStatus
from .loop.orchestrator import Orchestrator, WorkflowResult

__all__ = [
    "AgentConfig",
    "load_config_from_env",
    "ModelConfig",
    "ModelRole",
    "Message",
    "MessageRole",
    "ToolCall",
    "ToolResult",
    "WorkflowState",
    "TaskStatus",
    "Orchestrator",
    "WorkflowResult",
]
