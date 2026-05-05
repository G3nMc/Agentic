"""Shared text helpers — currently just  stripping.

Kept as a separate module so any new text-massaging helpers (truncation,
secret redaction, etc.) have an obvious home.
"""
from __future__ import annotations

import re

# Reasoning-model thinking blocks. Used by Groq, DeepSeek-R1, QwQ etc.
_THINK_RE = re.compile(r"", re.DOTALL | re.IGNORECASE)

# Patterns that indicate tool execution content (results, outputs, file paths, etc.)
# When detected, we preserve raw text to avoid corrupting tool outputs.
_TOOL_RESULT_PATTERNS = [
    r"\b[A-Za-z]:\\[\w\\.\-]+",  # Windows paths: C:\path\to\file
    r"\b/[\w\./\-]+\b",  # Unix paths: /path/to/file, lib/ui/widgets.dart
    r"\[tool result elided:",  # Compactor stub marker
    r"\b(?:read_file|write_file|list_files|search_in_files|run_command)\b",  # Tool names
    r'\{\"tool\":\s*\"[^\"]+\"',  # Tool call JSON: {"tool": "name"
    r'\b(?:status\"?:\s*\"?(?:success|error)\"?,|status\":\s*\"(?:success|error)\")',  # Tool result status
    r"\b(?:stdout|stderr|exit_code|output)\"?:",  # Command execution keys
    r"^\s*(?:SUCCESS|ERROR|Traceback|File \"|[A-Z]:\\|/usr/|/bin/|/opt/)",  # Common output prefixes
]
_TOOL_RESULT_RE = re.compile("|".join(_TOOL_RESULT_PATTERNS), re.IGNORECASE)


def strip_think(text: str) -> str:
    """Remove  reasoning blocks from a string."""
    if not text:
        return text
    return _THINK_RE.sub("", text).strip()


def _looks_like_tool_result(obj) -> bool:
    """Check if content appears to be tool execution output.
    
    Tool results (file contents, command outputs, etc.) should be preserved
    raw to avoid corrupting legitimate characters in user code/data.
    """
    if isinstance(obj, str):
        return bool(_TOOL_RESULT_RE.search(obj))
    if isinstance(obj, dict):
        # Check for tool result structure
        if "tool" in obj or "result" in obj or "status" in obj:
            return True
        if "parameters" in obj and "tool" in obj:
            return True
        # Recursively check values
        return any(_looks_like_tool_result(v) for v in obj.values())
    if isinstance(obj, list):
        return any(_looks_like_tool_result(item) for item in obj)
    return False


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
    """Sanitize content before sending to an agent (removes emoji/icon chars).
    
    Tool execution results (file contents, command outputs, etc.) are
    detected and returned raw to preserve legitimate characters in user
    code and data.
    """
    if _looks_like_tool_result(obj):
        # Tool result content - preserve raw, only strip null bytes
        return sanitize(obj, for_agent=False)
    return sanitize(obj, for_agent=True)


def sanitize_for_display(obj):
    """Sanitize content for UI display (preserves emoji/icon chars, removes only null bytes)."""
    return sanitize(obj, for_agent=False)
