"""`AGENTIC_SESSION_ID` stamping — echo behaviour and absent-safety.

Multi-session architecture: the Flutter client runs one orchestrator subprocess
per conversation, so several `[orch]` stderr streams may be collected together.
`bin/agent/utils/session_env.py` stamps every line with the owning chat's short
GUID. With the variable unset the output must stay byte-identical to the
historical format — that is the contract these tests pin.
"""

from __future__ import annotations

import io
import sys
from pathlib import Path

BIN_DIR = Path(__file__).resolve().parents[1] / "bin"
if str(BIN_DIR) not in sys.path:
    sys.path.insert(0, str(BIN_DIR))

from agent.utils.session_env import (  # noqa: E402  (path set above)
    BASE_LOG_PREFIX,
    SESSION_ID_ENV,
    _StampingStream,
    audit_context,
    audit_prefix,
    format_log_line,
    install_stderr_stamping,
    log_prefix,
    session_id,
    short_session_id,
    strip_session_tag,
)

GUID = "023862d4-31fa-41e0-ace5-e34b2033628f"


# ---------------------------------------------------------------- helpers
def test_session_id_reads_the_env_var():
    assert session_id({SESSION_ID_ENV: GUID}) == GUID


def test_session_id_is_empty_when_unset():
    assert session_id({}) == ""
    assert session_id({SESSION_ID_ENV: ""}) == ""
    assert session_id({SESSION_ID_ENV: "   "}) == ""


def test_session_id_strips_unsafe_characters():
    # Newlines would split a log line and confuse the Flutter log panel.
    assert session_id({SESSION_ID_ENV: "ab\ncd\r\x00ef [x]"}) == "abcdefx"


def test_short_session_id_is_eight_characters():
    assert short_session_id({SESSION_ID_ENV: GUID}) == GUID[:8]
    assert short_session_id({}) == ""


def test_log_prefix_echoes_the_guid():
    assert log_prefix({SESSION_ID_ENV: GUID}) == f"{BASE_LOG_PREFIX} [{GUID[:8]}]"


def test_log_prefix_is_unchanged_when_absent():
    assert log_prefix({}) == BASE_LOG_PREFIX
    assert log_prefix(None) == BASE_LOG_PREFIX


def test_format_log_line_echoes_and_is_absent_safe():
    stamped = format_log_line("Local Orchestrator ready.", {SESSION_ID_ENV: GUID})
    assert stamped == f"[orch] [{GUID[:8]}] Local Orchestrator ready."
    assert (
        format_log_line("Local Orchestrator ready.", {})
        == "[orch] Local Orchestrator ready."
    )


def test_strip_session_tag_round_trips():
    plain = "[orch] -> tool run_command"
    stamped = format_log_line("-> tool run_command", {SESSION_ID_ENV: GUID})
    assert strip_session_tag(stamped) == plain
    # Absent-safe: an untagged line is returned unchanged.
    assert strip_session_tag(plain) == plain
    assert strip_session_tag("") == ""


def test_audit_helpers_echo_and_are_absent_safe():
    assert audit_context({SESSION_ID_ENV: GUID}) == {"session": GUID}
    assert audit_context({}) == {}
    assert audit_prefix({SESSION_ID_ENV: GUID}) == f"SESSION={GUID} "
    assert audit_prefix({}) == ""


# ------------------------------------------------------- stderr stamping
def _capture(monkeypatch, environ=None):
    """Swap `sys.stderr` for a StringIO, install the proxy, return the buffer."""
    buffer = io.StringIO()
    monkeypatch.setattr(sys, "stderr", buffer)
    installed = install_stderr_stamping(environ)
    return installed, buffer


def test_install_is_a_noop_when_the_variable_is_unset(monkeypatch):
    installed, _ = _capture(monkeypatch, {})
    assert installed is False
    assert isinstance(sys.stderr, io.StringIO)


def test_every_orch_line_is_stamped(monkeypatch):
    installed, buffer = _capture(monkeypatch, {SESSION_ID_ENV: GUID})
    assert installed is True

    print("[orch] Audit logging enabled -> logs/a.log", file=sys.stderr)
    print("unrelated output", file=sys.stderr)
    sys.stderr.flush()

    lines = buffer.getvalue().splitlines()
    assert lines[0] == f"[orch] [{GUID[:8]}] Audit logging enabled -> logs/a.log"
    # Non-`[orch]` output is never rewritten.
    assert lines[1] == "unrelated output"


def test_partial_writes_are_stitched_into_one_line(monkeypatch):
    installed, buffer = _capture(monkeypatch, {SESSION_ID_ENV: GUID})
    assert installed is True

    sys.stderr.write("[orch] split ")
    sys.stderr.write("message\n")
    sys.stderr.flush()
    assert buffer.getvalue() == f"[orch] [{GUID[:8]}] split message\n"


def test_stamping_is_idempotent(monkeypatch):
    installed, buffer = _capture(monkeypatch, {SESSION_ID_ENV: GUID})
    assert installed is True

    # `Orchestrator._log` already built a stamped line through format_log_line.
    print(format_log_line("model reply", {SESSION_ID_ENV: GUID}), file=sys.stderr)
    sys.stderr.flush()
    assert buffer.getvalue().count(f"[{GUID[:8]}]") == 1


def test_install_is_not_applied_twice(monkeypatch):
    _capture(monkeypatch, {SESSION_ID_ENV: GUID})
    assert install_stderr_stamping({SESSION_ID_ENV: GUID}) is False


def test_proxy_forwards_stream_attributes():
    wrapped = io.StringIO()
    stream = _StampingStream(wrapped, "[orch] [deadbeef]")
    assert stream.encoding == wrapped.encoding
    stream.write("plain\n")
    stream.flush()
    assert wrapped.getvalue() == "plain\n"