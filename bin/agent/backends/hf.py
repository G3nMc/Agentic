"""HuggingFace Inference router backend -- pure REST.

The HF Inference router exposes an OpenAI-compatible chat/completions
endpoint at ``/v1/chat/completions``. Tokens from
https://huggingface.co/settings/tokens.

No ``huggingface_hub`` import.
"""

from __future__ import annotations

from .openai_compat import OpenAICompatBackend


class HFBackend(OpenAICompatBackend):
    """HuggingFace Inference router OpenAI-compatible chat completions."""

    DEFAULT_BASE_URL = "https://router.huggingface.co/v1"

    def __init__(self, hf_token: str = "", model_id: str = "", **kwargs):
        # Tolerate the older keyword ``hf_token`` used by the
        # ``build_backend("huggingface", hf_token=...)`` factory call.
        api_key = hf_token or kwargs.pop("api_key", "")
        super().__init__(api_key=api_key, model_id=model_id, label="HF")
