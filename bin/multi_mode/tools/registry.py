"""Tool registry for managing available tools."""

from typing import Any, Dict, List, Optional

from ..core.tool_schema import ToolSchema
from .base import Tool


class ToolRegistry:
    """Registry for managing available tools."""
    
    def __init__(self):

        self._tools: Dict[str, Tool] = {}

        self._schemas: Dict[str, ToolSchema] = {}

        self._timeouts: Dict[str, float] = {
            "read_file": 20.0,
            "read_files": 60.0,
            "write_file": 20.0,
            "append_file": 20.0,
            "delete_file": 10.0,
            "patch_file": 25.0,
            "move_file": 20.0,
            "create_directory": 10.0,
            "list_files": 60.0,
            "list_files_recursive": 125.0,
            "search_in_files": 60.0,
            "find_files": 60.0,
            "git_status": 10.0,
            "git_branches": 5.0,
            "git_log": 10.0,
            "git_diff": 15.0,
            "git_checkout": 10.0,
            "git_commit": 15.0,
            "flutter_analyze": 45.0,
            "python_check": 30.0,
            "python_lint": 30.0,
            "python_format": 30.0,
            "python_test": 60.0,
            "run_command": 30.0,
            "web_fetch": 20.0,
            "web_search": 20.0,
        }

    

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

    

    def get_tool_schemas_for_llm(self, llm_format: str = "openai") -> List[Dict[str, Any]]:

        """Get tool schemas in the format expected by the LLM."""

        schemas = []

        for schema in self._schemas.values():

            if llm_format == "openai":

                schemas.append(schema.to_json_schema())

            elif llm_format == "anthropic":

                schemas.append(schema.to_anthropic_format())

            elif llm_format == "gemini":

                schemas.append(schema.to_gemini_format())

            else:

                schemas.append(schema.to_json_schema())

        return schemas
    

    def get_tool_timeout(self, name: str) -> float:

        """Get timeout for a specific tool."""

        return self._timeouts.get(name, 30.0)


# Global registry instance
_registry = ToolRegistry()


def get_tool_registry() -> ToolRegistry:
    """Get the global tool registry."""
    return _registry


def register_tool(tool: Tool) -> None:
    """Register a tool globally."""
    _registry.register(tool)
