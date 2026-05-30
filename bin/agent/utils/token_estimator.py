"""Token estimation helpers with content-type-aware multipliers.

Coding workflows are heavy on source code, JSON, and tool results, which
tokenize more densely than English prose (typically 2.5-3.0 chars/token
vs 4.0 chars/token). Using a single global 4.0 multiplier underestimates
token counts for code-heavy prompts and risks silent context overflow.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

# Multipliers derived from observation across Python/Dart/JSON tool output.
# These are pessimistic (i.e. they OVER-estimate tokens slightly) so we
# stay safely under the context window.
CODE_CHARS_PER_TOKEN = 3.0  # source code, JSON, stack traces, diffs
PROSE_CHARS_PER_TOKEN = 4.0  # natural language explanations
DEFAULT_CHARS_PER_TOKEN = 3.5  # blended default for mixed content

# Safety margin applied on top of the raw estimate to absorb drift
# from role separators, formatting overhead, and provider-specific
# tokenization quirks.
SAFETY_FACTOR = 1.10


def estimate_tokens(text: str, content_type: str = "code") -> int:
    """Return a pessimistic token count for ``text``.

    Parameters
    ----------
    text
        The text to estimate.
    content_type
        One of ``"code"`` (dense punctuation/symbols), ``"prose"``
        (natural language), or ``"mixed"`` (default blended).
    """
    chars = len(text or "")
    if chars == 0:
        return 0
    multiplier = _multiplier_for(content_type)
    raw = chars / multiplier
    return int(raw * SAFETY_FACTOR) + 1  # +1 rounds up


def estimate_tokens_from_chars(chars: int, content_type: str = "code") -> int:
    """Convert a character count to an estimated token count."""
    if chars <= 0:
        return 0
    multiplier = _multiplier_for(content_type)
    raw = chars / multiplier
    return int(raw * SAFETY_FACTOR) + 1


def estimate_messages_tokens(
    messages: Optional[List[Dict[str, Any]]],
    *,
    content_type: str = "code",
    per_message_overhead: int = 10,
) -> int:
    """Estimate tokens for a list of chat messages.

    Includes ``per_message_overhead`` tokens per message for role
    separators and formatting.
    """
    if not messages:
        return 0
    total = 0
    for m in messages:
        c = m.get("content")
        if isinstance(c, str):
            total += estimate_tokens(c, content_type)
        elif isinstance(c, list):
            for part in c:
                if isinstance(part, dict):
                    total += estimate_tokens(str(part.get("text", "")), content_type)
    total += per_message_overhead * len(messages)
    return total


def chars_for_tokens(tokens: int, content_type: str = "code") -> int:
    """Convert a token budget to a character budget.

    Use this when deriving char caps from a token context window.
    Because code is denser (fewer chars per token), the resulting char
    budget is smaller than the naive ``tokens * 4`` calculation.
    """
    if tokens <= 0:
        return 0
    multiplier = _multiplier_for(content_type)
    return int(tokens * multiplier)


def _multiplier_for(content_type: str) -> float:
    ct = (content_type or "mixed").lower()
    if ct == "code":
        return CODE_CHARS_PER_TOKEN
    if ct == "prose":
        return PROSE_CHARS_PER_TOKEN
    return DEFAULT_CHARS_PER_TOKEN
