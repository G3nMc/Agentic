"""LLM Backend abstractions and implementations."""

from agent_core.backends.base import LLMBackend
from agent_core.backends.openai import OpenAIBackend
from agent_core.backends.anthropic import AnthropicBackend
from agent_core.backends.gemini import GeminiBackend
from agent_core.backends.ollama import OllamaBackend
from agent_core.backends.openrouter import OpenRouterBackend
from agent_core.backends.factory import get_backend, get_backend_for_config

__all__ = [
    "LLMBackend",
    "OpenAIBackend",
    "AnthropicBackend",
    "GeminiBackend",
    "OllamaBackend",
    "OpenRouterBackend",
    "get_backend",
    "get_backend_for_config",
]
