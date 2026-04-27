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


def sanitize(obj):
    import re

    if isinstance(obj, str):
        obj = obj.replace("\x00", "")
        obj = re.sub(r"[\ud800-\udfff]", "", obj)
        return obj

    if isinstance(obj, list):
        return [sanitize(x) for x in obj]

    if isinstance(obj, dict):
        return {k: sanitize(v) for k, v in obj.items()}

    return obj
