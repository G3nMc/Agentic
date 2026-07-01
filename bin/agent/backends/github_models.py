"""GitHub Models backend -- pure REST over the OpenAI-compatible endpoint.

PAT scope: ``models:read``. Create at
https://github.com/settings/personal-access-tokens/new.

Model IDs are namespaced (e.g. ``openai/gpt-4o``,
``meta/Llama-3.3-70B-Instruct``).
"""

from __future__ import annotations

from .openai_compat import OpenAICompatBackend


class GitHubModelsBackend(OpenAICompatBackend):
    """GitHub Models OpenAI-compatible chat/completions."""

    DEFAULT_BASE_URL = "https://models.github.ai/inference"

    def __init__(self, api_key: str, model_id: str):
        super().__init__(api_key=api_key, model_id=model_id, label="GitHubModels")
