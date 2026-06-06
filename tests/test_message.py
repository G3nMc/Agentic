"""Tests for Message, ToolCall, ToolResult types."""

import pytest
from agent_core.core.message import Message, MessageRole, ToolCall, ToolResult


class TestMessageRole:
    def test_roles_exist(self):
        assert MessageRole.SYSTEM.value == "system"
        assert MessageRole.USER.value == "user"
        assert MessageRole.ASSISTANT.value == "assistant"
        assert MessageRole.TOOL.value == "tool"


class TestToolCall:
    def test_create_tool_call(self):
        tc = ToolCall(id="call_1", name="read_file", arguments={"path": "test.txt"})
        assert tc.id == "call_1"
        assert tc.name == "read_file"
        assert tc.arguments == {"path": "test.txt"}

    def test_to_dict(self):
        tc = ToolCall(id="call_1", name="read_file", arguments={"path": "test.txt"})
        d = tc.to_dict()
        assert d == {"id": "call_1", "name": "read_file", "arguments": {"path": "test.txt"}}

    def test_from_dict(self):
        d = {"id": "call_1", "name": "read_file", "arguments": {"path": "test.txt"}}
        tc = ToolCall.from_dict(d)
        assert tc.id == "call_1"
        assert tc.name == "read_file"
        assert tc.arguments == {"path": "test.txt"}

    def test_default_arguments(self):
        tc = ToolCall(id="call_1", name="list_files")
        assert tc.arguments == {}


class TestToolResult:
    def test_success_result(self):
        tr = ToolResult(tool_call_id="call_1", name="read_file", content="file contents")
        assert tr.is_success() is True
        assert tr.error is None

    def test_error_result(self):
        tr = ToolResult(tool_call_id="call_1", name="read_file", content="", error="File not found")
        assert tr.is_success() is False
        assert tr.error == "File not found"

    def test_to_dict(self):
        tr = ToolResult(tool_call_id="call_1", name="read_file", content="hello")
        d = tr.to_dict()
        assert d["tool_call_id"] == "call_1"
        assert d["name"] == "read_file"
        assert d["content"] == "hello"
        assert d["error"] is None

    def test_from_dict(self):
        d = {"tool_call_id": "call_1", "name": "read_file", "content": "hello", "error": None, "metadata": {}}
        tr = ToolResult.from_dict(d)
        assert tr.tool_call_id == "call_1"
        assert tr.name == "read_file"
        assert tr.content == "hello"


class TestMessage:
    def test_create_user_message(self):
        msg = Message(role=MessageRole.USER, content="Hello")
        assert msg.role == MessageRole.USER
        assert msg.content == "Hello"
        assert msg.tool_calls == []
        assert msg.tool_call_id is None

    def test_create_assistant_with_tool_calls(self):
        tc = ToolCall(id="call_1", name="read_file", arguments={"path": "test.txt"})
        msg = Message(role=MessageRole.ASSISTANT, content="", tool_calls=[tc])
        assert msg.role == MessageRole.ASSISTANT
        assert len(msg.tool_calls) == 1
        assert msg.tool_calls[0].name == "read_file"

    def test_create_tool_message(self):
        msg = Message(role=MessageRole.TOOL, content="result", tool_call_id="call_1")
        assert msg.role == MessageRole.TOOL
        assert msg.tool_call_id == "call_1"

    def test_to_dict(self):
        msg = Message(role=MessageRole.USER, content="Hello")
        d = msg.to_dict()
        assert d["role"] == "user"
        assert d["content"] == "Hello"

    def test_from_dict(self):
        d = {"role": "user", "content": "Hello", "tool_calls": [], "tool_call_id": None, "metadata": {}}
        msg = Message.from_dict(d)
        assert msg.role == MessageRole.USER
        assert msg.content == "Hello"

    def test_to_openai_format(self):
        msg = Message(role=MessageRole.USER, content="Hello")
        oai = msg.to_openai_format()
        assert oai == {"role": "user", "content": "Hello"}

    def test_to_openai_format_with_tool_calls(self):
        tc = ToolCall(id="call_1", name="read_file", arguments={"path": "test.txt"})
        msg = Message(role=MessageRole.ASSISTANT, content="", tool_calls=[tc])
        oai = msg.to_openai_format()
        assert oai["role"] == "assistant"
        assert len(oai["tool_calls"]) == 1

    def test_to_anthropic_format_tool_result(self):
        msg = Message(role=MessageRole.TOOL, content="result", tool_call_id="call_1")
        anthro = msg.to_anthropic_format()
        assert anthro["role"] == "user"
        assert isinstance(anthro["content"], list)
        assert anthro["content"][0]["type"] == "tool_result"
        assert anthro["content"][0]["tool_use_id"] == "call_1"
