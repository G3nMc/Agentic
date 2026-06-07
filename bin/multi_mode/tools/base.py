"""Base tool classes."""

from abc import ABC, abstractmethod
from typing import Dict, Any, Optional

from multi_mode.core.tool_schema import ToolSchema
from multi_mode.core.message import ToolResult


class Tool(ABC):
    """Base class for all tools."""
    
    name: str
    description: str
    schema: ToolSchema
    
    @abstractmethod
    def execute(self, arguments: Dict[str, Any]) -> ToolResult:
        """Execute the tool with given arguments."""
        pass
    
    def validate_arguments(self, arguments: Dict[str, Any]) -> tuple[bool, Optional[str]]:
        """Validate arguments against schema.
        
        Returns:
            (is_valid, error_message)
        """
        # Basic validation - check required fields
        required = self.schema.parameters.required
        for field in required:
            if field not in arguments:
                return False, f"Missing required field: {field}"
        return True, None
