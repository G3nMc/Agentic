"""Tests for tool executor."""

import pytest
from agent_core.tools.executor import ToolExecutor
from agent_core.tools.registry import ToolRegistry
from agent_core.tools.base import Tool, ToolResult
from agent_core.core.tool_schema import ToolSchema, ParameterSchema
from agent_core.config import AgentConfig


class EchoTool(Tool):
    name = "echo"
    description = "Echo the input"
    schema = ToolSchema(
        name="echo",
        description="Echo the input",
        parameters=ParameterSchema(
            type="object",
            properties={
                "message": ParameterSchema(type="string", description="Message to echo"),
            },
            required=["message"],
        ),
    )
    
    def execute(self, arguments):
        return ToolResult(
            tool_call_id=arguments.get("tool_call_id", ""),
            name=self.name,
            content=arguments["message"],
        )


class FailingTool(Tool):
    name = "fail"
    description = "Always fails"
    schema = ToolSchema(
        name="fail",
        description="Always fails",
        parameters=ParameterSchema(type="object", properties={}),
    )
    
    def execute(self, arguments):
        return ToolResult(
            tool_call_id=arguments.get("tool_call_id", ""),
            name=self.name,
            content="",
            error="Intentional failure",
        )


def test_executor_single():
    """Test single tool execution."""
    config = AgentConfig()
    registry = ToolRegistry()
    registry.register(EchoTool())
    
    executor = ToolExecutor(config, registry)
    
    results = executor.execute_batch([{"id": "1", "name": "echo", "arguments": {"message": "hello"}}])
    
    assert len(results) == 1
    assert results[0].is_success()
    assert results[0].content == "hello"


def test_executor_parallel():
    """Test parallel tool execution."""
    config = AgentConfig()
    config.parallel_tools = True
    registry = ToolRegistry()
    registry.register(EchoTool())
    
    executor = ToolExecutor(config, registry)
    
    tool_calls = [
        {"id": "1", "name": "echo", "arguments": {"message": "a"}},
        {"id": "2", "name": "echo", "arguments": {"message": "b"}},
        {"id": "3", "name": "echo", "arguments": {"message": "c"}},
    ]
    
    results = executor.execute_batch(tool_calls)
    
    assert len(results) == 3
    contents = {r.content for r in results}
    assert contents == {"a", "b", "c"}


def test_executor_unknown_tool():
    """Test execution of unknown tool."""
    config = AgentConfig()
    registry = ToolRegistry()
    
    executor = ToolExecutor(config, registry)
    
    results = executor.execute_batch([{"id": "1", "name": "unknown", "arguments": {}}])
    
    assert len(results) == 1
    assert not results[0].is_success()
    assert "not found" in results[0].error.lower()


def test_executor_validation_error():
    """Test argument validation."""
    config = AgentConfig()
    registry = ToolRegistry()
    registry.register(EchoTool())
    
    executor = ToolExecutor(config, registry)
    
    # Missing required argument
    results = executor.execute_batch([{"id": "1", "name": "echo", "arguments": {}}])
    
    assert len(results) == 1
    assert not results[0].is_success()
    assert "missing required" in results[0].error.lower()


def test_executor_tool_failure():
    """Test tool that returns error."""
    config = AgentConfig()
    registry = ToolRegistry()
    registry.register(FailingTool())
    
    executor = ToolExecutor(config, registry)
    
    results = executor.execute_batch([{"id": "1", "name": "fail", "arguments": {}}])
    
    assert len(results) == 1
    assert not results[0].is_success()
    assert results[0].error == "Intentional failure"
