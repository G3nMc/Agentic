"""Accurate token counting per provider."""

from typing import Optional

# Try to import tiktoken for OpenAI models
try:
    import tiktoken
    HAS_TIKTOKEN = True
except ImportError:
    HAS_TIKTOKEN = False

# Try to import anthropic for token counting
try:
    from anthropic import Anthropic
    HAS_ANTHROPIC = True
except ImportError:
    HAS_ANTHROPIC = False


# Model to encoding mapping for tiktoken
MODEL_ENCODINGS = {
    # OpenAI
    "gpt-4o": "o200k_base",
    "gpt-4o-mini": "o200k_base",
    "gpt-4-turbo": "cl100k_base",
    "gpt-4": "cl100k_base",
    "gpt-3.5-turbo": "cl100k_base",
    # Anthropic (approximate with cl100k_base)
    "claude-3-5-sonnet": "cl100k_base",
    "claude-3-opus": "cl100k_base",
    "claude-3-sonnet": "cl100k_base",
    "claude-3-haiku": "cl100k_base",
    # Others default to cl100k_base
}


def get_encoding_for_model(model: str):
    """Get tiktoken encoding for a model."""
    if not HAS_TIKTOKEN:
        return None
    
    model_lower = model.lower()
    for key, encoding in MODEL_ENCODINGS.items():
        if key in model_lower:
            try:
                return tiktoken.get_encoding(encoding)
            except Exception:
                pass
    # Default
    try:
        return tiktoken.get_encoding("cl100k_base")
    except Exception:
        return None


def count_tokens(text: str, model: Optional[str] = None) -> int:
    """Count tokens in text.
    
    Uses tiktoken for OpenAI-compatible models, falls back to character estimation.
    """
    if not text:
        return 0
    
    # Try tiktoken first
    if HAS_TIKTOKEN:
        encoding = get_encoding_for_model(model or "")
        if encoding:
            try:
                return len(encoding.encode(text))
            except Exception:
                pass
    
    # Fallback: rough estimation (4 chars per token)
    return len(text) // 4


def count_tokens_for_model(text: str, provider: str, model: str) -> int:
    """Count tokens using provider-specific method."""
    if not text:
        return 0
    
    provider_lower = provider.lower()
    
    if provider_lower == "openai" or provider_lower == "openrouter":
        return count_tokens(text, model)
    
    if provider_lower == "anthropic" and HAS_ANTHROPIC:
        try:
            client = Anthropic()
            return client.messages.count_tokens(messages=text, model="anthropic").input_tokens
        except Exception:
            pass
    
    # Fallback for other providers
    return count_tokens(text, model)


def count_message_tokens(message, provider: str = "openai", model: str = "gpt-4o") -> int:
    """Count tokens for a message object (dict or Message)."""
    if hasattr(message, 'content'):
        # Message object
        content = message.content or ""
        tool_calls = getattr(message, 'tool_calls', [])
    else:
        # Dict format
        content = message.get("content", "") or ""
        tool_calls = message.get("tool_calls", [])
    
    total = count_tokens_for_model(content, provider, model)
    
    for tc in tool_calls:
        if hasattr(tc, 'arguments'):
            args_str = str(tc.arguments)
        else:
            args_str = str(tc.get("arguments", {}))
        total += count_tokens_for_model(args_str, provider, model)
    
    return total
