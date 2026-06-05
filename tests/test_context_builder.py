"""Tests for context builder."""

import pytest
from agent_core.core.context import ContextBuilder, SummarizationTrigger
from agent_core.core.state import WorkflowState
from agent_core.core.message import Message, MessageRole
from agent_core.config import AgentConfig


def test_context_builder_basic():
    """Test basic context building."""
    config = AgentConfig()
    config.token_budget = 10000
    builder = ContextBuilder(config)
    
    state = WorkflowState()
    state.add_message(Message(role=MessageRole.USER, content="Test task"))
    
    context = builder.build(state)
    
    assert len(context.messages) >= 1
    assert context.token_count > 0
    assert not context.truncated


def test_context_builder_with_system_prompt():
    """Test context building with system prompt."""
    config = AgentConfig()
    config.system_prompt = "You are a helpful assistant."
    builder = ContextBuilder(config)
    
    state = WorkflowState()
    state.add_message(Message(role=MessageRole.USER, content="Test task"))
    
    context = builder.build(state)
    
    assert context.messages[0].role == MessageRole.SYSTEM
    assert context.messages[0].content == "You are a helpful assistant."
    assert context.messages[1].role == MessageRole.USER
    assert context.messages[1].content == "Test task"


def test_context_builder_with_project_context():
    """Test context building with project context."""
    config = AgentConfig()
    builder = ContextBuilder(config)
    
    state = WorkflowState()
    state.add_message(Message(role=MessageRole.USER, content="Test task"))
    
    context = builder.build(state, project_context="Project: test")
    
    assert any("Project Context" in msg.content for msg in context.messages)


def test_context_builder_truncation():
    """Test context truncation when over budget."""
    config = AgentConfig()
    config.token_budget = 100  # Very small budget
    builder = ContextBuilder(config)
    
    state = WorkflowState()
    # Add many messages
    for i in range(20):
        state.add_message(Message(role=MessageRole.USER, content=f"Message {i} " + "x" * 100))
    
    context = builder.build(state)
    
    assert context.truncated
    assert context.token_count <= config.token_budget


def test_summarization_trigger():
    """Test summarization trigger logic."""
    config = AgentConfig()
    config.token_budget = 1000
    config.summarization_threshold = 0.7
    config.enable_summarization = True
    
    trigger = SummarizationTrigger(config)
    
    # Below threshold
    assert not trigger.should_summarize(500)
    
    # Above threshold
    assert trigger.should_summarize(800)
    
    # Disabled
    config.enable_summarization = False
    trigger = SummarizationTrigger(config)
    assert not trigger.should_summarize(800)
