"""Regression tests for the Workflow Agents ``User`` slot CLI contract.

The Flutter client (``OrchestratorManager._appendUserAgentArgs``) always emits
the same ``--user-*`` block, whichever Python entry point is launched. The
block used to exist only in ``orchestrator_multi.py``, so single-agent mode
died with ``error: unrecognized arguments`` before ``__READY__`` was printed
and the UI surfaced it as a bogus "is Ollama running?" failure.

These tests pin the contract from both sides:

* both parsers must advertise the full ``--user-*`` surface, and
* the single-agent entry point must forward the generation knobs into the
  run-loop ``Orchestrator``.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path
from typing import Any, List

import pytest

_BIN_DIR = Path(__file__).resolve().parents[1] / "bin"
if str(_BIN_DIR) not in sys.path:
    sys.path.insert(0, str(_BIN_DIR))

import orchestrator  # noqa: E402
import orchestrator_base  # noqa: E402
from agent.loop.run_loop import Orchestrator  # noqa: E402

# Flags emitted unconditionally by ``_appendUserAgentArgs`` plus the optional
# per-slot TPM cap. Every entry point must accept all of them.
_USER_SLOT_FLAGS = (
    "--user-provider",
    "--user-model",
    "--user-api-key",
    "--user-base-url",
    "--user-num-ctx",
    "--user-context-window",
    "--user-temperature",
    "--user-max-tokens",
    "--user-reasoning-level",
    "--user-thinking",
    "--user-no-thinking",
    "--user-tpm-limit",
)

# The exact tail the Flutter client appends in the failing report.
_CLIENT_USER_FLAGS = [
    "--user-context-window",
    "262144",
    "--user-temperature",
    "0.2",
    "--user-max-tokens",
    "16384",
    "--user-reasoning-level",
    "max",
    "--user-no-thinking",
]


class _FakeBackend:
    """Backend double carrying only the attributes the entry point reads."""

    def __init__(self, model_id: str) -> None:
        self.model_id = model_id
        self.context_limit = 0


def _help_text(script_name: str) -> str:
    """Return ``--help`` output for *script_name* (no side effects)."""
    result = subprocess.run(
        [sys.executable, str(_BIN_DIR / script_name), "--help"],
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert result.returncode == 0, result.stderr
    return result.stdout


@pytest.mark.parametrize("script_name", ["orchestrator.py", "orchestrator_multi.py"])
def test_both_entry_points_expose_the_user_slot_flags(script_name: str) -> None:
    help_text = _help_text(script_name)
    missing = [flag for flag in _USER_SLOT_FLAGS if flag not in help_text]
    assert missing == [], f"{script_name} does not expose {missing}"


def test_user_generation_defaults_map_cli_values_to_a_typed_record() -> None:
    defaults = orchestrator_base._build_user_generation_defaults(
        argparse.Namespace(
            user_temperature=0.2,
            user_max_tokens=16384,
            user_reasoning_level="MAX",
            user_thinking=False,
        )
    )
    assert defaults.temperature == pytest.approx(0.2)
    assert defaults.max_tokens == 16384
    assert defaults.effort == "max"
    assert defaults.thinking is False


def test_user_generation_defaults_keep_loop_fallbacks_when_unset() -> None:
    defaults = orchestrator_base._build_user_generation_defaults(argparse.Namespace())
    assert defaults.temperature is None
    assert defaults.max_tokens == 0
    assert defaults.effort is None
    assert defaults.thinking is False


def test_single_agent_forwards_user_slot_generation_flags(monkeypatch) -> None:
    """The failing argv must parse and reach the Orchestrator constructor."""
    captured: List[Any] = []

    monkeypatch.setattr(orchestrator, "sync_prompts_config", lambda: None)
    monkeypatch.setattr(
        orchestrator, "_build_backend_for_args", lambda args: _FakeBackend("assistant")
    )
    monkeypatch.setattr(
        orchestrator,
        "_build_user_backend_for_args",
        lambda args, **kwargs: _FakeBackend("user"),
    )
    monkeypatch.setattr(orchestrator, "_load_path_filter", lambda *a, **k: None)
    monkeypatch.setattr(orchestrator, "_load_db_connections", lambda *a, **k: {})
    monkeypatch.setattr(orchestrator, "_run_interactive_loop", lambda orch, args=None: captured.append(orch))
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "orchestrator.py",
            "--backend",
            "ollama",
            "--model",
            "glm-5.3-flash",
            "--task-mode",
            "auto_input",
            "--user-provider",
            "ollama",
            "--user-model",
            "glm-5.3-flash",
            *_CLIENT_USER_FLAGS,
            "--user-tpm-limit",
            "500",
            "--interactive",
        ],
    )

    orchestrator.main()

    assert len(captured) == 1
    instance = captured[0]
    assert isinstance(instance, Orchestrator)
    assert instance.user_temperature == pytest.approx(0.2)
    assert instance.user_max_tokens == 16384
    assert instance.user_effort == "max"
    assert instance.user_thinking is False


def test_single_agent_honours_user_thinking_opt_in(monkeypatch) -> None:
    captured: List[Any] = []

    monkeypatch.setattr(orchestrator, "sync_prompts_config", lambda: None)
    monkeypatch.setattr(
        orchestrator, "_build_backend_for_args", lambda args: _FakeBackend("assistant")
    )
    monkeypatch.setattr(
        orchestrator,
        "_build_user_backend_for_args",
        lambda args, **kwargs: _FakeBackend("user"),
    )
    monkeypatch.setattr(orchestrator, "_load_path_filter", lambda *a, **k: None)
    monkeypatch.setattr(orchestrator, "_load_db_connections", lambda *a, **k: {})
    monkeypatch.setattr(orchestrator, "_run_interactive_loop", lambda orch, args=None: captured.append(orch))
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "orchestrator.py",
            "--backend",
            "ollama",
            "--model",
            "glm-5.3-flash",
            "--user-provider",
            "ollama",
            "--user-model",
            "glm-5.3-flash",
            "--user-thinking",
            "--interactive",
        ],
    )

    orchestrator.main()

    assert captured[0].user_thinking is True
    # Unset knobs keep the loop's documented fallbacks.
    assert captured[0].user_temperature == pytest.approx(0.1)
    assert captured[0].user_max_tokens == 1024
    assert captured[0].user_effort is None