"""Tests for tool registry."""

import pytest
from agent_core.tools.registry import ToolRegistry
from agent_core.tools.base import Tool, ToolResult
from agent_core.core.tool_schema import ToolSchema, ParameterSchema


class DummyTool(Tool):
    name = "dummy"
    description = "A dummy tool"
    schema = ToolSchema(
        name="dummy",
        description="A dummy tool",
        parameters=ParameterSchema(
            type="object",
            properties={
                "value": ParameterSchema(type="string", description="A value"),
            },
            required=["value"],
        ),
    )
    
    def execute(self, arguments):
        return ToolResult(
            tool_call_id=arguments.get("tool_call_id", ""),
            name=self.name,
            content=f"Executed with {arguments['value']}",
        )


def test_registry_register():
    """Test tool registration."""
    registry = ToolRegistry()
    tool = DummyTool()
    
    registry.register(tool)
    
    assert registry.has_tool("dummy")
    assert registry.get("dummy") == tool
    assert registry.get_schema("dummy") == tool.schema


def test_registry_unregister():
    """Test tool unregistration."""
    registry = ToolRegistry()
    tool = DummyTool()
    
    registry.register(tool)
    registry.unregister("dummy")
    
    assert not registry.has_tool("dummy")
    assert registry.get("dummy") is None


def test_registry_get_all():
    """Test getting all tools and schemas."""
    registry = ToolRegistry()
    tool1 = DummyTool()
    tool2 = DummyTool()
    tool2.name = "dummy2"
    tool2.schema = ToolSchema(
        name="dummy2",
        description="Another dummy",
        parameters=ParameterSchema(type="object", properties={}),
    )
    
    registry.register(tool1)
    registry.register(tool2)
    
    tools = registry.get_all_tools()
    schemas = registry.get_all_schemas()
    
    assert len(tools) == 2
    assert len(schemas) == 2


def test_registry_get_schemas_for_llm():
    """Test getting schemas in LLM format."""
    registry = ToolRegistry()
    tool = DummyTool()
    registry.register(tool)
    
    openai_schemas = registry.get_tool_schemas_for_llm("openai")
    anthropic_schemas = registry.get_tool_schemas_for_llm("anthropic")
    
    assert len(openai_schemas) == 1
    assert openai_schemas[0]["type"] == "function"
    assert openai_schemas[0]["function"]["name"] == "dummy"
    
    assert len(anthropic_schemas) == 1
    assert anthropic_schemas[0]["name"] == "dummy"
