"""Tests for synthesis directive selection in the run loop."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import pytest

_BIN_DIR = Path(__file__).resolve().parents[1] / "bin"
if str(_BIN_DIR) not in sys.path:
    sys.path.insert(0, str(_BIN_DIR))

from agent.loop.run_loop import Orchestrator
from agent.prompts import get_system_prompt_value


class _FakeBackend:
    """Minimal backend that returns a fixed plain-text answer."""

    model_id = "fake-model"
    context_limit = 0

    def __init__(self, answer: str = "Work completed.") -> None:
        self.answer = answer
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
        self.calls.append(
            {
                "system_text": conversation.system_text(),
                "max_tokens": max_tokens,
            }
        )
        return self.answer, "stop"


def _make_orchestrator(backend: _FakeBackend) -> Orchestrator:
    return Orchestrator(
        backend=backend,
        base_path=".",
        task_mode="open",
        max_iterations=1,
    )


def test_synthesis_uses_tool_activity_directive_when_tools_ran() -> None:
    backend = _FakeBackend()
    orch = _make_orchestrator(backend)
    orch._turn.successful_tools = 2

    result = orch._attempt_synthesis(had_tool_activity=True)

    assert result == "Work completed."
    assert backend.calls, "expected at least one synthesis call"
    system_text = backend.calls[0]["system_text"]
    assert "You executed tools this turn" in system_text
    assert "Do NOT ask a clarifying question" in system_text


def test_synthesis_uses_default_directive_without_tool_activity() -> None:
    backend = _FakeBackend()
    orch = _make_orchestrator(backend)

    result = orch._attempt_synthesis(had_tool_activity=False)

    assert result == "Work completed."
    assert backend.calls, "expected at least one synthesis call"
    system_text = backend.calls[0]["system_text"]
    assert "You executed tools this turn" not in system_text
    assert "ask EXACTLY ONE clarifying question" in system_text


def test_build_recap_answer_passes_tool_activity_flag() -> None:
    backend = _FakeBackend()
    orch = _make_orchestrator(backend)
    orch._turn.successful_tools = 1

    result = orch._build_recap_answer(reason="final answer empty after cleaning")

    assert result == "Work completed."
    assert backend.calls, "expected at least one synthesis call"
    system_text = backend.calls[0]["system_text"]
    assert "You executed tools this turn" in system_text


def test_tool_activity_directive_is_registered() -> None:
    directive = get_system_prompt_value("SYNTHESIS_TOOL_ACTIVITY_DIRECTIVE")
    assert "You executed tools this turn" in directive
    assert "Do NOT ask a clarifying question" in directive