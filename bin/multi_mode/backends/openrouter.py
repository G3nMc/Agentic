"""OpenRouter API backend (OpenAI-compatible)."""

from typing import List, Dict, Any, Optional

from multi_mode.backends.openai import OpenAIBackend
from multi_mode.config.models import ModelConfig


class OpenRouterBackend(OpenAIBackend):
    """OpenRouter API backend (OpenAI-compatible)."""
    
    def __init__(self, config: ModelConfig):
        # OpenRouter uses OpenAI-compatible API
        super().__init__(config)
        self.client.base_url = config.base_url or "https://openrouter.ai/api/v1"
        # Add OpenRouter specific headers
        self.client.default_headers = {
            "HTTP-Referer": "https://github.com/agent-core",
            "X-Title": "Agent Core",
        }
