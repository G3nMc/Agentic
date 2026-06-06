"""Tests for WorkflowState and TaskStatus."""

import pytest
from agent_core.core.state import WorkflowState, TaskStatus, TraceEntry
from agent_core.core.message import Message, MessageRole, ToolCall, ToolResult
from agent_core.config.agent import AgentConfig


class TestTaskStatus:
    def test_status_values(self):
        assert TaskStatus.PENDING.value == "pending"
        assert TaskStatus.IN_PROGRESS.value == "in_progress"
        assert TaskStatus.COMPLETED.value == "completed"
        assert TaskStatus.FAILED.value == "failed"
        assert TaskStatus.NEEDS_REVISION.value == "needs_revision"


class TestWorkflowState:
    @pytest.fixture
    def config(self):
        return AgentConfig()

    @pytest.fixture
    def state(self, config):
        return WorkflowState.initial("Test task", config)

    def test_initial_state(self, state):
        assert state.status == TaskStatus.IN_PROGRESS
        assert state.iteration == 0
        assert len(state.messages) == 1
        assert state.messages[0].role == MessageRole.USER
        assert state.messages[0].content == "Test task"

    def test_is_terminal_completed(self, state):
        state.mark_completed()
        assert state.is_terminal() is True

    def test_is_terminal_failed(self, state):
        state.mark_failed("error")
        assert state.is_terminal() is True

    def test_is_terminal_in_progress(self, state):
        assert state.is_terminal() is False

    def test_add_message(self, state):
        msg = Message(role=MessageRole.ASSISTANT, content="Hello")
        state.add_message(msg)
        assert len(state.messages) == 2
        assert state.messages[-1].content == "Hello"

    def test_add_tool_call(self, state):
        tc = ToolCall(id="call_1", name="read_file", arguments={"path": "test.txt"})
        state.add_tool_call(tc)
        assert len(state.pending_tool_calls) == 1
        assert state.pending_tool_calls[0].name == "read_file"

    def test_add_tool_result(self, state):
        tr = ToolResult(tool_call_id="call_1", name="read_file", content="data")
        state.add_tool_result(tr)
        assert len(state.tool_results) == 1
        assert state.tool_results[0].content == "data"

    def test_clear_pending_tools(self, state):
        tc = ToolCall(id="call_1", name="read_file", arguments={})
        state.add_tool_call(tc)
        assert len(state.pending_tool_calls) == 1
        state.clear_pending_tools()
        assert len(state.pending_tool_calls) == 0

    def test_mark_completed(self, state):
        state.mark_completed()
        assert state.status == TaskStatus.COMPLETED

    def test_mark_failed(self, state):
        state.mark_failed("Something went wrong")
        assert state.status == TaskStatus.FAILED
        assert state.metadata["error"] == "Something went wrong"

    def test_mark_in_progress(self, state):
        state.mark_completed()
        state.mark_in_progress()
        assert state.status == TaskStatus.IN_PROGRESS

    def test_add_trace(self, state):
        state.add_trace("reasoner", output="Called read_file")
        assert len(state.trace) == 1
        assert state.trace[0].agent == "reasoner"
        assert state.trace[0].output == "Called read_file"

    def test_get_trace(self, state):
        state.add_trace("reasoner", output="Step 1")
        state.add_trace("executor", output="Step 2")
        trace = state.get_trace()
        assert len(trace) == 2
        assert trace[0]["agent"] == "reasoner"
        assert trace[1]["agent"] == "executor"


class TestTraceEntry:
    def test_create_trace_entry(self):
        te = TraceEntry(agent="reasoner", output="Test", tokens=100)
        assert te.agent == "reasoner"
        assert te.output == "Test"
        assert te.tokens == 100

    def test_to_dict(self):
        te = TraceEntry(agent="reasoner", output="Test", detail="More info", tokens=100)
        d = te.to_dict()
        assert d["agent"] == "reasoner"
        assert d["output"] == "Test"
        assert d["detail"] == "More info"
        assert d["tokens"] == 100

    def test_to_dict_minimal(self):
        te = TraceEntry(agent="executor", output="Done")
        d = te.to_dict()
        assert d["agent"] == "executor"
        assert d["output"] == "Done"
        assert "detail" not in d
        assert "tokens" not in d
