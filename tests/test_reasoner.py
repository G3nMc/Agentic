"""Tests for reasoner (mocked backend)."""

import pytest
from unittest.mock import Mock, patch
from multi_mode.agents.reasoner import Reasoner
from multi_mode.core.message import Message, MessageRole
from multi_mode.core.loop import ReasonerOutput
from multi_mode.backends.base import CompletionResponse
from multi_mode.config import AgentConfig, ModelConfig, ModelRole


def test_reasoner_initialization():
    """Test reasoner initialization."""
    config = AgentConfig()
    config.models[ModelRole.REASONER] = ModelConfig(
        role=ModelRole.REASONER,
        provider="openai",
        model="gpt-4o",
    )
    
    with patch("multi_mode.agents.reasoner.get_backend") as mock_get_backend:
        mock_backend = Mock()
        mock_backend.get_tool_format.return_value = "openai"
        mock_get_backend.return_value = mock_backend
        
        reasoner = Reasoner(config)
        assert reasoner.backend == mock_backend


def test_reasoner_parse_tool_calls():
    """Test parsing tool calls from response."""
    config = AgentConfig()
    config.models[ModelRole.REASONER] = ModelConfig(
        role=ModelRole.REASONER,
        provider="openai",
        model="gpt-4o",
    )
    
    with patch("multi_mode.agents.reasoner.get_backend") as mock_get_backend:
        mock_backend = Mock()
        mock_backend.get_tool_format.return_value = "openai"
        mock_get_backend.return_value = mock_backend
        
        reasoner = Reasoner(config)
        
        # Mock response with tool calls
        response = CompletionResponse(
            content=None,
            tool_calls=[
                {"id": "call_1", "name": "read_file", "arguments": {"path": "test.py"}},
                {"id": "call_2", "name": "write_file", "arguments": {"path": "out.py", "content": "hello"}},
            ],
        )
        
        output = reasoner._parse_response(response)
        
        assert len(output.tool_calls) == 2
        assert output.tool_calls[0]["name"] == "read_file"
        assert output.tool_calls[0]["arguments"]["path"] == "test.py"
        assert output.tool_calls[1]["name"] == "write_file"
        assert output.final_answer is None


def test_reasoner_parse_final_answer():
    """Test parsing final answer from response."""
    config = AgentConfig()
    config.models[ModelRole.REASONER] = ModelConfig(
        role=ModelRole.REASONER,
        provider="openai",
        model="gpt-4o",
    )
    
    with patch("multi_mode.agents.reasoner.get_backend") as mock_get_backend:
        mock_backend = Mock()
        mock_backend.get_tool_format.return_value = "openai"
        mock_get_backend.return_value = mock_backend
        
        reasoner = Reasoner(config)
        
        # Mock response with final answer
        response = CompletionResponse(
            content="Task completed successfully.",
            tool_calls=[],
        )
        
        output = reasoner._parse_response(response)
        
        assert output.final_answer == "Task completed successfully."
        assert output.tool_calls == []


def test_reasoner_parse_empty():
    """Test parsing empty response."""
    config = AgentConfig()
    config.models[ModelRole.REASONER] = ModelConfig(
        role=ModelRole.REASONER,
        provider="openai",
        model="gpt-4o",
    )
    
    with patch("multi_mode.agents.reasoner.get_backend") as mock_get_backend:
        mock_backend = Mock()
        mock_backend.get_tool_format.return_value = "openai"
        mock_get_backend.return_value = mock_backend
        
        reasoner = Reasoner(config)
        
        response = CompletionResponse(content=None, tool_calls=[])
        output = reasoner._parse_response(response)
        
        assert output.reasoning == "No valid response from model"
        assert output.final_answer is None
        assert output.tool_calls == []
