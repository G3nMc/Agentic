"""LLM Backend abstractions and implementations."""

from  base import LLMBackend
from  openai import OpenAIBackend
from  anthropic import AnthropicBackend
from gemini import GeminiBackend
from  ollama import OllamaBackend
from openrouter import OpenRouterBackend
from  factory import get_backend, get_backend_for_config

# Also expose the old-style backends and factory
from bin.common.backends.backend_base import ModelBackend, RateLimitedBackend
from bin.common.backends.openai_compat import OpenAICompatBackend, RateLimitError, ToolsNotSupportedError

__all__ = [
    "LLMBackend",
    "OpenAIBackend",
    "AnthropicBackend",
    "GeminiBackend",
    "OllamaBackend",
    "OpenRouterBackend",
    "get_backend",
    "get_backend_for_config",
    "ModelBackend",
    "RateLimitedBackend",
    "OpenAICompatBackend",
    "RateLimitError",
    "ToolsNotSupportedError",
    "build_backend",
]


def build_backend(name: str, **kwargs) -> ModelBackend:
    """Construct a backend by name. Imports are lazy so a user who only
    needs Ollama doesn't have to install groq/google-genai."""
    name = name.lower().strip()
    if name == "huggingface":
        from bin.common.backends.hf import HFBackend

        return HFBackend(**kwargs)
    if name == "ollama":
        from .ollama import OllamaBackend

        return OllamaBackend(**kwargs)
    if name == "groq":
        from bin.common.backends.groq import GroqBackend

        return GroqBackend(**kwargs)
    if name == "gemini":
        from .gemini import GeminiBackend

        return GeminiBackend(**kwargs)
    if name == "openrouter":
        from .openrouter import OpenRouterBackend

        return OpenRouterBackend(**kwargs)
    if name == "github":
        from bin.common.backends.github_models import GitHubModelsBackend

        return GitHubModelsBackend(**kwargs)
    raise ValueError(f"Unknown backend: {name!r}")
