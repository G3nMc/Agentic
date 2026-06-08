"""OpenRouter backend for multi_mode -- pure REST.

OpenRouter exposes an OpenAI-compatible chat/completions endpoint, so
this is a thin subclass that just sets the base URL. No SDK.
"""

from __future__ import annotations

from ..config.models import ModelConfig
from .openai import OpenAIBackend


class OpenRouterBackend(OpenAIBackend):
    """OpenRouter OpenAI-compatible chat/completions."""

    DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"

    def __init__(self, config: ModelConfig):
        # If the user didn't override base_url, point to OpenRouter.
        if not config.base_url:
            config.base_url = self.DEFAULT_BASE_URL
        super().__init__(config)
