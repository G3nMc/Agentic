"""Tests for the multi-slot (Workflow Agents) orchestrator entry point.

Covers the mapping between the Workflow Agents slots (REASONER / USER)
and the run-loop backend, plus the crash-resilience of the interactive loop
when a session cannot be created.
"""

from __future__ import annotations

import argparse
import io
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

import pytest

_BIN_DIR = Path(__file__).resolve().parents[1] / "bin"
if str(_BIN_DIR) not in sys.path:
    sys.path.insert(0, str(_BIN_DIR))

import orchestrator_multi
from agent.loop.task_protocol import TaskMode


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------


class _FakeBackend:
    """Backend double that only carries the attributes the entry point reads."""

    def __init__(self, model_id: str) -> None:
        self.model_id = model_id
        self.context_limit = 0


class _FakeOrchestrator:
    """Run-loop double recording the constructor kwargs and driven requests."""

    instances: List["_FakeOrchestrator"] = []

    def __init__(self, **kwargs: Any) -> None:
        self.kwargs = kwargs
        self.backend = kwargs.get("backend")
        self.task_mode = TaskMode.parse(kwargs.get("task_mode") or "open")
        self.user_backend = kwargs.get("user_backend")
        # The entry point logs the effective AUTO INPUT round cap, so the double
        # must expose it exactly like the real Orchestrator does.
        self.max_auto_rounds = kwargs.get("max_auto_rounds", 20)
        self.driver_label = "ASSISTANT"
        self.thinking = False
        self.effort = None
        self.answer = "Done."
        self.reset_calls = 0
        self.imported_history: List[Dict[str, str]] = []
        self.prompts: List[str] = []
        _FakeOrchestrator.instances.append(self)

    def reset(self) -> None:
        self.reset_calls += 1

    def import_history(self, history: List[Dict[str, str]]) -> None:
        self.imported_history = list(history)

    def run(self, prompt: str) -> str:
        self.prompts.append(prompt)
        return self.answer


def _args(**overrides: Any) -> argparse.Namespace:
    """argparse.Namespace with the defaults the entry point expects."""
    values: Dict[str, Any] = {
        "reasoner_provider": "ollama",
        "reasoner_model": "glm-5.3-flash",
        "reasoner_api_key": "",
        "reasoner_base_url": "",
        "reasoner_context_window": None,
        "reasoning_level": "max",
        "user_provider": "",
        "user_model": "",
        "user_api_key": "",
        "user_base_url": "",
        "user_num_ctx": 0,
        "temperature": 0.1,
        "max_tokens": 32768,
        "max_iterations": 100,
        "max_agent_rounds": 20,
        "task_mode": "open",
        "base_path": ".",
        "sandbox": False,
        "disable_tools": False,
        "is_debug": False,
        "file_name": "",
    }
    values.update(overrides)
    return argparse.Namespace(**values)


@pytest.fixture(autouse=True)
def _isolated_env(monkeypatch):
    """Keep provider API keys out of the tests unless a test sets one."""
    for env_name in (
        "HF_TOKEN",
        "OLLAMA_API_KEY",
        "GEMINI_API_KEY",
        "GOOGLE_API_KEY",
        "GROQ_API_KEY",
        "OPENROUTER_API_KEY",
        "GITHUB_TOKEN",
        "GITHUB_API_KEY",
    ):
        monkeypatch.delenv(env_name, raising=False)
    _FakeOrchestrator.instances.clear()


# ----------------------------------------------------------------------
# Slot -> backend mapping
# ----------------------------------------------------------------------


def test_resolve_api_key_prefers_explicit_value(monkeypatch):
    monkeypatch.setenv("GROQ_API_KEY", "env-key")
    assert orchestrator_multi._resolve_api_key("groq", "explicit") == "explicit"


def test_resolve_api_key_falls_back_to_env(monkeypatch):
    monkeypatch.setenv("GROQ_API_KEY", "env-key")
    assert orchestrator_multi._resolve_api_key("groq", "") == "env-key"


def test_resolve_api_key_unknown_provider_returns_empty():
    assert orchestrator_multi._resolve_api_key("mystery", "") == ""


def test_build_slot_backend_requires_provider_and_model(monkeypatch):
    calls: List[tuple] = []
    monkeypatch.setattr(
        orchestrator_multi, "build_backend", lambda *a, **k: calls.append((a, k))
    )

    assert orchestrator_multi._build_slot_backend("", "m", "", "", None, "REASONER") is None
    assert orchestrator_multi._build_slot_backend("ollama", "", "", "", None, "REASONER") is None
    assert calls == []


def test_build_slot_backend_maps_ollama_context_to_num_ctx(monkeypatch):
    captured: Dict[str, Any] = {}

    def fake_build(name: str, **kwargs: Any) -> _FakeBackend:
        captured["name"] = name
        captured.update(kwargs)
        return _FakeBackend(kwargs["model_id"])

    monkeypatch.setattr(orchestrator_multi, "build_backend", fake_build)

    backend = orchestrator_multi._build_slot_backend(
        "ollama", "glm-5.3-flash", "secret", "http://localhost:11434", 8192, "REASONER"
    )

    assert backend is not None and backend.model_id == "glm-5.3-flash"
    assert captured["name"] == "ollama"
    assert captured["api_key"] == "secret"
    assert captured["base_url"] == "http://localhost:11434"
    assert captured["num_ctx"] == 8192


def test_build_slot_backend_maps_openrouter_context_to_context_limit(monkeypatch):
    captured: Dict[str, Any] = {}

    def fake_build(name: str, **kwargs: Any) -> _FakeBackend:
        captured.update(kwargs)
        return _FakeBackend(kwargs["model_id"])

    monkeypatch.setattr(orchestrator_multi, "build_backend", fake_build)

    orchestrator_multi._build_slot_backend(
        "openrouter", "arcee/spotlight", "k", "https://openrouter.ai/api/v1", 64000, "REASONER"
    )

    assert captured["context_limit"] == 64000
    assert captured["base_url"] == "https://openrouter.ai/api/v1"


def test_build_slot_backend_omits_base_url_for_pinned_endpoints(monkeypatch):
    """groq / github / huggingface pin their endpoint and reject base_url."""
    captured: Dict[str, Any] = {}

    def fake_build(name: str, **kwargs: Any) -> _FakeBackend:
        captured.clear()
        captured.update(kwargs)
        return _FakeBackend(kwargs["model_id"])

    monkeypatch.setattr(orchestrator_multi, "build_backend", fake_build)

    orchestrator_multi._build_slot_backend(
        "groq", "llama-3.3-70b", "k", "http://ignored", 4096, "REASONER"
    )

    assert "base_url" not in captured
    assert "context_limit" not in captured


def test_build_slot_backend_returns_none_when_provider_rejects_config(monkeypatch):
    def fake_build(name: str, **kwargs: Any) -> _FakeBackend:
        raise ValueError(f"Unknown backend: {name!r}")

    monkeypatch.setattr(orchestrator_multi, "build_backend", fake_build)

    assert (
        orchestrator_multi._build_slot_backend("mystery", "m", "", "", None, "REASONER")
        is None
    )


# ----------------------------------------------------------------------
# Session construction
# ----------------------------------------------------------------------


def test_create_orchestrator_uses_reasoner_slot(monkeypatch):
    reasoner = _FakeBackend("glm-5.3-flash")
    monkeypatch.setattr(
        orchestrator_multi, "build_backend", lambda name, **kw: reasoner
    )
    monkeypatch.setattr(
        orchestrator_multi, "_build_user_backend_for_args", lambda *a, **k: None
    )
    monkeypatch.setattr(orchestrator_multi, "Orchestrator", _FakeOrchestrator)

    orchestrator = orchestrator_multi._create_orchestrator(_args(), task_mode="open")

    assert orchestrator.backend is reasoner
    assert orchestrator.kwargs["task_mode"] == "open"
    assert orchestrator.kwargs["path_filter"] is None
    assert orchestrator.kwargs["db_connections"] is None
    assert orchestrator.driver_label == "REASONER (Workflow Agents Assistant)"


def test_create_orchestrator_raises_when_reasoner_slot_cannot_be_built(monkeypatch):
    """The Assistant slot is the only driver: no other slot can take over."""

    def fake_build(name: str, **kwargs: Any) -> _FakeBackend:
        if name == "ollama" and kwargs["model_id"] == "missing-provider-model":
            raise ValueError("cannot build")
        return _FakeBackend(kwargs["model_id"])

    monkeypatch.setattr(orchestrator_multi, "build_backend", fake_build)
    monkeypatch.setattr(
        orchestrator_multi, "_build_user_backend_for_args", lambda *a, **k: None
    )
    monkeypatch.setattr(orchestrator_multi, "Orchestrator", _FakeOrchestrator)

    with pytest.raises(RuntimeError) as excinfo:
        orchestrator_multi._create_orchestrator(
            _args(
                reasoner_model="missing-provider-model",
                user_provider="ollama",
                user_model="fallback-model",
            )
        )

    message = str(excinfo.value)
    assert "Workflow Agents" in message
    assert "Assistant" in message
    # No session may be created when the driver slot cannot be built.
    assert _FakeOrchestrator.instances == []


def test_create_orchestrator_raises_when_reasoner_has_no_model(monkeypatch):
    """A blank Assistant model must fail loudly instead of borrowing a model."""
    monkeypatch.setattr(
        orchestrator_multi, "build_backend", lambda name, **kw: _FakeBackend("x")
    )
    monkeypatch.setattr(
        orchestrator_multi, "_build_user_backend_for_args", lambda *a, **k: None
    )
    monkeypatch.setattr(orchestrator_multi, "Orchestrator", _FakeOrchestrator)

    with pytest.raises(RuntimeError):
        orchestrator_multi._create_orchestrator(_args(reasoner_model=""))

    assert _FakeOrchestrator.instances == []


def test_create_orchestrator_wires_user_agent_slot(monkeypatch):
    user_backend = _FakeBackend("reviewer")
    monkeypatch.setattr(
        orchestrator_multi, "build_backend", lambda name, **kw: _FakeBackend("driver")
    )
    monkeypatch.setattr(
        orchestrator_multi, "_build_user_backend_for_args", lambda *a, **k: user_backend
    )
    monkeypatch.setattr(orchestrator_multi, "Orchestrator", _FakeOrchestrator)

    orchestrator = orchestrator_multi._create_orchestrator(_args())

    assert orchestrator.user_backend is user_backend


# ----------------------------------------------------------------------
# Interactive loop
# ----------------------------------------------------------------------


def _run_loop(monkeypatch, requests: List[Dict[str, Any]]) -> List[str]:
    """Drive ``_run_interactive_loop`` with the given request envelopes."""
    stdin = io.StringIO(
        "".join(json.dumps(req) + "\n" for req in requests)
    )
    stdout = io.StringIO()
    monkeypatch.setattr(sys, "stdin", stdin)
    monkeypatch.setattr(sys, "stdout", stdout)
    orchestrator_multi._run_interactive_loop(_args())
    return [line for line in stdout.getvalue().splitlines() if line.strip()]


def test_interactive_loop_survives_a_failed_session_creation(monkeypatch):
    """A configuration error must not kill the subprocess."""
    created = {"count": 0}

    def fake_create(*a: Any, **k: Any) -> _FakeOrchestrator:
        created["count"] += 1
        if created["count"] == 1:
            raise RuntimeError("No usable model backend.")
        return _FakeOrchestrator(task_mode=k.get("task_mode") or "open")

    monkeypatch.setattr(orchestrator_multi, "_create_orchestrator", fake_create)

    lines = _run_loop(
        monkeypatch,
        [
            {"prompt": "hello", "task_mode": "open"},
            {"prompt": "hello again", "task_mode": "open"},
        ],
    )

    responses = [
        json.loads(line)["response"]
        for line in lines
        if line.startswith("{")
    ]
    assert responses[0].startswith("Error:")
    assert "No usable model backend" in responses[0]
    assert responses[1] == "Done."
    assert created["count"] == 2
    assert lines.count("__RESPONSE_END__") == 2


def test_interactive_loop_seeds_visible_history(monkeypatch):
    fake = _FakeOrchestrator(task_mode="open")
    monkeypatch.setattr(orchestrator_multi, "_create_orchestrator", lambda *a, **k: fake)

    _run_loop(
        monkeypatch,
        [
            {
                "prompt": "continue",
                "task_mode": "open",
                "new_session": True,
                "history": [
                    {"role": "user", "content": "first"},
                    {"role": "assistant", "content": "second"},
                ],
            }
        ],
    )

    assert fake.reset_calls == 1
    assert [m["content"] for m in fake.imported_history] == ["first", "second"]
    assert fake.prompts == ["continue"]


def test_interactive_loop_applies_task_mode_and_thinking_overrides(monkeypatch):
    fake = _FakeOrchestrator(task_mode="open")
    monkeypatch.setattr(orchestrator_multi, "_create_orchestrator", lambda *a, **k: fake)

    _run_loop(
        monkeypatch,
        [
            {
                "prompt": "go",
                "task_mode": "auto_input",
                "thinking": True,
                "effort": "HIGH",
            }
        ],
    )

    assert fake.task_mode is TaskMode.AUTO_INPUT
    assert fake.thinking is True
    assert fake.effort == "high"


def test_interactive_loop_emits_sentinel_for_empty_prompt(monkeypatch):
    monkeypatch.setattr(
        orchestrator_multi,
        "_create_orchestrator",
        lambda *a, **k: _FakeOrchestrator(task_mode="open"),
    )

    lines = _run_loop(monkeypatch, [{"prompt": "", "task_mode": "open"}])

    assert lines[0] == "__READY__"
    assert lines[-1] == "__RESPONSE_END__"
    # The empty prompt still gets exactly one response terminator and no
    # JSON envelope (nothing was asked).
    assert not any(line.startswith("{") for line in lines)