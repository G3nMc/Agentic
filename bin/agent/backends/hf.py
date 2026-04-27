"""Hugging Face Inference API / router backend (the original path)."""
from __future__ import annotations

from .backend_base import ModelBackend


class HFBackend(ModelBackend):
    """Hugging Face Inference API / router backend (the original path)."""

    def __init__(self, hf_token: str, model_id: str):
        if not hf_token:
            raise RuntimeError("HF backend requires --hf-token.")
        # Lazy import: only HF users pay the huggingface_hub import cost.
        from huggingface_hub import InferenceClient
        self.hf_token = hf_token
        self.model_id = model_id
        self._client = InferenceClient(model=model_id, token=hf_token)

    def chat(self, messages, max_tokens, temperature, tools=None):
        resp = self._client.chat_completion(
            messages=messages,
            max_tokens=max_tokens,
            temperature=temperature,
        )
        choice = resp.choices[0]
        content = choice.message.content or ""
        finish_reason = getattr(choice, "finish_reason", None) or ""
        return content, finish_reason
