"""Shared text helpers — currently just <think>…</think> stripping.

Kept as a separate module so any new text-massaging helpers (truncation,
secret redaction, etc.) have an obvious home.
"""
from __future__ import annotations

import re

# Reasoning-model thinking blocks. Used by Groq, DeepSeek-R1, QwQ etc.
_THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)


def strip_think(text: str) -> str:
    """Remove <think>…</think> reasoning blocks from a string."""
    if not text:
        return text
    return _THINK_RE.sub("", text).strip()


def sanitize(obj, *, for_agent: bool = True):
    """Sanitize content by removing problematic characters.

    Args:
        obj: The object to sanitize (str, list, dict, or other).
        for_agent: If True (default), remove emoji/icon chars that cause
            agent errors. If False, only remove null bytes to preserve
            markdown formatting for UI display.
    """
    import re

    if isinstance(obj, str):
        # Always remove null bytes - they break JSON encoding
        obj = obj.replace("\x00", "")
        # Only remove Unicode surrogate pairs (emoji/icon chars) when
        # sending to agents. Preserve them for UI display.
        if for_agent:
            obj = re.sub(r"[\ud800-\udfff]", "", obj)
        return obj

    if isinstance(obj, list):
        return [sanitize(x, for_agent=for_agent) for x in obj]

    if isinstance(obj, dict):
        return {k: sanitize(v, for_agent=for_agent) for k, v in obj.items()}

    return obj


def sanitize_for_agent(obj):
    """Sanitize content before sending to an agent (removes emoji/icon chars)."""
    return sanitize(obj, for_agent=True)


def sanitize_for_display(obj):
    """Sanitize content for UI display (preserves emoji/icon chars, removes only null bytes)."""
    return sanitize(obj, for_agent=False)
