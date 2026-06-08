"""Stdin/stdout framing for the interactive protocol used by the Flutter UI.

The Flutter side spawns the orchestrator as a subprocess and communicates
via pipes:

  - One JSON object per line written to stdin:
      {"prompt": "...", "new_session": true|false, "history": [...]}
  - The response text on stdout, followed by a single line containing
    exactly ``__RESPONSE_END__``.
  - Diagnostics on stderr.

Both streams must stay UTF-8 (the Flutter app sends/receives UTF-8) and
must NOT have their buffering or newline translation altered — the
parent process relies on Python's default ``print() + flush()`` behavior
and on Windows' native ``\r\n`` line endings on stdout. Replacing the
wrapper with ``io.TextIOWrapper(..., newline='\n')`` breaks both
contracts and causes the Flutter side to hang waiting for ``__READY__``.
Use :meth:`io.TextIOWrapper.reconfigure` instead: it changes encoding in
place without touching buffering or newline mode.
"""

from __future__ import annotations

import json
import sys
from typing import Any, Dict, Optional

# Sentinel printed on its own line to mark the end of one response in the
# interactive protocol. The Flutter side reads stdout until it sees this.
RESPONSE_SENTINEL = "__RESPONSE_END__"


def configure_stdio_utf8() -> None:
    """Force UTF-8 on stdin/stdout/stderr without changing buffering.

    Uses :meth:`io.TextIOWrapper.reconfigure` so the existing wrappers
    keep their original buffering and newline behavior — critical on
    Windows where the Flutter subprocess host expects ``\\r\\n`` line
    endings on stdout and would otherwise hang waiting for
    ``__READY__``.

    Safe to call more than once. No-op on streams that don't expose
    ``reconfigure`` (e.g. captured pipes in some test harnesses).
    """
    for stream in (sys.stdin, sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8")
            except (ValueError, OSError):
                # Streams already detached or attached to a non-text
                # buffer: leave them alone, encoding will fall back to
                # whatever Python picked at startup.
                pass


def read_interactive_request(stream) -> Optional[Dict[str, Any]]:
    """Read one line (JSON object) from ``stream``.

    Returns:
      - ``None`` on EOF (parent process closed stdin).
      - A normalised dict ``{"prompt": str, "new_session": bool,
        "history": list}`` for JSON input.
      - A normalised dict treating the raw line as the prompt for
        backwards-compatibility with the old plain-text protocol.
    """
    line = stream.readline()
    if not line:
        return None
    line = line.strip()
    if not line:
        return {"prompt": "", "new_session": False, "history": []}
    if line.startswith("{"):
        try:
            obj = json.loads(line)
            if isinstance(obj, dict):
                obj.setdefault("prompt", "")
                obj.setdefault("new_session", False)
                obj.setdefault("history", [])
                return obj
        except json.JSONDecodeError:
            pass
    return {"prompt": line, "new_session": False, "history": []}
