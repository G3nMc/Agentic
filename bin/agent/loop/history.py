"""Conversation-history management — system-prompt insertion + sliding-window cap.

Pure functions operating on the message list so the run-loop stays
focused on iteration logic.
"""
from __future__ import annotations

import sys
from typing import Any, Dict, List

# Default hard cap on individual message length. Used as a fallback when
# the caller doesn't pass ``max_msg_chars`` — the Orchestrator now derives
# it from ``backend.context_limit`` so a 128K cloud model isn't truncated
# at a constant sized for 8K Ollama. ~10K chars ≈ 2.5K tokens.
MAX_MSG_CHARS = 10_000


def ensure_system_prompt(history: List[Dict[str, Any]], system_prompt: str) -> None:
    """Insert ``system_prompt`` at index 0 if not already present. In-place."""
    if not history or history[0].get("role") != "system":
        history.insert(0, {"role": "system", "content": system_prompt})


def trim_history(history: List[Dict[str, Any]], max_turns: int,
                 *, max_msg_chars: int = MAX_MSG_CHARS) -> List[Dict[str, Any]]:
    """
    Enforce the sliding-window history cap. Always keeps the system message.
    Non-system messages are capped at ``max_turns * 2`` (user + assistant
    per turn). Older messages are dropped first; then any surviving message
    whose content exceeds ``max_msg_chars`` is truncated in place so a
    single large tool result cannot blow the request budget on its own.

    Returns a new list — caller assigns it back.
    """
    system = [m for m in history if m.get("role") == "system"]
    non_system = [m for m in history if m.get("role") != "system"]

    max_msgs = max_turns * 2
    if len(non_system) > max_msgs:
        dropped = len(non_system) - max_msgs
        non_system = non_system[-max_msgs:]
        print(f"[orch] History trimmed: dropped {dropped} old messages "
              f"(keeping last {max_turns} turns).", file=sys.stderr)

    # Truncate any individual message that is abnormally large.
    capped = []
    for msg in non_system:
        content = msg.get("content") or ""
        if len(content) > max_msg_chars:
            overflow = len(content) - max_msg_chars
            content = (content[:max_msg_chars]
                       + f"\n[... {overflow} chars truncated from history ...]")
            msg = dict(msg, content=content)
        capped.append(msg)

    return system + capped


def import_external_history(history: List[Dict[str, Any]],
                            external: List[Dict[str, Any]]) -> None:
    """Append a caller-supplied history (filtered + normalised) to ``history``."""
    for msg in external:
        if not isinstance(msg, dict):
            continue
        role = str(msg.get("role") or "").strip().lower()
        content = str(msg.get("content") or "")
        if role not in ("user", "assistant", "system"):
            continue
        if not content.strip():
            continue
        history.append({"role": role, "content": content})
