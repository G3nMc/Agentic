"""Tests for token counter utility."""

import pytest
from agent_core.utils.token_counter import count_tokens, count_tokens_for_model


def test_count_tokens_basic():
    """Test basic token counting."""
    text = "Hello, world!"
    count = count_tokens(text)
    assert count > 0
    assert count < len(text)  # Should be less than char count


def test_count_tokens_empty():
    """Test token counting with empty string."""
    assert count_tokens("") == 0
    assert count_tokens(None) == 0


def test_count_tokens_long_text():
    """Test token counting with longer text."""
    text = "This is a longer piece of text that should have more tokens. " * 10
    count = count_tokens(text)
    assert count > 20


def test_count_tokens_for_model_openai():
    """Test model-specific token counting for OpenAI."""
    text = "Test message for token counting."
    count = count_tokens_for_model(text, "openai", "gpt-4o")
    assert count > 0


def test_count_tokens_for_model_anthropic():
    """Test model-specific token counting for Anthropic (fallback)."""
    text = "Test message for token counting."
    count = count_tokens_for_model(text, "anthropic", "claude-3-5-sonnet")
    assert count > 0


def test_count_message_tokens():
    """Test token counting for message objects."""
    from agent_core.utils.token_counter import count_message_tokens
    from agent_core.core.message import Message, MessageRole, ToolCall
    
    msg = Message(
        role=MessageRole.USER,
        content="Hello",
        tool_calls=[ToolCall(id="1", name="test", arguments={"arg": "value"})]
    )
    count = count_message_tokens(msg, "openai", "gpt-4o")
    assert count > 0


def test_count_message_tokens_dict():
    """Test token counting for message dicts."""
    from agent_core.utils.token_counter import count_message_tokens
    
    msg = {
        "role": "user",
        "content": "Hello",
        "tool_calls": [{"id": "1", "name": "test", "arguments": {"arg": "value"}}]
    }
    count = count_message_tokens(msg, "openai", "gpt-4o")
    assert count > 0
