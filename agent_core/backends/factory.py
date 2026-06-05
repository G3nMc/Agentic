"""Backend factory for creating LLM backends from config."""

from typing import Optional

from agent_core.backends.base import LLMBackend
from agent_core.backends.openai import OpenAIBackend
from agent_core.backends.anthropic import AnthropicBackend
from agent_core.backends.gemini import GeminiBackend
from agent_core.backends.ollama import OllamaBackend
from agent_core.backends.openrouter import OpenRouterBackend
from agent_core.config.models import ModelConfig


def get_backend(config: Optional[ModelConfig]) -> Optional[LLMBackend]:
    """Get backend instance for a model config."""
    if not config:
        return None
    
    provider = config.provider.lower()
    
    if provider == "openai":
        return OpenAIBackend(config)
    elif provider == "anthropic":
        return AnthropicBackend(config)
    elif provider == "gemini":
        return GeminiBackend(config)
    elif provider == "ollama":
        return OllamaBackend(config)
    elif provider == "openrouter":
        return OpenRouterBackend(config)
    else:
        raise ValueError(f"Unknown provider: {provider}")


def get_backend_for_config(config: ModelConfig) -> LLMBackend:
    """Get backend instance for a model config (raises if not found)."""
    backend = get_backend(config)
    if not backend:
        raise ValueError(f"No backend for config: {config}")
    return backend
