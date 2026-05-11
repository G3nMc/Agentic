"""Hugging Face Inference API / router backend."""
from __future__ import annotations

import sys

from .backend_base import ModelBackend


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


class HFBackend(ModelBackend):
    """Hugging Face Inference API / router backend."""

    def __init__(self, hf_token: str, model_id: str):
        if not hf_token:
            raise RuntimeError("HF backend requires --hf-token.")
        if not model_id:
            raise RuntimeError("HF backend requires --model.")
        from huggingface_hub import InferenceClient  # noqa: PLC0415
        self.hf_token = hf_token
        self.model_id = model_id
        self._client = InferenceClient(model=model_id, token=hf_token)
        _log(f"[HF:init] model={model_id} InferenceClient created")

    def chat(self, messages, max_tokens, temperature, tools=None):
        _log(
            f"[HF:chat] model={self.model_id} msgs={len(messages)} "
            f"max_tokens={max_tokens} temperature={temperature}"
        )
        try:
            resp = self._client.chat_completion(
                messages=messages,
                max_tokens=max_tokens,
                temperature=temperature,
            )
        except Exception as exc:
            _log(f"[HF:error] model={self.model_id} {type(exc).__name__}: {exc}")
            raise RuntimeError(f"HF error: {exc}") from exc

        choice = resp.choices[0]
        content = choice.message.content or ""
        finish_reason = getattr(choice, "finish_reason", None) or ""
        usage = getattr(resp, "usage", None)
        usage_tokens = int(getattr(usage, "total_tokens", 0) or 0) if usage else 0

        _log(
            f"[HF:done] model={self.model_id} "
            f"content_len={len(content)} finish_reason={finish_reason!r} "
            f"usage_tokens={usage_tokens}"
        )
        return content, finish_reason
