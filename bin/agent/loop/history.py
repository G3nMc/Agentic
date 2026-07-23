"""Conversation-self management — system-prompt insertion + sliding-window cap.

Pure functions operating on the message list so the run-loop stays
focused on iteration logic.

As of the ConversationHistory refactor, system prompts are keyed and
separated from clean user/assistant turns. The class provides a
backward-compatible list-like API so existing call sites continue to
work during the migration.

The class also hosts a :class:`TaskTracker` that keeps the live state
of the task-flow protocol (planned tasks, statuses, active task id).
The tracker is updated by the run-loop whenever the model emits
``<task_status>`` tags, and its state is rendered into a dedicated
system prompt key (``"task_state"``) so the model always sees the
current task state — not a stale snapshot from a previous iteration.
This prevents the model from re-emitting ``task_status`` for a task
that is already ``done`` (the ``done x5`` loop observed in the logs).
"""

from __future__ import annotations

import sys
from typing import Any, Dict, List, Optional, Iterator, Tuple

from agent.utils.token_estimator import estimate_tokens, chars_for_tokens
from agent.utils.text import sanitize as _sanitize_text


# ======================================================================
# TaskTracker — live task-flow state hosted by ConversationHistory
# ======================================================================


class TaskTracker:
    """Live state of the task-flow protocol, hosted inside ConversationHistory.

    The run-loop updates this tracker whenever the model emits
    ``<tasks>`` (a plan) or ``<task_status>`` (a status update).  The
    tracker renders its state into a system-prompt key so the model
    always sees the *current* task state — preventing the degenerate
    loop where the model re-emits ``task_status`` for a task that is
    already ``done``.

    The tracker uses the dataclasses/enums from :mod:`task_protocol`
    so it stays wire-compatible with the JSON envelopes emitted on
    stdout for the Flutter UI.
    """

    def __init__(self) -> None:
        # Ordered list of planned task ids (insertion order).
        self._task_ids: List[int] = []
        # Full Task objects keyed by id.
        self._tasks: Dict[int, Any] = {}
        # Per-task status (TaskStatus enum).  Defaults to PENDING.
        self._statuses: Dict[int, Any] = {}
        # Per-task note (last note emitted by the model).
        self._notes: Dict[int, str] = {}
        # The task the model last marked in_progress.
        self._active_task_id: Optional[int] = None
        # Every id that has ever been in_progress this request.
        self._inprogress_ids: set = set()

    # ── Plan management ───────────────────────────────────────────

    def set_plan(self, tasks: List[Any]) -> None:
        """Replace the current plan with *tasks* (list of Task dataclasses)."""
        self._task_ids = [t.id for t in tasks]
        self._tasks = {t.id: t for t in tasks}
        self._statuses = {t.id: t.status for t in tasks}
        self._notes = {}
        self._active_task_id = None
        self._inprogress_ids = set()

    def clear_plan(self) -> None:
        """Remove all plan state."""
        self._task_ids = []
        self._tasks = {}
        self._statuses = {}
        self._notes = {}
        self._active_task_id = None
        self._inprogress_ids = set()

    @property
    def has_plan(self) -> bool:
        return bool(self._task_ids)

    @property
    def task_ids(self) -> List[int]:
        return list(self._task_ids)

    @property
    def active_task_id(self) -> Optional[int]:
        return self._active_task_id

    @property
    def inprogress_ids(self) -> set:
        return set(self._inprogress_ids)

    # ── Status updates ────────────────────────────────────────────

    def update_status(self, task_id: int, status: Any, note: str = "") -> None:
        """Update the status of *task_id*.

        If *status* is IN_PROGRESS, the task becomes the active task.
        Terminal statuses (DONE, FAILED, SKIPPED) do NOT clear the
        active_task_id — the run-loop decides which task to advance to.
        """
        if task_id not in self._tasks:
            # The model emitted a status for an unplanned task id.
            # Create a minimal entry so the tracker doesn't lose it.
            self._tasks[task_id] = None
            self._task_ids.append(task_id)
            self._statuses[task_id] = status
        else:
            self._statuses[task_id] = status
        if note:
            self._notes[task_id] = note
        if status is not None and hasattr(status, "value"):
            if status.value == "in_progress":
                self._active_task_id = task_id
                self._inprogress_ids.add(task_id)

    def get_status(self, task_id: int) -> Any:
        return self._statuses.get(task_id)

    def is_done(self, task_id: int) -> bool:
        s = self._statuses.get(task_id)
        if s is None:
            return False
        return hasattr(s, "value") and s.value in ("done", "skipped", "failed")

    # ── Rendering ────────────────────────────────────────────────

    def render_state_block(self) -> str:
        """Render the current task state as a text block for the model.

        This is injected as a system-prompt key (``"task_state"``) so
        the model sees it as a persistent, always-updated instruction.

        The block includes:
          - The full plan (id, name, description, status)
          - The current active task
          - A reminder of the task_status protocol

        Returns an empty string when no plan is active.
        """
        if not self._task_ids:
            return ""

        lines: List[str] = [
            "=== CURRENT TASK STATE (orchestrator-managed — DO NOT re-emit <tasks>) ===",
            "The plan below is tracked by the orchestrator. Do NOT re-emit a",
            "<tasks> block. Continue working on the current task and emit",
            "<task_status> tags ONLY when the status CHANGES.",
            "",
        ]

        for tid in self._task_ids:
            task_obj = self._tasks.get(tid)
            name = getattr(task_obj, "name", f"Task {tid}") if task_obj else f"Task {tid}"
            desc = getattr(task_obj, "description", "") if task_obj else ""
            status = self._statuses.get(tid)
            status_str = status.value if status and hasattr(status, "value") else "pending"
            note = self._notes.get(tid, "")

            marker = "▶" if tid == self._active_task_id else "○"
            line = f"  #{tid} {marker} [{status_str}] — {name}"
            if desc:
                short_desc = desc[:120]
                if len(desc) > 120:
                    short_desc += "..."
                line += f"\n       {short_desc}"
            if note:
                line += f"\n       note: {note[:200]}"
            lines.append(line)

        lines.append("")
        if self._active_task_id is not None:
            task_obj = self._tasks.get(self._active_task_id)
            task_name = getattr(task_obj, "name", f"Task #{self._active_task_id}") if task_obj else f"Task #{self._active_task_id}"
            lines.append(
                f"CURRENT TASK: #{self._active_task_id} ({task_name}). "
                "Continue working on THIS task. Emit:\n"
                "<task_status>\n"
                f"  <id>{self._active_task_id}</id>\n"
                "  <status>done|partial|blocked|failed</status>\n"
                "  <note><short summary></note>\n"
                "</task_status> when it is "
                "complete. Do NOT re-emit a status that is already shown above."
            )
        else:
            # Find the first pending task.
            pending = next(
                (tid for tid in self._task_ids
                 if not self.is_done(tid)),
                None,
            )
            if pending is not None:
                task_obj = self._tasks.get(pending)
                task_name = getattr(task_obj, "name", f"Task #{pending}") if task_obj else f"Task #{pending}"
                lines.append(
                    f"NEXT TASK: #{pending} ({task_name}). "
                    "Emit its <task_status> as in_progress and start working on it."
                )
            else:
                lines.append(
                    "All tasks are complete. Emit your final answer."
                )

        lines.append("")
        lines.append(
            "IMPORTANT: Do NOT emit <task_status> for a task whose status is "
            "already shown above as done/partial/blocked/failed. Only emit a "
            "NEW status when it CHANGES."
        )
        lines.append("=== END TASK STATE ===")
        return "\n".join(lines)


# ======================================================================
# ConversationHistory — keyed system prompts + clean turns
# ======================================================================

class ConversationHistory:
    """Conversation self with separated system prompts and clean turns.

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

        # Live task-flow state tracker.  The run-loop updates this
        # whenever the model emits <tasks> or <task_status>, then
        # calls sync_task_state() to push the current state into the
        # "task_state" system-prompt key so the model always sees it.
        self.task_tracker: TaskTracker = TaskTracker()

    # ── Task-flow state (delegates to TaskTracker) ────────────────

    def sync_task_state(self) -> None:
        """Render the current task-tracker state into the ``task_state``
        system-prompt key.

        Call this **before** every model call so the model sees the
        most recent task state.  When no plan is active, the key is
        removed so it doesn't clutter the system block.
        """
        block = self.task_tracker.render_state_block()
        if block:
            self._system_prompts["task_state"] = block
        else:
            self._system_prompts.pop("task_state", None)

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
        """Build the message list sent to the model: a single merged
        system block first, then the clean turns.

        The keyed system prompts are concatenated in insertion order
        (Python 3.7+ dicts preserve order) into ONE system message, so
        the system instructions live as a single static block and are
        never interleaved with user/assistant turns. Merging also avoids
        backends that honor only the first system message silently
        dropping the rest.
        """
        messages: List[Dict[str, str]] = []
        if self._system_prompts:
            messages.append({"role": "system", "content": self.system_text()})
        messages.extend(self._turns)
        return messages

    def system_text(self) -> str:
        """Return the merged system block exactly as emitted by
        ``to_messages`` (empty string when no system prompts are set)."""
        return "\n\n".join(self._system_prompts.values())

    # ── Wire-format builders for backends ──────────────────────────

    def to_prompt(self) -> str:
        """Render the conversation as a single text prompt for
        ``/api/generate``-style backends (Ollama).

        System prompts are NOT included here — they are passed
        separately via :meth:`system_text` so the backend can populate
        the ``system`` field of the API payload. Only user / assistant /
        tool turns are rendered into the prompt body, prefixed with
        the speaker label and terminated by a final ``Assistant:`` cue
        so the model continues as the assistant.
        """
        body: List[str] = []
        for msg in self._turns:
            role = (msg.get("role") or "").lower()
            content = msg.get("content") or ""
            if not isinstance(content, str):
                content = str(content)
            if not content.strip():
                continue
            if role == "user":
                body.append(f"User: {content}")
            elif role == "assistant":
                body.append(f"Assistant: {content}")
            else:
                body.append(f"[{role}] {content}")
        body.append("Assistant:")
        return "\n\n".join(body)

    def to_gemini_contents(self) -> List[Dict[str, Any]]:
        """Render the conversation turns in Gemini's ``contents`` format.

        Gemini uses ``user`` and ``model`` roles (not ``assistant``).
        System prompts are handled separately via :meth:`system_text`.
        Tool / function roles are mapped to ``user`` parts so context
        isn't lost.
        """
        contents: List[Dict[str, Any]] = []
        for msg in self._turns:
            role = (msg.get("role") or "").lower()
            content = msg.get("content") or ""
            if not isinstance(content, str):
                content = str(content)
            if not content.strip():
                continue
            gemini_role = "model" if role == "assistant" else "user"
            contents.append(
                {"role": gemini_role, "parts": [{"text": content}]}
            )
        return contents

    def sanitize(self) -> None:
        """Sanitize all system prompts and turns in-place.

        Strips null bytes and lone UTF-16 surrogate code points that
        crash downstream encoders (notably Ollama's Python client).
        This centralizes sanitization so backends no longer need to
        call ``sanitize_for_agent()`` individually.
        """
        self._system_prompts = {
            k: _sanitize_text(v) for k, v in self._system_prompts.items()
        }
        self._turns = [
            dict(msg, content=_sanitize_text(msg.get("content") or ""))
            for msg in self._turns
        ]

    # ── Trimming (turns only — system is never trimmed) ────────────

    def trim_turns_to_budget(
            self,
            token_budget: int,
            *,
            content_type: str = "code",
            per_message_overhead: int = 10,
            max_msg_tokens: Optional[int] = None,
            reply_reserve_tokens: int = 0,
    ) -> int:
        """Trim ONLY the conversation turns to fit ``token_budget``.

        System prompts are never dropped: the merged system block's token
        cost is subtracted from the budget first, then turns are packed
        newest-first into whatever remains. Any single surviving turn
        larger than ``max_msg_tokens`` is truncated in place. The most
        recent turn is always kept so the model still sees the current
        request.

        Mutates ``self._turns`` directly (no flat round-trip), so the
        keyed system prompts keep their identity and never duplicate.
        Returns the number of turns dropped.
        """

        sys_text = self.system_text()
        system_tokens = (
            estimate_tokens(sys_text, content_type=content_type)
            + per_message_overhead
            if sys_text
            else 0
        )
        turns_budget = token_budget - system_tokens - reply_reserve_tokens

        if max_msg_tokens is None:
            max_msg_tokens = max(
                self.MAX_MSG_TOKENS,
                max(0, turns_budget) // max(10, len(self._turns) or 1),
            )

        # Truncate any oversized individual turn in place.
        for i, msg in enumerate(self._turns):
            content = msg.get("content") or ""
            if estimate_tokens(content, content_type=content_type) > max_msg_tokens:
                target_chars = chars_for_tokens(
                    max_msg_tokens, content_type=content_type
                )
                overflow = len(content) - target_chars
                self._turns[i] = dict(
                    msg,
                    content=content[:target_chars]
                            + f"\n[... {overflow} chars truncated from self ...]",
                )

        if turns_budget <= 0:
            print(
                f"[self] WARNING: system block (~{system_tokens} tok) "
                f"meets or exceeds the budget ({token_budget} tok); "
                "keeping only the most recent turn.",
                file=sys.stderr,
            )

        # Pack newest-first; always keep at least the most recent turn.
        min_keep = min(2, len(self._turns))
        kept: List[Dict[str, str]] = []
        used = 0
        for msg in reversed(self._turns):
            cost = (
                    estimate_tokens(msg.get("content", ""), content_type=content_type)
                    + per_message_overhead
            )
            if used + cost > turns_budget and len(kept) >= min_keep:
                break
            kept.insert(0, msg)
            used += cost

        dropped = len(self._turns) - len(kept)
        if dropped > 0:
            print(
                f"[self] Trimmed turns: dropped {dropped} old "
                f"(kept {len(kept)} turns, ~{used} tok; "
                f"system ~{system_tokens} tok).",
                file=sys.stderr,
            )
        self._turns = kept
        return dropped

    # ── Utility ────────────────────────────────────────────────────

    def reset_turns(self) -> None:
        """Clear turns but keep system prompts."""
        self._turns = []

    def reset_all(self) -> None:
        """Clear everything — system prompts, turns, and task state."""
        self._system_prompts.clear()
        self._turns = []
        self.task_tracker.clear_plan()

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
        # Deep-copy the task tracker state so the copy's task state
        # is independent of the original (the synthesis call uses a
        # copy and must not mutate the live tracker).
        new.task_tracker._task_ids = list(self.task_tracker._task_ids)
        new.task_tracker._tasks = dict(self.task_tracker._tasks)
        new.task_tracker._statuses = dict(self.task_tracker._statuses)
        new.task_tracker._notes = dict(self.task_tracker._notes)
        new.task_tracker._active_task_id = self.task_tracker._active_task_id
        new.task_tracker._inprogress_ids = set(self.task_tracker._inprogress_ids)
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

    def _to_flat(self) -> list[dict[str, str]] | ConversationHistory:
        """Normalise *self* to a plain list of message dicts.

        Accepts a ``ConversationHistory`` or a plain list.
        """
        if isinstance(self, ConversationHistory):
            return self.to_messages()
        return self

    def ensure_system_prompt(self, system_prompt: str) -> None:
        """Insert ``system_prompt`` at index 0 if not already present.

        Works with both ``ConversationHistory`` and plain lists.
        """
        if isinstance(self, ConversationHistory):
            # Use the keyed API — "base" is the canonical key for the
            # primary system prompt.
            if "base" not in self.system_prompts:
                self.set_system_prompt("base", system_prompt)
            return

        # Legacy list path.
        if not self or self[0].get("role") != "system":
            self.insert(0, {"role": "system", "content": system_prompt})

    def trim_history(
            self,
            max_turns: int,
            *,
            max_msg_chars: int = MAX_MSG_CHARS,
            max_msg_tokens: Optional[int] = None,
            content_type: str = "code",
    ):
        """Enforce the sliding-window self cap. Always keeps system messages.

        Non-system messages are capped at ``max_turns * 2`` (user + assistant
        per turn). Older messages are dropped first; then any surviving message
        whose content exceeds ``max_msg_chars`` (or ``max_msg_tokens`` if
        provided) is truncated in place so a single large tool result cannot
        blow the request budget on its own.

        Returns a new list — caller assigns it back.
        """

        flat = self._to_flat()
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
                            + f"\n[... {overflow} chars truncated from self ...]"
                    )
                    msg = dict(msg, content=content)
            elif len(content) > max_msg_chars:
                overflow = len(content) - max_msg_chars
                content = (
                        content[:max_msg_chars]
                        + f"\n[... {overflow} chars truncated from self ...]"
                )
                msg = dict(msg, content=content)
            capped.append(msg)

        return system + capped

    def trim_history_by_tokens(
            self,
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

        flat = self._to_flat()
        system = [m for m in flat if m.get("role") == "system"]
        non_system = [m for m in flat if m.get("role") != "system"]

        if max_msg_tokens is None:
            # Fair share: budget divided by a reasonable message count, with a floor.
            max_msg_tokens = max(self.MAX_MSG_TOKENS, token_budget // max(10, len(non_system)))

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
                        + f"\n[... {overflow} chars truncated from self ...]"
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
