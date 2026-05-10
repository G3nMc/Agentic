"""Conversation-history management — system-prompt insertion + sliding-window cap.

Pure functions operating on the message list so the run-loop stays
focused on iteration logic.
"""
from __future__ import annotations

import sys
from typing import Any, Dict, List, Optional

from ..utils.token_estimator import estimate_tokens, chars_for_tokens

# Default hard cap on individual message length. Used as a fallback when
# the caller doesn't pass ``max_msg_chars`` — the Orchestrator now derives
# it from ``backend.context_limit`` so a 128K cloud model isn't truncated
# at a constant sized for 8K Ollama.
# At 8K context: ~10K chars ≈ 2.5K tokens (code-aware).
# At 128K context: scaled dynamically by the caller.
MAX_MSG_CHARS = 10_000

# Default token cap per message when the caller passes max_msg_tokens.
# ~2_500 tokens is safe for 8K Ollama; callers with larger context windows
# should pass a higher max_msg_tokens.
MAX_MSG_TOKENS = 2_500


def ensure_system_prompt(history: List[Dict[str, Any]], system_prompt: str) -> None:
    """Insert ``system_prompt`` at index 0 if not already present. In-place."""
    if not history or history[0].get("role") != "system":
        history.insert(0, {"role": "system", "content": system_prompt})


def trim_history(history: List[Dict[str, Any]], max_turns: int,
                 *, max_msg_chars: int = MAX_MSG_CHARS,
                 max_msg_tokens: Optional[int] = None,
                 content_type: str = "code") -> List[Dict[str, Any]]:
    """
    Enforce the sliding-window history cap. Always keeps the system message.
    Non-system messages are capped at ``max_turns * 2`` (user + assistant
    per turn). Older messages are dropped first; then any surviving message
    whose content exceeds ``max_msg_chars`` (or ``max_msg_tokens`` if
    provided) is truncated in place so a single large tool result cannot
    blow the request budget on its own.

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
        if max_msg_tokens is not None:
            msg_tokens = estimate_tokens(content, content_type=content_type)
            if msg_tokens > max_msg_tokens:
                target_chars = chars_for_tokens(max_msg_tokens, content_type=content_type)
                overflow = len(content) - target_chars
                content = (content[:target_chars]
                           + f"\n[... {overflow} chars truncated from history ...]")
                msg = dict(msg, content=content)
        elif len(content) > max_msg_chars:
            overflow = len(content) - max_msg_chars
            content = (content[:max_msg_chars]
                       + f"\n[... {overflow} chars truncated from history ...]")
            msg = dict(msg, content=content)
        capped.append(msg)

    return system + capped


def trim_history_by_tokens(
    history: List[Dict[str, Any]],
    token_budget: int,
    *,
    content_type: str = "code",
    per_message_overhead: int = 10,
    max_msg_tokens: Optional[int] = None,
) -> List[Dict[str, Any]]:
    """
    Enforce a token budget by packing messages newest-first.

    Always keeps the system message. Non-system messages are included
    newest-first until the accumulated token estimate exceeds the budget.
    Any surviving message that exceeds ``max_msg_tokens`` is truncated
    in place.

    Returns a new list — caller assigns it back.
    """
    system = [m for m in history if m.get("role") == "system"]
    non_system = [m for m in history if m.get("role") != "system"]

    if max_msg_tokens is None:
        # Fair share: budget divided by a reasonable message count, with a floor.
        max_msg_tokens = max(MAX_MSG_TOKENS, token_budget // max(10, len(non_system)))

    # Truncate individual messages first.
    capped = []
    for msg in non_system:
        content = msg.get("content") or ""
        msg_tokens = estimate_tokens(content, content_type=content_type)
        if msg_tokens > max_msg_tokens:
            target_chars = chars_for_tokens(max_msg_tokens, content_type=content_type)
            overflow = len(content) - target_chars
            content = (content[:target_chars]
                       + f"\n[... {overflow} chars truncated from history ...]")
            msg = dict(msg, content=content)
        capped.append(msg)

    # Pack newest-first until budget. Always keep at least 1 turn (2 msgs).
    kept: List[Dict[str, Any]] = []
    current_tokens = sum(
        estimate_tokens(m.get("content", ""), content_type=content_type)
        + per_message_overhead
        for m in system
    )
    min_keep = min(2, len(capped))

    for msg in reversed(capped):
        msg_tokens = (
            estimate_tokens(msg.get("content", ""), content_type=content_type)
            + per_message_overhead
        )
        if current_tokens + msg_tokens > token_budget and len(kept) >= min_keep:
            break
        kept.insert(0, msg)
        current_tokens += msg_tokens

    dropped = len(capped) - len(kept)
    if dropped > 0:
        print(
            f"[orch] History trimmed by tokens: dropped {dropped} old messages "
            f"(kept {len(kept)} non-system, ~{current_tokens} tokens).",
            file=sys.stderr,
        )

    return system + kept


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
