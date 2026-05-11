"""Model backends + a tiny factory.

Adding a backend is a two-step change:
  1. Create ``agent/backends/<name>.py`` with a class subclassing
     :class:`~agent.backends.backend_base.ModelBackend`.
  2. Add it to :func:`build_backend` and to the ``--backend`` choices
     list in ``bin/orchestrator.py``.
"""
from __future__ import annotations

import sys as _sys
_sys.dont_write_bytecode = True

from .backend_base import ModelBackend, RateLimitedBackend
from .openai_compat import OpenAICompatBackend, RateLimitError, ToolsNotSupportedError

__all__ = [
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
        from .hf import HFBackend
        return HFBackend(**kwargs)
    if name == "ollama":
        from .ollama import OllamaBackend
        return OllamaBackend(**kwargs)
    if name == "groq":
        from .groq import GroqBackend
        return GroqBackend(**kwargs)
    if name == "gemini":
        from .gemini import GeminiBackend
        return GeminiBackend(**kwargs)
    if name == "openrouter":
        from .openrouter import OpenRouterBackend
        return OpenRouterBackend(**kwargs)
    if name == "github":
        from .github_models import GitHubModelsBackend
        return GitHubModelsBackend(**kwargs)
    raise ValueError(f"Unknown backend: {name!r}")
