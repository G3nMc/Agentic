"""Per-model context-window limits for backends that don't expose one
explicitly.

Backends like Ollama know their context window directly (``num_ctx`` is a
constructor arg). Cloud backends (Gemini, Groq, OpenRouter, GitHub
Models, Hugging Face) don't — the limit is a property of the model
itself. This module keeps a small lookup table so each backend can
expose a uniform ``context_limit`` property without duplicating the
table in five files.

The numbers are conservative — when a model advertises a 200K window,
we report slightly less to leave headroom for output tokens and
provider-side accounting overhead. Adjust upward only after observing
real responses; over-reporting causes the compactor to do nothing
useful.
"""
from __future__ import annotations


# Default fallback when the model id isn't recognised.
DEFAULT_CONTEXT_LIMIT = 8192


# Family-prefix → token limit. Matched by ``model_id.lower().startswith(prefix)``
# so order matters: list the most-specific prefixes first.
_FAMILY_LIMITS = (
    # Anthropic Claude (via OpenRouter / Bedrock proxies)
    ("anthropic/claude-3-haiku", 200_000),
    ("anthropic/claude-3-sonnet", 200_000),
    ("anthropic/claude-3-opus", 200_000),
    ("anthropic/claude-3.5", 200_000),
    ("anthropic/claude-3.7", 200_000),
    ("anthropic/claude-4", 200_000),
    ("anthropic/claude", 200_000),
    ("claude-", 200_000),
    # Google Gemini
    ("google/gemini-2.5-pro", 1_000_000),
    ("google/gemini-2.5-flash", 1_000_000),
    ("google/gemini-1.5-pro", 1_000_000),
    ("google/gemini-1.5-flash", 1_000_000),
    ("gemini-2.5-pro", 1_000_000),
    ("gemini-2.5-flash", 1_000_000),
    ("gemini-1.5", 1_000_000),
    ("gemini-2.0", 1_000_000),
    ("gemini", 32_768),
    # OpenAI
    ("openai/gpt-4o", 128_000),
    ("openai/gpt-4-turbo", 128_000),
    ("openai/gpt-4", 8_192),
    ("openai/gpt-3.5", 16_385),
    ("openai/o1", 128_000),
    ("openai/o3", 200_000),
    ("gpt-4o", 128_000),
    ("gpt-4-turbo", 128_000),
    ("gpt-4", 8_192),
    ("gpt-3.5", 16_385),
    ("o1-", 128_000),
    ("o3-", 200_000),
    # Meta Llama
    ("meta-llama/llama-3.1", 128_000),
    ("meta-llama/llama-3.2", 128_000),
    ("meta-llama/llama-3.3", 128_000),
    ("meta-llama/llama-3", 8_192),
    ("meta/llama-3.3", 128_000),
    ("meta/llama-3", 8_192),
    ("llama-3.1", 128_000),
    ("llama-3.2", 128_000),
    ("llama-3.3", 128_000),
    ("llama-3", 8_192),
    # Mistral
    ("mistral-large", 128_000),
    ("mistral-medium", 32_768),
    ("mistral-small", 32_768),
    ("mistralai/mixtral", 32_768),
    ("mistralai/mistral", 32_768),
    ("mistral-ai/mistral", 32_768),
    # Qwen
    ("qwen2.5-coder", 32_768),
    ("qwen2.5", 32_768),
    ("qwen3", 32_768),
    ("qwen", 32_768),
    # GLM (ZhipuAI / Ollama Cloud)
    ("glm-4.5", 128_000),
    ("glm-4.6", 128_000),
    ("glm-5", 128_000),
    ("glm", 32_768),
    # DeepSeek
    ("deepseek-coder", 32_768),
    ("deepseek-chat", 32_768),
    ("deepseek/", 32_768),
    ("deepseek", 32_768),
    # Gemma (Ollama / Google)
    ("gemma-3", 128_000),
    ("gemma-2", 8_192),
    ("gemma", 8_192),
    # GPT-OSS (cloud-hosted open-source models)
    ("gpt-oss", 32_768),
    # Phi
    ("phi-3", 128_000),
    ("phi3", 4_096),
    ("phi-2", 2_048),
    # Groq-hosted families that don't match the prefixes above
    ("llama3-70b", 8_192),
    ("llama3-8b", 8_192),
    ("mixtral-8x7b", 32_768),
)


def lookup_context_limit(model_id: str, *, default: int = DEFAULT_CONTEXT_LIMIT) -> int:
    """Best-effort context-window estimate for a model id.

    Returns ``default`` (8192) when the model id is unknown — that's a
    safe lower bound for almost every modern chat model. Callers that
    know better (e.g. Ollama with ``num_ctx``) should override.
    """
    if not model_id:
        return default
    mid = model_id.lower().strip()
    # Strip provider prefix like "groq/" or trailing tags like ":cloud",
    # ":latest", ":128k" so "glm-5.1:cloud" matches the "glm-5" entry.
    base = mid.split(":", 1)[0]
    for prefix, limit in _FAMILY_LIMITS:
        if base.startswith(prefix) or mid.startswith(prefix):
            return limit
    return default
