"""Tests for ContextBuilder and SummarizationTrigger."""

import pytest
from multi_mode.core.context import ContextBuilder, ContextWindow, SummarizationTrigger
from multi_mode.core.message import Message, MessageRole
from multi_mode.core.state import WorkflowState
from multi_mode.config.agent import AgentConfig


class TestContextBuilder:
    @pytest.fixture
    def config(self):
        c = AgentConfig()
        c.token_budget = 10000
        c.system_prompt = "You are a helpful assistant."
        return c

    @pytest.fixture
    def builder(self, config):
        return ContextBuilder(config)

    @pytest.fixture
    def state(self, config):
        return WorkflowState.initial("Test task", config)

    def test_build_basic(self, builder, state):
        window = builder.build(state)
        assert isinstance(window, ContextWindow)
        assert len(window.messages) >= 1
        # Should have system prompt and user message
        roles = [m.role for m in window.messages]
        assert MessageRole.SYSTEM in roles
        assert MessageRole.USER in roles

    def test_build_with_project_context(self, builder, state):
        window = builder.build(state, project_context="Project: test")
        # Should have project context message
        contents = [m.content for m in window.messages]
        assert any("Project Context" in c for c in contents)

    def test_build_with_summary(self, builder, state):
        state.metadata["summary"] = "Previous conversation summary"
        window = builder.build(state)
        contents = [m.content for m in window.messages]
        assert any("Conversation Summary" in c for c in contents)

    def test_build_no_system_prompt(self, config):
        config.system_prompt = ""
        builder = ContextBuilder(config)
        state = WorkflowState.initial("Test", config)
        window = builder.build(state)
        roles = [m.role for m in window.messages]
        # Should not have system prompt
        assert MessageRole.SYSTEM not in roles or all(
            m.content != "" for m in window.messages if m.role == MessageRole.SYSTEM
        )

    def test_token_count(self, builder, state):
        window = builder.build(state)
        assert window.token_count > 0

    def test_truncation(self, config):
        config.token_budget = 50  # Very small budget
        builder = ContextBuilder(config)
        state = WorkflowState.initial("Test", config)
        # Add many messages
        for i in range(20):
            state.add_message(Message(role=MessageRole.USER, content=f"Message {i}" * 10))
        window = builder.build(state)
        # Should be truncated
        assert window.truncated is True
        assert window.token_count <= config.token_budget


class TestSummarizationTrigger:
    @pytest.fixture
    def config(self):
        c = AgentConfig()
        c.token_budget = 10000
        c.summarization_threshold = 0.7
        c.enable_summarization = True
        return c

    @pytest.fixture
    def trigger(self, config):
        return SummarizationTrigger(config)

    def test_should_summarize_below_threshold(self, trigger):
        assert trigger.should_summarize(5000) is False

    def test_should_summarize_above_threshold(self, trigger):
        assert trigger.should_summarize(8000) is True

    def test_should_summarize_at_threshold(self, trigger):
        threshold = int(10000 * 0.7)
        assert trigger.should_summarize(threshold) is False  # > not >=
        assert trigger.should_summarize(threshold + 1) is True

    def test_should_summarize_disabled(self, config):
        config.enable_summarization = False
        trigger = SummarizationTrigger(config)
        assert trigger.should_summarize(8000) is False


class TestContextWindow:
    def test_create_context_window(self):
        msg = Message(role=MessageRole.USER, content="Hello")
        window = ContextWindow(messages=[msg], token_count=10, truncated=False)
        assert len(window.messages) == 1
        assert window.token_count == 10
        assert window.truncated is False
        assert window.summary is None

    def test_context_window_with_summary(self):
        msg = Message(role=MessageRole.USER, content="Hello")
        window = ContextWindow(messages=[msg], token_count=10, truncated=True, summary="Summary text")
        assert window.summary == "Summary text"
