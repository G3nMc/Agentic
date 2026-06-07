"""Backend factory for creating LLM backends from config."""

from typing import Optional

from multi_mode.backends.base import LLMBackend
from multi_mode.backends.openai import OpenAIBackend
from multi_mode.backends.anthropic import AnthropicBackend
from multi_mode.backends.gemini import GeminiBackend
from multi_mode.backends.ollama import OllamaBackend
from multi_mode.backends.openrouter import OpenRouterBackend
from multi_mode.config.models import ModelConfig

# Default base URLs for providers that are OpenAI-compatible
_OPENAI_COMPATIBLE_DEFAULTS: dict[str, str] = {
    "groq": "https://api.groq.com/openai/v1",
    "deepseek": "https://api.deepseek.com/v1",
    "mistral": "https://api.mistral.ai/v1",
    "xai": "https://api.x.ai/v1",
    "perplexity": "https://api.perplexity.ai",
    "custom": "",  # user must supply base_url
}


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
    elif provider in _OPENAI_COMPATIBLE_DEFAULTS:
        # Ensure a base_url is set; use default if not provided
        if not config.base_url:
            default_url = _OPENAI_COMPATIBLE_DEFAULTS[provider]
            if default_url:
                config.base_url = default_url
        return OpenAIBackend(config)
    else:
        raise ValueError(f"Unknown provider: {provider}")


def get_backend_for_config(config: ModelConfig) -> LLMBackend:
    """Get backend instance for a model config (raises if not found)."""
    backend = get_backend(config)
    if not backend:
        raise ValueError(f"No backend for config: {config}")
    return backend
