"""Stdin/stdout framing for the interactive protocol used by the Flutter UI."""

from __future__ import annotations

import io
import json
import sys
from typing import Any, Dict, Optional

# Sentinel printed on its own line to mark the end of one response in the
# interactive protocol. The Flutter side reads stdout until it sees this.
RESPONSE_SENTINEL = "__RESPONSE_END__"


def configure_stdio_utf8() -> None:
    """Force UTF-8 on Windows consoles so emojis / non-ASCII don't crash.

    Safe to call more than once: it's a no-op when stdout/stderr already
    use UTF-8 (Linux, macOS, Python 3.15+ on Windows with PEP 686).
    """
    if sys.platform == "win32" and sys.stdout.encoding != "utf-8":
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", newline="\n")
        sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", newline="\n")


def read_interactive_request(stream) -> Optional[Dict[str, Any]]:
    """
    Read one line (JSON object) from stdin. Returns None on EOF.
    Accepts either a JSON object {"prompt": "...", "new_session": bool}
    or a raw line (treated as the prompt) for backward compatibility.
    """
    line = stream.readline()
    if not line:
        return None
    line = line.strip()
    if not line:
        return {"prompt": "", "new_session": False}
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
    return {"prompt": line, "new_session": False}
