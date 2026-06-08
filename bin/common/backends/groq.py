"""Groq Cloud backend -- pure REST over the OpenAI-compatible endpoint.

Get an API key at https://console.groq.com/keys.

No SDK import. Inherits all the heavy lifting from
:class:`common.backends.openai_compat.OpenAICompatBackend`.
"""

from __future__ import annotations

from .openai_compat import OpenAICompatBackend


class GroqBackend(OpenAICompatBackend):
    """Groq Cloud OpenAI-compatible chat/completions."""

    DEFAULT_BASE_URL = "https://api.groq.com/openai/v1"

    def __init__(self, api_key: str, model_id: str):
        super().__init__(api_key=api_key, model_id=model_id, label="Groq")
