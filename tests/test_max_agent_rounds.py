"""Tests for the configurable AUTO INPUT round cap.

``max_auto_rounds`` bounds the Assistant <-> User exchange performed by
``Orchestrator._run_auto_input_loop``. It is configured in Settings ->
Workflow Agents MaM -> "Maximum Auto Round Actions" and forwarded by the
Flutter launcher as ``--max-agent-rounds``.

Covered here:

* ``_clamp_auto_rounds`` — the single coercion point, tolerant of ``None``,
  empty strings, junk and out-of-range numbers.
* ``Orchestrator.max_auto_rounds`` — the clamp is applied when the attribute is
  seeded from the constructor argument, and the default is preserved for
  callers that never pass one (single-agent orchestrator, older launchers).
* The ``--max-agent-rounds`` argparse contract of ``orchestrator_multi``: the
  flag exists, defaults to 20, and accepts an explicit override.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import pytest

_BIN_DIR = Path(__file__).resolve().parents[1] / "bin"
if str(_BIN_DIR) not in sys.path:
    sys.path.insert(0, str(_BIN_DIR))

import orchestrator_multi  # noqa: E402  (imports follow the sys.path bootstrap above)

from agent.loop.run_loop import (  # noqa: E402
    _DEFAULT_MAX_AUTO_ROUNDS,
    _MAX_AUTO_ROUNDS_CAP,
    _MIN_AUTO_ROUNDS,
    Orchestrator,
    _clamp_auto_rounds,
)


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------


class _FakeBackend:
    """Backend double carrying only what the Orchestrator constructor reads."""

    model_id = "fake-model"
    context_limit = 0

    def __init__(self) -> None:
        self.calls: List[Dict[str, Any]] = []

    def chat(
        self,
        conversation: Any,
        max_tokens: int,
        temperature: float,
        tools: Optional[List[Dict[str, Any]]] = None,
        stop: Optional[List[str]] = None,
        thinking: bool = False,
        effort: Optional[str] = None,
        on_thinking: Optional[Any] = None,
    ) -> Tuple[str, str]:
        self.calls.append({"max_tokens": max_tokens})
        return "ok", "stop"


def _make_orchestrator(**overrides: Any) -> Orchestrator:
    kwargs: Dict[str, Any] = {
        "backend": _FakeBackend(),
        "base_path": ".",
        "task_mode": "open",
        "max_iterations": 1,
    }
    kwargs.update(overrides)
    return Orchestrator(**kwargs)


# ----------------------------------------------------------------------
# _clamp_auto_rounds
# ----------------------------------------------------------------------


@pytest.mark.parametrize("value", [None, "", "abc", "   "])
def test_clamp_falls_back_to_the_default(value: Any) -> None:
    assert _clamp_auto_rounds(value) == _DEFAULT_MAX_AUTO_ROUNDS


@pytest.mark.parametrize("value", [0, -5, -1, "-12"])
def test_clamp_lifts_values_below_the_minimum(value: Any) -> None:
    assert _clamp_auto_rounds(value) == _MIN_AUTO_ROUNDS


@pytest.mark.parametrize("value", [1, 20, 200, 7])
def test_clamp_keeps_in_range_values(value: Any) -> None:
    assert _clamp_auto_rounds(value) == value


@pytest.mark.parametrize("value", [201, 10_000, "9999"])
def test_clamp_caps_values_above_the_maximum(value: Any) -> None:
    assert _clamp_auto_rounds(value) == _MAX_AUTO_ROUNDS_CAP


def test_clamp_accepts_numeric_strings() -> None:
    """argparse-free callers (tests, embedders) may hand over strings."""
    assert _clamp_auto_rounds("12") == 12


def test_clamp_bounds_are_ordered() -> None:
    assert _MIN_AUTO_ROUNDS <= _DEFAULT_MAX_AUTO_ROUNDS <= _MAX_AUTO_ROUNDS_CAP


# ----------------------------------------------------------------------
# Orchestrator attribute
# ----------------------------------------------------------------------


def test_max_auto_rounds_defaults_when_not_configured() -> None:
    assert _make_orchestrator().max_auto_rounds == _DEFAULT_MAX_AUTO_ROUNDS


@pytest.mark.parametrize(
    ("given", "expected"), [(0, 1), (7, 7), (500, 200), (None, 20)]
)
def test_max_auto_rounds_is_clamped_on_the_instance(
    given: Optional[int], expected: int
) -> None:
    assert _make_orchestrator(max_auto_rounds=given).max_auto_rounds == expected


def test_max_auto_rounds_survives_reset() -> None:
    """The cap is a launcher setting, not per-request state."""
    orchestrator = _make_orchestrator(max_auto_rounds=5)
    orchestrator.reset()
    assert orchestrator.max_auto_rounds == 5


# ----------------------------------------------------------------------
# CLI flag contract (--max-agent-rounds)
# ----------------------------------------------------------------------


def test_cli_flag_defaults_to_the_builtin_cap() -> None:
    args = orchestrator_multi._build_arg_parser().parse_args([])
    assert args.max_agent_rounds == _DEFAULT_MAX_AUTO_ROUNDS


def test_cli_flag_accepts_an_override() -> None:
    args = orchestrator_multi._build_arg_parser().parse_args(
        ["--max-agent-rounds", "7"]
    )
    assert args.max_agent_rounds == 7


def test_cli_flag_parses_as_int() -> None:
    args = orchestrator_multi._build_arg_parser().parse_args(
        ["--max-agent-rounds", "35"]
    )
    assert args.max_agent_rounds == 35


def test_cli_flag_rejects_non_numeric_values() -> None:
    with pytest.raises(SystemExit):
        orchestrator_multi._build_arg_parser().parse_args(
            ["--max-agent-rounds", "abc"]
        )