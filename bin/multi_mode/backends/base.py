"""Base LLM Backend interface."""

from abc import ABC, abstractmethod
from typing import List, Dict, Any, Optional
from dataclasses import dataclass

from ..config.models import ModelConfig


@dataclass
class CompletionResponse:
    """Structured response from LLM completion."""
    content: Optional[str] = None
    tool_calls: List[Dict[str, Any]] = None
    finish_reason: str = "stop"
    usage: Dict[str, int] = None
    
    def __post_init__(self):
        if self.tool_calls is None:
            self.tool_calls = []
        if self.usage is None:
            self.usage = {}


class LLMBackend(ABC):
    """Abstract base class for LLM backends."""
    
    def __init__(self, config: ModelConfig):
        self.config = config
    
    @abstractmethod
    def complete(
        self,
        messages: List[Dict[str, Any]],
        tools: Optional[List[Dict[str, Any]]] = None,
        **kwargs
    ) -> CompletionResponse:
        """Complete a chat conversation.
        
        Args:
            messages: List of message dicts in OpenAI format
            tools: Optional list of tool schemas in OpenAI format
            **kwargs: Additional provider-specific parameters
        
        Returns:
            CompletionResponse with content, tool_calls, and metadata
        """
        pass
    
    @abstractmethod
    def count_tokens(self, text: str) -> int:
        """Count tokens for the given text using provider's tokenizer."""
        pass
    
    def supports_native_tools(self) -> bool:
        """Whether this backend supports native function calling."""
        return True
    
    def get_tool_format(self) -> str:
        """Get the tool schema format this backend expects."""
        return "openai"  # Default to OpenAI format
