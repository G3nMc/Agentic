"""Tests for token counting utilities."""

import pytest
from agent_core.utils.token_counter import count_tokens, count_tokens_for_model, count_message_tokens


class TestCountTokens:
    def test_empty_string(self):
        assert count_tokens("") == 0

    def test_none_string(self):
        assert count_tokens(None) == 0

    def test_simple_text(self):
        result = count_tokens("Hello world")
        assert result > 0

    def test_long_text(self):
        result = count_tokens("a" * 1000)
        assert result > 0
        # Rough estimation: ~4 chars per token
        assert result >= 200  # At least 200 tokens

    def test_with_model(self):
        result = count_tokens("Hello world", model="gpt-4o")
        assert result > 0


class TestCountTokensForModel:
    def test_openai(self):
        result = count_tokens_for_model("Hello world", "openai", "gpt-4o")
        assert result > 0

    def test_anthropic_fallback(self):
        result = count_tokens_for_model("Hello world", "anthropic", "claude-3-5-sonnet")
        assert result > 0

    def test_ollama_fallback(self):
        result = count_tokens_for_model("Hello world", "ollama", "llama3.2")
        assert result > 0

    def test_empty_text(self):
        assert count_tokens_for_model("", "openai", "gpt-4o") == 0


class TestCountMessageTokens:
    def test_simple_message(self):
        msg = {"role": "user", "content": "Hello"}
        result = count_message_tokens(msg)
        assert result > 0

    def test_message_with_tool_calls(self):
        msg = {
            "role": "assistant",
            "content": "",
            "tool_calls": [{"id": "1", "name": "read_file", "arguments": {"path": "test.txt"}}],
        }
        result = count_message_tokens(msg)
        assert result > 0

    def test_message_object(self):
        from agent_core.core.message import Message, MessageRole
        msg = Message(role=MessageRole.USER, content="Hello")
        result = count_message_tokens(msg)
        assert result > 0
