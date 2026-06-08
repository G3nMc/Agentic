"""Executor agent - deterministic tool execution."""

from __future__ import annotations

from typing import List

from ..core.state import WorkflowState
from ..core.message import ToolCall, Message, MessageRole
from ..tools.executor import ToolExecutor


class Executor:
    """Deterministic executor for tool calls.

    No LLM - just executes tools and returns structured results.
    """

    def __init__(self, tool_executor: ToolExecutor):
        self.tool_executor = tool_executor

    def run(self, state: WorkflowState, tool_calls: List[ToolCall]) -> WorkflowState:
        """Execute the given tool calls and update state."""
        # Convert ToolCall objects to dicts for the executor
        tool_call_dicts = [
            {"id": tc.id, "name": tc.name, "arguments": tc.arguments}
            for tc in tool_calls
        ]

        # Execute tools
        results = self.tool_executor.execute_batch(tool_call_dicts)

        # Add tool calls and results to state
        for tc in tool_calls:
            state.add_tool_call(tc)

        for result in results:
            state.add_tool_result(result)
            # Also add as a message for the conversation history

            msg = Message(
                role=MessageRole.TOOL,
                content=result.content if result.is_success() else f"Error: {result.error}",
                tool_call_id=result.tool_call_id,
                metadata={"tool_name": result.name, "error": result.error} if result.error else {"tool_name": result.name},
            )
            state.add_message(msg)

        state.clear_pending_tools()
        return state
