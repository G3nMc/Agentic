#!/usr/bin/env python3
"""Shared helpers for the two CLI orchestrators.

Both ``orchestrator.py`` (single-agent) and ``orchestrator_multi.py``
(multi-agent) expose the same JSON-line stdin/stdout protocol to the
Flutter UI and share several pieces of plumbing:

  - Normalising caller-supplied chat self into a safe shape.
  - Prefixing a stateless prompt with that self.
  - Loading the optional filesystem-filter JSON config.
  - Loading the optional db-connections JSON config.

These helpers live here so the two entry points stay slim and stay in
sync. They are intentionally module-level functions (no class) to keep
the public surface of the two orchestrator scripts unchanged.

Nothing in this module touches argparse, the orchestrator classes, or
the interactive loop itself — those bits remain in the two scripts
because their shape genuinely differs between modes.
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any, Dict, List


def _normalise_external_history(raw: Any) -> List[Dict[str, str]]:
    """Return caller-supplied visible chat turns in a safe role/content shape.

    Drops anything that isn't a dict with a recognised role
    (``user``/``assistant``/``system``) and a non-empty content. The
    Flutter UI passes the user-visible chat log this way so the
    orchestrator can prime the model with prior context after a
    ``new_session`` reset.
    """
    if not isinstance(raw, list):
        return []
    history: List[Dict[str, str]] = []
    for msg in raw:
        if not isinstance(msg, dict):
            continue
        role = str(msg.get("role") or "").strip().lower()
        content = str(msg.get("content") or "")
        if role not in ("user", "assistant", "system") or not content.strip():
            continue
        history.append({"role": role, "content": content})
    return history


def _prompt_with_visible_history(prompt: str, history: List[Dict[str, str]]) -> str:
    """Prefix a stateless prompt with the visible chat self.

    Used by stateless workflows (e.g. Team Mode in multi_mode) where the
    orchestrator does not carry conversational state across calls.
    Returns ``prompt`` unchanged when self is empty.
    """
    if not history:
        return prompt
    lines = [
        "Use the following visible chat self as authoritative context for "
        "the latest user request. It is ordered oldest to newest.",
        "--- CHAT HISTORY ---",
    ]
    for msg in history:
        lines.append(f"[{msg['role']}] {msg['content']}")
    lines.extend(
        [
            "--- END CHAT HISTORY ---",
            "",
            "Latest user request:",
            prompt,
        ]
    )
    return "\n".join(lines)


def _load_path_filter(
        filters_config_path: str,
        base_path: str,
        log_prefix: str = "orch",
):
    """Read the optional filters JSON file and build a :class:`PathFilter`.

    Returns ``None`` when the path is empty/missing or unreadable; the
    ToolRegistry treats ``None`` as "filter off" (only the hardcoded
    baseline of ``.git``, ``__pycache__``, etc. applies). Failures are
    logged to stderr with ``log_prefix`` so each orchestrator stays
    identifiable in shared log streams.
    """
    path = (filters_config_path or "").strip()
    if not path:
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except FileNotFoundError:
        print(
            f"[{log_prefix}] --filters-config '{path}' not found; ignoring.",
            file=sys.stderr,
        )
        return None
    except (json.JSONDecodeError, OSError) as ex:
        print(
            f"[{log_prefix}] --filters-config could not be read ({ex}); ignoring.",
            file=sys.stderr,
        )
        return None
    if not isinstance(cfg, dict):
        print(
            f"[{log_prefix}] --filters-config did not contain an object; ignoring.",
            file=sys.stderr,
        )
        return None
    try:
        from agent.core.path_filter import PathFilter
    except ImportError as ex:
        print(f"[{log_prefix}] Cannot import path_filter: {ex}", file=sys.stderr)
        return None
    return PathFilter.from_config(base_path, cfg)


def _load_db_connections(
        config_path: str,
        log_prefix: str = "orch",
) -> Dict[str, Dict[str, str]]:
    """Read the optional db-connections JSON file and return a dict.

    The Flutter Settings UI writes a list of ``{"key", "value", "type"}``
    entries; this helper converts it into the dict shape the
    ``db_query`` tool expects (keyed by connection name). Returns an
    empty dict for any failure so the orchestrator still starts — the
    ``db_query`` tool will just report "no connections available" until
    the user fixes the file.
    """
    path = (config_path or "").strip()
    if not path:
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = json.load(f)
    except FileNotFoundError:
        print(
            f"[{log_prefix}] --db-connections-config '{path}' not found; ignoring.",
            file=sys.stderr,
        )
        return {}
    except (json.JSONDecodeError, OSError) as ex:
        print(
            f"[{log_prefix}] --db-connections-config could not be read ({ex}); "
            "ignoring.",
            file=sys.stderr,
        )
        return {}
    if not isinstance(raw, list):
        print(
            f"[{log_prefix}] --db-connections-config did not contain a list; "
            "ignoring.",
            file=sys.stderr,
        )
        return {}
    connections: Dict[str, Dict[str, str]] = {}
    for item in raw:
        if not isinstance(item, dict):
            continue
        key = item.get("key")
        value = item.get("value", "")
        conn_type = item.get("type", "sqlite")
        if not isinstance(key, str) or not key:
            continue
        connections[key] = {"value": value, "type": conn_type}
    return connections


def _resolve_debug_chat_path(base_path: str, file_name: str) -> str:
    """Resolve the absolute path of the debug chat file.

    In debug mode the relative path passed via --file_name is interpreted
    against --base-path so the chat file lives inside the project tree.
    """
    base = os.path.abspath(base_path)
    file_name = (file_name or "").strip()
    if not file_name:
        return ""
    # Strip a leading slash so "C:/chats/foo.txt" on Windows is not forced
    # to the drive root, while still allowing absolute paths through.
    if file_name.startswith("/") or file_name.startswith("\\"):
        file_name = file_name[1:]
    return os.path.abspath(os.path.join(base, file_name))


def _read_last_user_turn(chat_path: str) -> tuple[str, list[dict]]:
    """Read the last USER: turn from a debug chat file.

    Returns (prompt, visible_history) where visible_history contains every
    previous USER/AGENT pair as {"role": "user"|"assistant", "content": ...}.
    """
    if not chat_path or not os.path.isfile(chat_path):
        return "", []

    try:
        with open(chat_path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except Exception as ex:  # noqa: BLE001
        print(f"[orch] Debug chat read failed: {ex}", file=sys.stderr, flush=True)
        return "", []

    # Parse alternating USER: ... AGENT: ... blocks.
    user_marker = "USER:"
    agent_marker = "AGENT:"
    pairs = []
    current_role = None
    current_lines = []

    def flush():
        nonlocal current_role, current_lines, pairs
        if current_role is None:
            return
        contenuto = "\n".join(current_lines).strip()
        if contenuto:
            pairs.append((current_role, contenuto))
        current_role = None
        current_lines = []

    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        lu = line.upper()
        if lu.startswith(user_marker):
            flush()
            current_role = "user"
            current_lines.append(line[len(user_marker):].strip())
        elif lu.startswith(agent_marker):
            flush()
            current_role = "agent"
            current_lines.append(line[len(agent_marker):].strip())
        elif current_role is not None:
            current_lines.append(line)

    flush()

    # visible_history: every completed user+agent pair except the last user.
    visible_history = []
    last_prompt = ""
    for role, content in pairs:
        if role == "user":
            # If we already had a previous prompt without an answer, keep it
            # as part of self (the user may have edited the file mid-way).
            if last_prompt:
                visible_history.append({"role": "user", "content": last_prompt})
            last_prompt = content
        else:  # agent
            if last_prompt:
                visible_history.append({"role": "user", "content": last_prompt})
                last_prompt = ""
            visible_history.append({"role": "assistant", "content": content})

    return last_prompt, visible_history


def _append_debug_response(chat_path: str, response: str) -> None:
    """Append the AGENT response to the debug chat file.

    In debug mode the USER turn is already present in the chat file; we
    only append the model's answer so the file keeps the alternating
    USER:/AGENT: format.
    """
    if not chat_path:
        return
    os.makedirs(os.path.dirname(chat_path), exist_ok=True)
    with open(chat_path, "a", encoding="utf-8") as fh:
        fh.write(f"\n\nAGENT:\n {response}\n")


__all__ = [
    "_normalise_external_history",
    "_prompt_with_visible_history",
    "_load_path_filter",
    "_load_db_connections",
    "_resolve_debug_chat_path",
    "_read_last_user_turn",
    "_append_debug_response",
]
