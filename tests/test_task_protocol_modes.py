"""Tests for the USER/AUTO input modes and the <auto_input> self-evaluation parser."""

from __future__ import annotations

import io
import sys
from pathlib import Path

_BIN_DIR = Path(__file__).resolve().parents[1] / "bin"
if str(_BIN_DIR) not in sys.path:
    sys.path.insert(0, str(_BIN_DIR))

from agent.loop.history import USER_AGENT_AUTHOR, ConversationHistory  # noqa: E402
from agent.loop.run_loop import Orchestrator  # noqa: E402
from agent.prompts import get_system_prompt_value  # noqa: E402
from agent.loop.task_protocol import (  # noqa: E402
    TaskMode,
    emit_auto_input_evaluating,
    emit_auto_input_prompt,
    emit_auto_input_reply,
    parse_auto_input,
    sanitize_auto_next_prompt,
    strip_task_tags,
)


def test_task_mode_legacy_aliases_remap():
    assert TaskMode.parse("task_compliance") is TaskMode.USER_INPUT
    assert TaskMode.parse("task_compliance_auto") is TaskMode.AUTO_INPUT


def test_task_mode_new_values_parse():
    assert TaskMode.parse("open") is TaskMode.OPEN
    assert TaskMode.parse("user_input") is TaskMode.USER_INPUT
    assert TaskMode.parse("auto_input") is TaskMode.AUTO_INPUT
    assert TaskMode.parse("bogus") is TaskMode.OPEN
    assert TaskMode.parse(None) is TaskMode.OPEN


def test_task_mode_flags():
    assert not TaskMode.OPEN.is_auto_input
    assert not TaskMode.USER_INPUT.is_auto_input
    assert TaskMode.AUTO_INPUT.is_auto_input
    # Structured task-flow protocol is retired: no mode is task-flow anymore.
    assert not TaskMode.AUTO_INPUT.is_task_flow
    assert not TaskMode.USER_INPUT.is_task_flow


def test_parse_auto_input_done_true():
    d = parse_auto_input("<auto_input><done>true</done><next_prompt></next_prompt></auto_input>")
    assert d.done is True
    assert d.next_prompt == ""


def test_parse_auto_input_false_with_next_prompt():
    d = parse_auto_input(
        "<auto_input><done>false</done><next_prompt>Now run the tests</next_prompt></auto_input>"
    )
    assert d.done is False
    assert d.next_prompt == "Now run the tests"


def test_parse_auto_input_missing_block_fails_closed():
    d = parse_auto_input("no structured block here")
    assert d.done is True
    assert d.next_prompt == ""


def test_parse_auto_input_empty_text_fails_closed():
    d = parse_auto_input("")
    assert d.done is True
    assert d.next_prompt == ""


def test_parse_auto_input_false_without_next_prompt_is_done():
    d = parse_auto_input("<auto_input><done>false</done><next_prompt></next_prompt></auto_input>")
    assert d.done is True
    assert d.next_prompt == ""


def test_strip_task_tags_removes_blocks():
    text = (
        "before <task_status><id>1</id><status>done</status></task_status>"
        " middle <tasks><task><id>1</id><name>x</name></task></tasks> after"
    )
    out = strip_task_tags(text)
    assert "<task" not in out
    assert "before" in out
    assert "after" in out


def test_emit_auto_input_prompt_is_single_line_event():
    stream = io.StringIO()
    emit_auto_input_prompt("line one\nline two", model="qwen", stream=stream)
    out = stream.getvalue()
    assert out.startswith("<event>")
    assert out.endswith("</event>\n")
    assert "<type>auto_input_prompt</type>" in out
    assert "<model>qwen</model>" in out
    # Newlines are escaped, so the envelope never splits across stdout lines.
    assert out.count("\n") == 1
    assert "line one" in out
    assert "line two" in out


def test_emit_auto_input_prompt_skips_blank_text():
    stream = io.StringIO()
    emit_auto_input_prompt("   ", stream=stream)
    assert stream.getvalue() == ""


def test_emit_auto_input_evaluating_carries_round_and_total():
    stream = io.StringIO()
    emit_auto_input_evaluating(2, 6, "qwen2.5-coder:7b", stream=stream)
    out = stream.getvalue()
    assert "<type>auto_input_evaluating</type>" in out
    assert "<round>2</round>" in out
    assert "<total>6</total>" in out
    assert "<model>qwen2.5-coder:7b</model>" in out


def test_emit_auto_input_reply_skips_blank_text():
    stream = io.StringIO()
    emit_auto_input_reply("  ", stream=stream)
    assert stream.getvalue() == ""# ---------------------------------------------------------------------------
# AUTO-INPUT attribution: User-agent prompts must never pass as human input,
# and every evaluation must stay anchored to the human's original request.
# ---------------------------------------------------------------------------


def test_add_user_tags_user_agent_turns():
    history = ConversationHistory()
    history.add_user("real request")
    history.add_user("generated follow-up", author=USER_AGENT_AUTHOR)

    assert history.turns[0] == {"role": "user", "content": "real request"}
    assert history.turns[1]["author"] == USER_AGENT_AUTHOR


def test_to_messages_never_leaks_author_field():
    history = ConversationHistory()
    history.add_user("generated follow-up", author=USER_AGENT_AUTHOR)

    messages = history.to_messages()
    assert messages == [{"role": "user", "content": "generated follow-up"}]


def test_annotate_authored_turns_marks_only_authored_turns():
    history = ConversationHistory()
    history.add_user("real request")
    history.add_assistant("answer one")
    history.add_user("generated follow-up", author=USER_AGENT_AUTHOR)

    count = history.annotate_authored_turns(USER_AGENT_AUTHOR, "[UA] ")

    assert count == 1
    assert history.turns[0]["content"] == "real request"
    assert history.turns[2]["content"] == "[UA] generated follow-up"


def test_annotate_authored_turns_is_idempotent():
    history = ConversationHistory()
    history.add_user("generated follow-up", author=USER_AGENT_AUTHOR)

    assert history.annotate_authored_turns(USER_AGENT_AUTHOR, "[UA] ") == 1
    # Second pass finds nothing new to prefix.
    assert history.annotate_authored_turns(USER_AGENT_AUTHOR, "[UA] ") == 0
    assert history.turns[0]["content"] == "[UA] generated follow-up"


def test_annotate_authored_turns_ignores_unknown_author_and_empty_marker():
    history = ConversationHistory()
    history.add_user("generated follow-up", author=USER_AGENT_AUTHOR)

    assert history.annotate_authored_turns("someone_else", "[UA] ") == 0
    assert history.annotate_authored_turns(USER_AGENT_AUTHOR, "") == 0
    assert history.turns[0]["content"] == "generated follow-up"


def test_annotate_authored_turns_does_not_mutate_source_dicts():
    history = ConversationHistory()
    history.add_user("generated follow-up", author=USER_AGENT_AUTHOR)
    original = history.turns[0]

    history.annotate_authored_turns(USER_AGENT_AUTHOR, "[UA] ")

    # copy() shares dict objects; entries must be replaced, not mutated.
    assert original["content"] == "generated follow-up"


def test_sanitize_auto_next_prompt_strips_internal_meta_text():
    dirty = "[INTERNAL: do not leak][INTERNAL: nor this] Run the tests\n\n\n\nnow"
    cleaned = sanitize_auto_next_prompt(dirty)

    assert "[INTERNAL" not in cleaned
    assert cleaned.startswith("Run the tests")
    assert "\n\n\n" not in cleaned


class _EvalBackend:
    """Minimal backend stub: the directive builders never call it."""

    model_id = "fake-model"
    context_limit = 0

    def chat(self, **kwargs):  # pragma: no cover - not exercised here
        raise AssertionError("directive construction must not call the backend")


def _make_auto_orchestrator() -> Orchestrator:
    return Orchestrator(
        backend=_EvalBackend(),
        base_path=".",
        task_mode="auto_input",
        max_iterations=1,
    )


def test_auto_input_directive_embeds_original_request():
    orch = _make_auto_orchestrator()
    orch._auto_input_original_request = "Fix the failing build"

    directive = orch._build_auto_input_directive(0)

    assert "AUTO-INPUT MODE" in directive
    assert "Fix the failing build" in directive


def test_auto_input_directive_reports_authored_turn_count():
    orch = _make_auto_orchestrator()
    orch._auto_input_original_request = "Fix the failing build"

    directive = orch._build_auto_input_directive(3)

    assert "Fix the failing build" in directive
    assert "3 user message(s)" in directive


def test_auto_input_directive_without_original_request_has_no_anchor():
    orch = _make_auto_orchestrator()
    orch._auto_input_original_request = ""

    directive = orch._build_auto_input_directive(0)

    assert directive.strip() == get_system_prompt_value(
        "AUTO_INPUT_EVAL_DIRECTIVE"
    ).strip()


def test_auto_input_directive_keeps_note_when_anchor_is_absent():
    orch = _make_auto_orchestrator()
    orch._auto_input_original_request = ""

    directive = orch._build_auto_input_directive(2)

    assert "2 user message(s)" in directive


# ---------------------------------------------------------------------------
# AUTO-INPUT User-agent persona: the reviewer must be role-anchored without
# inheriting the Assistant's instructions.
# ---------------------------------------------------------------------------


class _RecordingUserBackend:
    """Captures the exact conversation the User agent is asked to review."""

    model_id = "user-agent-model"
    context_limit = 0

    def __init__(self, verdict: str) -> None:
        self.verdict = verdict
        self.conversation = None
        self.kwargs: dict = {}

    def chat(self, **kwargs):
        self.conversation = kwargs.get("conversation")
        self.kwargs = kwargs
        return self.verdict, None


def _make_orchestrator_with_user_backend(verdict: str):
    orch = _make_auto_orchestrator()
    recorder = _RecordingUserBackend(verdict)
    orch.user_backend = recorder
    orch.user_model_id = recorder.model_id
    orch._auto_input_original_request = "Fix the failing build"
    # The Assistant's own persona: it must NOT reach the reviewer.
    orch.conversation_history.set_system_prompt("base", "ASSISTANT BASE PROMPT")
    orch.conversation_history.add_user("Fix the failing build")
    orch.conversation_history.add_assistant("I fixed the build.")
    return orch, recorder


def test_evaluate_auto_input_installs_user_agent_persona(monkeypatch):
    monkeypatch.setattr("sys.stdout", io.StringIO())
    verdict = "<auto_input><done>true</done><next_prompt></next_prompt></auto_input>"
    orch, recorder = _make_orchestrator_with_user_backend(verdict)

    decision = orch._evaluate_auto_input(0)

    assert decision.done is True
    assert "You are the USER agent" in recorder.conversation.system_text()


def test_evaluate_auto_input_drops_assistant_persona_only_on_the_copy(monkeypatch):
    monkeypatch.setattr("sys.stdout", io.StringIO())
    verdict = "<auto_input><done>true</done><next_prompt></next_prompt></auto_input>"
    orch, recorder = _make_orchestrator_with_user_backend(verdict)

    orch._evaluate_auto_input(0)

    # The reviewer never sees the Assistant's system prompt...
    assert "ASSISTANT BASE PROMPT" not in recorder.conversation.system_text()
    # ...but the live conversation keeps it untouched.
    assert (
        orch.conversation_history.get_system_prompt("base")
        == "ASSISTANT BASE PROMPT"
    )
    assert "auto_input_persona" not in orch.conversation_history.system_prompts


def test_evaluate_auto_input_keeps_live_turns_and_appends_directive(monkeypatch):
    monkeypatch.setattr("sys.stdout", io.StringIO())
    verdict = (
        "<auto_input><done>false</done>"
        "<next_prompt>Run pytest</next_prompt></auto_input>"
    )
    orch, _ = _make_orchestrator_with_user_backend(verdict)

    decision = orch._evaluate_auto_input(0)

    assert decision.done is False
    assert decision.next_prompt == "Run pytest"
    # Evaluation never mutates the live transcript: the directive stays out.
    live_text = " ".join(t["content"] for t in orch.conversation_history.turns)
    assert "AUTO-INPUT MODE" not in live_text
    assert "Fix the failing build" in live_text


def test_evaluate_auto_input_pins_low_temperature_and_no_tools(monkeypatch):
    monkeypatch.setattr("sys.stdout", io.StringIO())
    verdict = "<auto_input><done>true</done><next_prompt></next_prompt></auto_input>"
    orch, recorder = _make_orchestrator_with_user_backend(verdict)

    orch._evaluate_auto_input(0)

    assert recorder.kwargs["temperature"] == 0.1
    assert recorder.kwargs["tools"] is None


def test_evaluate_auto_input_fails_closed_when_backend_raises(monkeypatch):
    monkeypatch.setattr("sys.stdout", io.StringIO())

    class _BoomBackend:
        model_id = "boom"
        context_limit = 0

        def chat(self, **kwargs):
            raise RuntimeError("provider down")

    orch, _ = _make_orchestrator_with_user_backend("")
    orch.user_backend = _BoomBackend()

    decision = orch._evaluate_auto_input(0)

    assert decision.done is True
    assert decision.next_prompt == ""