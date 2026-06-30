"""Conversation-history management — system-prompt insertion + sliding-window cap.

Pure functions operating on the message list so the run-loop stays
focused on iteration logic.

As of the ConversationHistory refactor, system prompts are keyed and
separated from clean user/assistant turns. The class provides a
backward-compatible list-like API so existing call sites continue to
work during the migration.
"""

from __future__ import annotations

import sys
from typing import Any, Dict, List, Optional, Iterator


# ======================================================================
# ConversationHistory — keyed system prompts + clean turns
# ======================================================================

class ConversationHistory:
    """Conversation history with separated system prompts and clean turns.

    System prompts are keyed by name — setting the same key replaces the
    content (no duplication).  Turns contain only real user/assistant
    exchanges and tool results (which are part of the working
    conversation).

    The class also provides a backward-compatible list-like API
    (``__getitem__``, ``__len__``, ``__iter__``, ``append``, ``pop``,
    ``insert``) so existing code that treats ``conversation_history`` as
    a plain ``List[Dict]`` continues to work during the migration.
    """

    def __init__(self):
        # System prompts keyed by name. Each key maps to one system
        # instruction. Setting the same key replaces the content.
        self._system_prompts: Dict[str, str] = {}

        # Clean conversation turns: only real user/assistant exchanges
        # + tool results (which are part of the working conversation).
        self._turns: List[Dict[str, str]] = []

    # ── System prompts (keyed, static) ──────────────────────────────

    def set_system_prompt(self, key: str, content: str) -> None:
        """Set or replace a system prompt by key."""
        self._system_prompts[key] = content

    def remove_system_prompt(self, key: str) -> None:
        """Remove a system prompt by key (no-op if missing)."""
        self._system_prompts.pop(key, None)

    def get_system_prompt(self, key: str) -> Optional[str]:
        """Return the content for *key*, or None."""
        return self._system_prompts.get(key)

    def clear_system_prompts(self) -> None:
        """Remove all system prompts."""
        self._system_prompts.clear()

    # ── Clean turns (user / assistant / tool-result) ───────────────

    def add_user(self, content: str) -> None:
        """Append a clean user turn (no directive prepended)."""
        self._turns.append({"role": "user", "content": content})

    def add_assistant(self, content: str) -> None:
        """Append a clean assistant turn."""
        self._turns.append({"role": "assistant", "content": content})

    def add_turn(self, role: str, content: str) -> None:
        """Append a turn with an explicit role."""
        self._turns.append({"role": role, "content": content})

    def pop_turn(self) -> Optional[Dict[str, str]]:
        """Remove and return the last turn, or None if empty."""
        return self._turns.pop() if self._turns else None

    def last_turn(self) -> Optional[Dict[str, str]]:
        """Return the last turn without removing it, or None."""
        return self._turns[-1] if self._turns else None

    # ── Build the message list for the model ───────────────────────

    def to_messages(self) -> List[Dict[str, str]]:
        """Build the full message list: system prompts first, then turns.

        System prompts are emitted in insertion order (Python 3.7+
        dicts preserve order), so the base system prompt is always
        first.
        """
        system_msgs = [
            {"role": "system", "content": content}
            for content in self._system_prompts.values()
        ]
        # Log a compact summary so we can see at a glance how many
        # system keys are active and how many turns are in play.
        n_sys = len(system_msgs)
        n_turns = len(self._turns)
        if n_sys > 1:
            keys = list(self._system_prompts.keys())
            print(
                f"[history] to_messages: {n_sys} system keys "
                f"({', '.join(keys)}) + {n_turns} turns",
                file=sys.stderr,
            )
        return system_msgs + self._turns

    # ── Utility ────────────────────────────────────────────────────

    def reset_turns(self) -> None:
        """Clear turns but keep system prompts."""
        self._turns = []

    def reset_all(self) -> None:
        """Clear everything — system prompts and turns."""
        self._system_prompts.clear()
        self._turns = []

    def import_external_history(self, external: List[Dict[str, Any]]) -> None:
        """Append caller-supplied user/assistant turns.

        Only ``user`` and ``assistant`` roles are accepted.  System
        prompts are owned exclusively by ``set_system_prompt``.
        """
        for msg in external:
            if not isinstance(msg, dict):
                continue
            role = str(msg.get("role") or "").strip().lower()
            content = str(msg.get("content") or "")
            if role not in ("user", "assistant"):
                continue
            if not content.strip():
                continue
            self._turns.append({"role": role, "content": content})

    # ── Backward-compatible list-like API ──────────────────────────
    # These delegate to ``to_messages()`` so existing code that
    # indexes / iterates / appends ``conversation_history`` directly
    # continues to work.  Once all call sites are migrated to the
    # native API these can be removed.

    @property
    def turns(self) -> List[Dict[str, str]]:
        """Direct access to the clean turns list (read-only view)."""
        return self._turns

    @property
    def system_prompts(self) -> Dict[str, str]:
        """Direct access to the system prompts dict (read-only view)."""
        return dict(self._system_prompts)

    # -- mutation helpers that keep the flat view consistent ---------

    def _rebuild_from_flat(self, flat: List[Dict[str, Any]]) -> None:
        """Rebuild internal state from a flat message list.

        System messages (role='system') are extracted into
        ``_system_prompts`` using positional keys (sys_0, sys_1, …).
        Non-system messages become ``_turns``.
        """
        self._system_prompts.clear()
        self._turns.clear()
        sys_idx = 0
        for msg in flat:
            role = str(msg.get("role") or "").strip().lower()
            content = str(msg.get("content") or "")
            if role == "system":
                self._system_prompts[f"sys_{sys_idx}"] = content
                sys_idx += 1
            else:
                self._turns.append({"role": role, "content": content})

    @classmethod
    def from_flat(cls, flat: List[Dict[str, Any]]) -> ConversationHistory:
        """Create a ConversationHistory from a flat message list."""
        ch = cls()
        ch._rebuild_from_flat(flat)
        return ch

    # -- list protocol -----------------------------------------------

    def __getitem__(self, index):
        """Index into the flat message list (system + turns)."""
        return self.to_messages()[index]

    def __setitem__(self, index, value):
        """Set an item in the flat view.  Rebuilds internal state."""
        flat = self.to_messages()
        flat[index] = value
        self._rebuild_from_flat(flat)

    def __delitem__(self, index):
        flat = self.to_messages()
        del flat[index]
        self._rebuild_from_flat(flat)

    def __len__(self) -> int:
        return len(self._system_prompts) + len(self._turns)

    def __iter__(self) -> Iterator[Dict[str, str]]:
        return iter(self.to_messages())

    def __contains__(self, item) -> bool:
        return item in self.to_messages()

    def __reversed__(self):
        return reversed(self.to_messages())

    def __eq__(self, other) -> bool:
        if isinstance(other, ConversationHistory):
            return self.to_messages() == other.to_messages()
        if isinstance(other, list):
            return self.to_messages() == other
        return NotImplemented

    def __repr__(self) -> str:
        return (
            f"ConversationHistory(system_keys={list(self._system_prompts.keys())}, "
            f"turns={len(self._turns)})"
        )

    def append(self, item: Dict[str, Any]) -> None:
        """Append a message dict.  System messages go to
        ``_system_prompts`` (auto-keyed); everything else goes to
        ``_turns``."""
        role = str(item.get("role") or "").strip().lower()
        content = str(item.get("content") or "")
        if role == "system":
            # Auto-key: use the next available sys_N slot.
            idx = 0
            while f"sys_{idx}" in self._system_prompts:
                idx += 1
            self._system_prompts[f"sys_{idx}"] = content
        else:
            self._turns.append({"role": role, "content": content})

    def pop(self, index: int = -1) -> Dict[str, str]:
        """Pop from the flat view.  Rebuilds internal state."""
        flat = self.to_messages()
        result = flat.pop(index)
        self._rebuild_from_flat(flat)
        return result

    def insert(self, index: int, item: Dict[str, Any]) -> None:
        """Insert into the flat view.  Rebuilds internal state."""
        flat = self.to_messages()
        flat.insert(index, item)
        self._rebuild_from_flat(flat)

    def extend(self, items: List[Dict[str, Any]]) -> None:
        """Extend with a list of message dicts."""
        for item in items:
            self.append(item)

    def index(self, value, start=0, stop=None) -> int:
        return self.to_messages().index(value, start, stop or len(self))

    def count(self, value) -> int:
        return self.to_messages().count(value)

    def copy(self) -> ConversationHistory:
        """Return a shallow copy."""
        new = ConversationHistory()
        new._system_prompts = dict(self._system_prompts)
        new._turns = list(self._turns)
        return new

    def clear(self) -> None:
        """Clear everything (same as reset_all)."""
        self.reset_all()

    def remove(self, value) -> None:
        flat = self.to_messages()
        flat.remove(value)
        self._rebuild_from_flat(flat)

    def reverse(self) -> None:
        flat = self.to_messages()
        flat.reverse()
        self._rebuild_from_flat(flat)

    def sort(self, *, key=None, reverse=False) -> None:
        flat = self.to_messages()
        flat.sort(key=key, reverse=reverse)
        self._rebuild_from_flat(flat)


# ======================================================================
# Legacy module-level functions (kept for backward compatibility)
# ======================================================================

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


def _to_flat(history) -> List[Dict[str, Any]]:
    """Normalise *history* to a plain list of message dicts.

    Accepts a ``ConversationHistory`` or a plain list.
    """
    if isinstance(history, ConversationHistory):
        return history.to_messages()
    return history


def ensure_system_prompt(history, system_prompt: str) -> None:
    """Insert ``system_prompt`` at index 0 if not already present.

    Works with both ``ConversationHistory`` and plain lists.
    """
    if isinstance(history, ConversationHistory):
        # Use the keyed API — "base" is the canonical key for the
        # primary system prompt.
        if "base" not in history._system_prompts:
            history.set_system_prompt("base", system_prompt)
        return

    # Legacy list path.
    if not history or history[0].get("role") != "system":
        history.insert(0, {"role": "system", "content": system_prompt})


def trim_history(
    history,
    max_turns: int,
    *,
    max_msg_chars: int = MAX_MSG_CHARS,
    max_msg_tokens: Optional[int] = None,
    content_type: str = "code",
):
    """Enforce the sliding-window history cap. Always keeps system messages.

    Non-system messages are capped at ``max_turns * 2`` (user + assistant
    per turn). Older messages are dropped first; then any surviving message
    whose content exceeds ``max_msg_chars`` (or ``max_msg_tokens`` if
    provided) is truncated in place so a single large tool result cannot
    blow the request budget on its own.

    Returns a new list — caller assigns it back.
    """
    from ..utils.token_estimator import estimate_tokens, chars_for_tokens

    flat = _to_flat(history)
    system = [m for m in flat if m.get("role") == "system"]
    non_system = [m for m in flat if m.get("role") != "system"]

    max_msgs = max_turns * 2
    if len(non_system) > max_msgs:
        dropped = len(non_system) - max_msgs
        non_system = non_system[-max_msgs:]
        print(
            f"[orch] History trimmed: dropped {dropped} old messages "
            f"(keeping last {max_turns} turns).",
            file=sys.stderr,
        )

    # Truncate any individual message that is abnormally large.
    capped = []
    for msg in non_system:
        content = msg.get("content") or ""
        if max_msg_tokens is not None:
            msg_tokens = estimate_tokens(content, content_type=content_type)
            if msg_tokens > max_msg_tokens:
                target_chars = chars_for_tokens(
                    max_msg_tokens, content_type=content_type
                )
                overflow = len(content) - target_chars
                content = (
                    content[:target_chars]
                    + f"\n[... {overflow} chars truncated from history ...]"
                )
                msg = dict(msg, content=content)
        elif len(content) > max_msg_chars:
            overflow = len(content) - max_msg_chars
            content = (
                content[:max_msg_chars]
                + f"\n[... {overflow} chars truncated from history ...]"
            )
            msg = dict(msg, content=content)
        capped.append(msg)

    return system + capped


def trim_history_by_tokens(
    history,
    token_budget: int,
    *,
    content_type: str = "code",
    per_message_overhead: int = 10,
    max_msg_tokens: Optional[int] = None,
):
    """Enforce a token budget by packing messages newest-first.

    Always keeps system messages. Non-system messages are included
    newest-first until the accumulated token estimate exceeds the budget.
    Any surviving message that exceeds ``max_msg_tokens`` is truncated
    in place.

    Returns a new list — caller assigns it back.
    """
    from ..utils.token_estimator import estimate_tokens, chars_for_tokens

    flat = _to_flat(history)
    system = [m for m in flat if m.get("role") == "system"]
    non_system = [m for m in flat if m.get("role") != "system"]

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
            content = (
                content[:target_chars]
                + f"\n[... {overflow} chars truncated from history ...]"
            )
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


def import_external_history(
    history, external: List[Dict[str, Any]]
) -> None:
    """Append a caller-supplied history (filtered + normalised) to *history*.

    Only ``user`` and ``assistant`` roles are accepted. The system
    prompt is owned exclusively by ``ensure_system_prompt`` and lives at
    ``history[0]``; admitting external ``system`` turns mid-conversation
    confuses the model into treating them as topic switches (seen as
    "I don't understand" / "Can you be more specific" replies).

    Works with both ``ConversationHistory`` and plain lists.
    """
    if isinstance(history, ConversationHistory):
        history.import_external_history(external)
        return

    # Legacy list path.
    for msg in external:
        if not isinstance(msg, dict):
            continue
        role = str(msg.get("role") or "").strip().lower()
        content = str(msg.get("content") or "")
        if role not in ("user", "assistant"):
            continue
        if not content.strip():
            continue
        history.append({"role": role, "content": content})
