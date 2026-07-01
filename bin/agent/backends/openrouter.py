"""OpenRouter backend (single-agent mode) -- pure REST.

OpenRouter exposes an OpenAI-compatible chat/completions endpoint.
Get a key at https://openrouter.ai/keys.
"""

from __future__ import annotations

from agent.backends.openai_compat import OpenAICompatBackend


class OpenRouterBackend(OpenAICompatBackend):
    """OpenRouter OpenAI-compatible chat/completions."""

    DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"

    def __init__(self, api_key: str, model_id: str):
        super().__init__(api_key=api_key, model_id=model_id, label="OpenRouter")
