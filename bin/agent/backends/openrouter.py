"""OpenRouter backend (single-agent mode) -- pure REST.

OpenRouter exposes an OpenAI-compatible chat/completions endpoint.
Get a key at https://openrouter.ai/keys.
"""

from __future__ import annotations

from agent.backends.openai_compat import OpenAICompatBackend


class OpenRouterBackend(OpenAICompatBackend):
    """OpenRouter OpenAI-compatible chat/completions."""

    DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"
    DEFAULT_CONTEXT_LIMIT = 128000

    def __init__(
        self,
        api_key: str,
        model_id: str,
        context_limit: int = DEFAULT_CONTEXT_LIMIT,
    ):
        super().__init__(api_key=api_key, model_id=model_id, label="OpenRouter")
        self._context_limit = int(context_limit)
        if self._context_limit <= 0:
            raise ValueError("OpenRouter context_limit must be greater than zero.")

    @property
    def context_limit(self) -> int:
        """Return the context window selected for the OpenRouter model.

        OpenRouter model IDs include a provider prefix and often cannot be
        resolved by the generic model lookup. Keeping the explicit catalog
        value prevents the orchestrator from trimming history against its
        conservative fallback.
        """
        return self._context_limit
