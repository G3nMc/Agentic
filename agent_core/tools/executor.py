"""Tool executor for running tool calls."""

from typing import List, Dict, Any
from concurrent.futures import ThreadPoolExecutor, as_completed

from agent_core.tools.registry import get_tool_registry
from agent_core.tools.base import ToolResult
from agent_core.config.agent import AgentConfig


class ToolExecutor:
    """Executes tool calls and returns results."""
    
    def __init__(self, config: AgentConfig, registry=None):
        self.config = config
        self.registry = registry or get_tool_registry()
    
    def execute_batch(self, tool_calls: List[Dict[str, Any]]) -> List[ToolResult]:
        """Execute multiple tool calls in parallel or sequentially."""
        results = []
        
        if self.config.parallel_tools and len(tool_calls) > 1:
            with ThreadPoolExecutor(max_workers=len(tool_calls)) as executor:
                futures = {executor.submit(self._execute_single, tc): tc for tc in tool_calls}
                for future in as_completed(futures):
                    results.append(future.result())
        else:
            for tc in tool_calls:
                results.append(self._execute_single(tc))
        
        return results
    
    def _execute_single(self, tool_call: Dict[str, Any]) -> ToolResult:
        """Execute a single tool call."""
        name = tool_call.get("name")
        arguments = tool_call.get("arguments", {})
        tool_call_id = tool_call.get("id", "")
        
        tool = self.registry.get(name)
        if not tool:
            return ToolResult(
                tool_call_id=tool_call_id,
                name=name,
                content="",
                error=f"Tool not found: {name}",
            )
        
        # Add tool_call_id to arguments for the tool
        arguments["tool_call_id"] = tool_call_id
        
        # Validate arguments
        is_valid, error = tool.validate_arguments(arguments)
        if not is_valid:
            return ToolResult(
                tool_call_id=tool_call_id,
                name=name,
                content="",
                error=error,
            )
        
        try:
            return tool.execute(arguments)
        except Exception as e:
            return ToolResult(
                tool_call_id=tool_call_id,
                name=name,
                content="",
                error=str(e),
            )
