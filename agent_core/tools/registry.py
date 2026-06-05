"""Tool registry for managing available tools."""

from typing import Dict, List, Optional

from agent_core.core.tool_schema import ToolSchema
from agent_core.tools.base import Tool


class ToolRegistry:
    """Registry for managing available tools."""
    
    def __init__(self):
        self._tools: Dict[str, Tool] = {}
        self._schemas: Dict[str, ToolSchema] = {}
    
    def register(self, tool: Tool) -> None:
        """Register a tool."""
        self._tools[tool.name] = tool
        self._schemas[tool.name] = tool.schema
    
    def unregister(self, name: str) -> None:
        """Unregister a tool."""
        self._tools.pop(name, None)
        self._schemas.pop(name, None)
    
    def get(self, name: str) -> Optional[Tool]:
        """Get a tool by name."""
        return self._tools.get(name)
    
    def get_schema(self, name: str) -> Optional[ToolSchema]:
        """Get a tool schema by name."""
        return self._schemas.get(name)
    
    def get_all_tools(self) -> List[Tool]:
        """Get all registered tools."""
        return list(self._tools.values())
    
    def get_all_schemas(self) -> List[ToolSchema]:
        """Get all tool schemas."""
        return list(self._schemas.values())
    
    def has_tool(self, name: str) -> bool:
        """Check if a tool is registered."""
        return name in self._tools
    
    def get_tool_schemas_for_llm(self, format: str = "openai") -> List[Dict[str, Any]]:
        """Get tool schemas in the format expected by the LLM."""
        schemas = []
        for schema in self._schemas.values():
            if format == "openai":
                schemas.append(schema.to_json_schema())
            elif format == "anthropic":
                schemas.append(schema.to_anthropic_format())
            elif format == "gemini":
                schemas.append(schema.to_gemini_format())
            else:
                schemas.append(schema.to_json_schema())
        return schemas


# Global registry instance
_registry = ToolRegistry()


def get_tool_registry() -> ToolRegistry:
    """Get the global tool registry."""
    return _registry


def register_tool(tool: Tool) -> None:
    """Register a tool globally."""
    _registry.register(tool)
