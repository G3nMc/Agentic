"""Shared text helpers — currently just  stripping.

Kept as a separate module so any new text-massaging helpers (truncation,
secret redaction, etc.) have an obvious home.
"""

from __future__ import annotations

import re

# Reasoning-model thinking blocks. Used by Groq, DeepSeek-R1, QwQ etc.
_THINK_RE = re.compile(r"", re.DOTALL | re.IGNORECASE)


def strip_think(text: str) -> str:
    """Remove  reasoning blocks from a string."""
    if not text:
        return text
    return _THINK_RE.sub("", text).strip()


def sanitize(obj, *, for_agent: bool = True):
    """Sanitize content by removing characters that break downstream encoders.

    Args:
        obj: The object to sanitize (str, list, dict, or other).
        for_agent: Reserved for future use. Currently has no effect —
            null-byte and lone-surrogate stripping are always applied
            because both are invalid in UTF-8 and crash any encoder
            regardless of whether the consumer is an agent or the UI.
    """
    import re

    if isinstance(obj, str):
        # Always remove null bytes — they break JSON encoding.
        obj = obj.replace("\x00", "")
        # Always strip lone UTF-16 surrogate code points (U+D800–U+DFFF).
        # These are an encoding-error artifact (typically from
        # surrogateescape decoding that wasn't cleaned up), never
        # legitimate Unicode, and crash any UTF-8 encoder downstream
        # (Ollama's Python client, json.dumps without ensure_ascii,
        # file writes). Safe in both agent and display contexts:
        # real emoji live in the supplementary planes (U+1F300+) and
        # are not affected.
        obj = re.sub(r"[\ud800-\udfff]", "", obj)
        return obj

    if isinstance(obj, list):
        return [sanitize(x, for_agent=for_agent) for x in obj]

    if isinstance(obj, dict):
        return {k: sanitize(v, for_agent=for_agent) for k, v in obj.items()}

    return obj


def sanitize_for_agent(obj):
    """Sanitize content before sending to an agent.

    Strips null bytes and lone UTF-16 surrogate code points — both are
    invalid in UTF-8 and crash downstream encoders (notably Ollama's
    Python client). Applied uniformly to every message, including tool
    results: lone surrogates are never legitimate content, so there's
    no reason to preserve them.
    """
    return sanitize(obj, for_agent=True)


def sanitize_for_display(obj):
    """Sanitize content for UI display.

    Same behaviour as :func:`sanitize_for_agent` today — both strip
    null bytes and lone surrogates. Kept as a separate entry point so
    callers self-document intent and the two paths can diverge later
    if display-specific handling (e.g. preserving real emoji that an
    agent system has trouble with) becomes necessary.
    """
    return sanitize(obj, for_agent=False)
