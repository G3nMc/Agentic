"""Per-session identity for concurrent orchestrator processes.

Multi-session architecture
--------------------------
The Flutter client runs one orchestrator subprocess per conversation, so several
processes can be alive at the same time. Each one writes its own
``logs/<guid>.log`` and its own audit trail, but the raw ``[orch]`` stderr lines
of two processes are otherwise indistinguishable when they are collected in a
single terminal or forwarded to the same log sink.

The client therefore exports an optional ``AGENTIC_SESSION_ID`` environment
variable containing the chat GUID when it launches the subprocess. This module is
the single reader of that variable:

* :func:`session_id` returns the raw, sanitised GUID (``""`` when unset).
* :func:`short_session_id` returns a compact, log-friendly form.
* :func:`log_prefix` builds the ``[orch] [<sid>]`` prefix.
* :func:`format_log_line` builds a fully stamped diagnostic line.
* :func:`strip_session_tag` removes the stamp for downstream parsers.
* :func:`audit_prefix` / :func:`audit_context` stamp audit records.
* :func:`install_stderr_stamping` proxies ``sys.stderr`` so every ``[orch]``
  line of the process is stamped, including the ones printed directly by the
  CLI shim and the backends.

Everything here is **absent-safe**: with the variable unset every helper returns
exactly what the orchestrator produced before this module existed, so a
standalone ``python bin/orchestrator.py`` run is byte-identical to the previous
behaviour.
"""

from __future__ import annotations

import os
import re
import sys
from typing import Any, Dict, Mapping, Optional

#: Environment variable carrying the chat GUID of the owning conversation.
SESSION_ID_ENV = "AGENTIC_SESSION_ID"

#: Prefix every orchestrator diagnostic line, independent of the session.
BASE_LOG_PREFIX = "[orch]"

#: Number of GUID characters kept in a stamped log line. Chat GUIDs are UUIDv4
#: strings; eight hex characters are already unique within a session list and
#: keep the diagnostic lines narrow.
_SHORT_ID_LENGTH = 8

#: Characters allowed inside an env-supplied session id. Anything else is
#: stripped so an odd value can never inject newlines or tags into the log
#: stream, which the Flutter log panel parses line by line.
_SAFE_ID_RE = re.compile(r"[^0-9A-Za-z_-]")


def _clean(value: Optional[str]) -> str:
    """Return a log-safe, trimmed session id (never ``None``)."""
    if not value:
        return ""
    return _SAFE_ID_RE.sub("", value.strip())


def session_id(environ: Optional[Mapping[str, str]] = None) -> str:
    """Return the session GUID for this process, or ``""`` when unset."""
    env = os.environ if environ is None else environ
    return _clean(env.get(SESSION_ID_ENV))


def short_session_id(environ: Optional[Mapping[str, str]] = None) -> str:
    """Return the truncated session GUID shown in log lines (``""`` if unset)."""
    return session_id(environ)[:_SHORT_ID_LENGTH]


def log_prefix(environ: Optional[Mapping[str, str]] = None) -> str:
    """Return the ``[orch]`` prefix, stamped with the session id when known.

    * unset -> ``"[orch]"``
    * set   -> ``"[orch] [023862d4]"``
    """
    sid = short_session_id(environ)
    if not sid:
        return BASE_LOG_PREFIX
    return f"{BASE_LOG_PREFIX} [{sid}]"


def format_log_line(
    message: str,
    environ: Optional[Mapping[str, str]] = None,
) -> str:
    """Build one stamped diagnostic line (no trailing newline)."""
    return f"{log_prefix(environ)} {message}"


def strip_session_tag(line: str) -> str:
    """Remove a leading session stamp from ``line``.

    Consumers that pattern-match on the historical ``[orch] <verb>`` shape keep
    working on stamped lines. A line without a stamp is returned unchanged.
    """
    if not line:
        return line
    marker = f"{BASE_LOG_PREFIX} ["
    if line.startswith(marker):
        end = line.find("] ", len(marker))
        if end != -1:
            return f"{BASE_LOG_PREFIX} {line[end + 2:]}"
    return line


def audit_context(environ: Optional[Mapping[str, str]] = None) -> Dict[str, Any]:
    """Extra fields to merge into an audit record (``{}`` when unset)."""
    sid = session_id(environ)
    if not sid:
        return {}
    return {"session": sid}


def audit_prefix(environ: Optional[Mapping[str, str]] = None) -> str:
    """Ready-to-format audit-log prefix (``"SESSION=<guid> "`` or ``""``)."""
    sid = session_id(environ)
    return f"SESSION={sid} " if sid else ""


# ----------------------------------------------------------------------
# Process-wide stderr stamping
# ----------------------------------------------------------------------
#
# ``Orchestrator._log`` is the main diagnostic channel, but several modules
# (the CLI shim's preflight, ``rate_limit``, ``backend_base``, ``history``)
# print ``[orch]`` lines directly. Rather than touch every call site, the entry
# point installs a thin pass-through proxy on ``sys.stderr`` that stamps
# complete lines as they are written.
#
# The proxy delegates ``flush``, ``fileno``, ``isatty`` and every other
# attribute to the wrapped stream and leaves buffering untouched -- it only
# rewrites the *text* of a finished line. That keeps the stdout/stdin contract
# described in :mod:`agent.utils.io_protocol` intact.


def _stamp_line(line: str, prefix: str) -> str:
    """Stamp one finished line; already-stamped and non-``[orch]`` lines pass."""
    stripped = line.lstrip()
    if not stripped.startswith(BASE_LOG_PREFIX):
        return line
    if stripped.startswith(f"{BASE_LOG_PREFIX} ["):
        # Already carrying a session tag (e.g. built by ``format_log_line``).
        # Idempotent by design.
        return line
    indent = line[: len(line) - len(stripped)]
    return f"{indent}{prefix}{stripped[len(BASE_LOG_PREFIX):]}"


class _StampingStream:
    """Minimal ``sys.stderr`` proxy that prefixes ``[orch]`` lines.

    Write calls are accumulated until a newline arrives so a partially written
    line is never stamped twice. Any attribute not implemented here is proxied
    to the wrapped stream, so ``fileno()``, ``encoding``, ``errors`` and
    ``isatty()`` keep working.
    """

    def __init__(self, wrapped: Any, prefix: str) -> None:
        self._wrapped = wrapped
        self._prefix = prefix
        self._buffer = ""

    # -- attribute passthrough -----------------------------------------
    def __getattr__(self, name: str) -> Any:
        return getattr(self._wrapped, name)

    # -- writing -------------------------------------------------------
    def write(self, text: str) -> int:
        if not isinstance(text, str):
            return self._wrapped.write(text)
        self._buffer += text
        out = []
        while True:
            newline = self._buffer.find("\n")
            if newline == -1:
                break
            out.append(_stamp_line(self._buffer[: newline + 1], self._prefix))
            self._buffer = self._buffer[newline + 1 :]
        if out:
            self._wrapped.write("".join(out))
        return len(text)

    def flush(self) -> None:
        if self._buffer:
            self._wrapped.write(_stamp_line(self._buffer, self._prefix))
            self._buffer = ""
        self._wrapped.flush()


def install_stderr_stamping(environ: Optional[Mapping[str, str]] = None) -> bool:
    """Install the stamping proxy on ``sys.stderr`` for this process.

    Returns ``True`` when the proxy was installed. It is a **no-op** -- and
    returns ``False`` -- when ``AGENTIC_SESSION_ID`` is unset or when the proxy
    is already installed, so a standalone CLI run keeps its historical output
    and repeated calls are harmless.
    """
    prefix = log_prefix(environ)
    if prefix == BASE_LOG_PREFIX:
        return False
    stream = sys.stderr
    if isinstance(stream, _StampingStream):
        return False
    sys.stderr = _StampingStream(stream, prefix)
    return True