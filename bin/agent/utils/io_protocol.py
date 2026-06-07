"""I/O protocol utilities for the orchestrator."""

import sys
import json

RESPONSE_SENTINEL = "__RESPONSE_END__"


def configure_stdio_utf8():
    """Reconfigure stdin/stdout to use UTF-8 encoding."""
    if hasattr(sys.stdin, 'reconfigure'):
        sys.stdin.reconfigure(encoding='utf-8')
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')


def read_interactive_request(stream):
    """Read one JSON object per line from stream. Returns dict or None on EOF."""
    line = stream.readline()
    if not line:
        return None
    line = line.strip()
    if not line:
        return None
    try:
        return json.loads(line)
    except json.JSONDecodeError:
        return None
