"""Protocol contract for the Flutter <-> orchestrator stdin framing.

Covers the two additive fields the UI relies on:

* ``request_id`` — echoed untouched so an envelope belonging to a turn the user
  already aborted can be discarded instead of landing in the next turn.
* ``{"action": "shutdown"}`` — a control line that must be returned verbatim
  (no prompt/history default-filling) so the interactive loops can tell it
  apart from a chat turn and leave ``while True`` cleanly. Terminating abruptly
  would drop the audit log and the per-chat log file.
"""

from __future__ import annotations

import io
import sys
from pathlib import Path

import pytest

BIN_DIR = Path(__file__).resolve().parents[1] / "bin"
if str(BIN_DIR) not in sys.path:
    sys.path.insert(0, str(BIN_DIR))

from agent.utils.io_protocol import (  # noqa: E402  (path set above)
    RESPONSE_SENTINEL,
    read_interactive_request,
)


def _read(line: str):
    """Feed one line to the real reader, exactly as the loops do."""
    return read_interactive_request(io.StringIO(line))


def test_sentinel_is_unchanged():
    assert RESPONSE_SENTINEL == "__RESPONSE_END__"


def test_request_id_is_passed_through():
    req = _read('{"prompt": "hi", "request_id": "abc-123"}')

    assert req is not None
    assert req["request_id"] == "abc-123"
    # The normal defaults are still applied alongside the correlation id.
    assert req["prompt"] == "hi"
    assert req["new_session"] is False
    assert req["history"] == []
    assert req["thinking"] is False
    assert req["effort"] is None


def test_request_id_survives_when_only_the_id_is_sent():
    req = _read('{"request_id": "only-id"}')

    assert req is not None
    assert req["request_id"] == "only-id"
    # A prompt-less turn is still a valid envelope: the loop answers with the
    # sentinel and continues rather than dying.
    assert req["prompt"] == ""


def test_shutdown_line_is_returned_verbatim():
    req = _read('{"action": "shutdown"}')

    assert req == {"action": "shutdown"}
    # No chat-turn keys are injected: the loops must see this as a control
    # line, not as an empty prompt.
    assert "prompt" not in req
    assert "history" not in req
    assert "new_session" not in req


def test_shutdown_line_wins_over_other_keys():
    req = _read('{"action": "shutdown", "prompt": "ignored", "request_id": "x"}')

    assert req is not None
    assert req["action"] == "shutdown"
    assert req["prompt"] == "ignored"


def test_unknown_action_does_not_crash():
    req = _read('{"action": "pause", "prompt": "hi"}')

    assert req is not None
    assert req["action"] == "pause"
    assert req["prompt"] == "hi"
    assert req["history"] == []


def test_eof_returns_none():
    assert read_interactive_request(io.StringIO("")) is None


def test_blank_line_is_a_no_op_turn():
    req = _read("\n")

    assert req is not None
    assert req["prompt"] == ""
    assert req["new_session"] is False


def test_malformed_json_falls_back_to_empty_turn():
    req = _read('{"prompt": ')

    assert req is not None
    assert req["prompt"] == ""
    assert req["history"] == []


@pytest.mark.parametrize("action", ["shutdown", "pause", "resume", ""])
def test_arbitrary_action_values_are_tolerated(action):
    """Any ``action`` value must be readable without raising."""
    req = _read('{"action": "%s"}' % action)

    assert req is not None
    assert req.get("action") == action