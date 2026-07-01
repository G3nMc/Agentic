"""Task-flow protocol shared by single-agent and multi-agent orchestrators.

The protocol is purely text-based and provider-agnostic: the model emits
three kinds of tags inside its reply, the orchestrator extracts them
and rewrites them as structured JSON envelopes on stdout (between
``{"response": ...}`` and ``__RESPONSE_END__``) so the Flutter client
can intercept them without parsing prose.

Tags
----
``<tasks>[{...}, ...]</tasks>``
    Emitted ONCE at the start of a multi-step request. Each entry is a
    JSON object with fields ``id`` (int), ``name`` (str), ``description``
    (str), optional ``success_criteria`` (str), optional ``depends_on``
    (list[int]).

``<task_status>{"id": N, "status": "..."}</task_status>``
    Emitted by the model after every task or partial step. ``status``
    is one of :class:`TaskStatus` values.

``<task_action>{"id": N, "action": "..."}</task_action>``
    Emitted by the *client* (e.g. the Flutter UI's Proceed button)
    addressed to the orchestrator. Carries a :class:`TaskAction` value.
    Sent inline as the next user prompt so the existing send/response
    cycle does not need a new channel.

Modes (selected from the UI dropdown)
-------------------------------------
``open``                 -- task protocol is OFF; replies are free-form.
``task_compliance``      -- task protocol is ON; orchestrator pauses
                            after each task and waits for an explicit
                            ``<task_action>`` from the client.
``task_compliance_auto`` -- task protocol is ON; auto-proceed.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass, field, asdict
from enum import Enum
from typing import Any, Dict, List, Optional


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------


class TaskMode(str, Enum):
    OPEN = "open"
    COMPLIANCE = "task_compliance"
    COMPLIANCE_AUTO = "task_compliance_auto"

    @classmethod
    def parse(cls, raw: Any) -> "TaskMode":
        """Normalise external input to a valid mode. Falls back to OPEN."""
        if isinstance(raw, cls):
            return raw
        s = str(raw or "").strip().lower()
        for m in cls:
            if m.value == s:
                return m
        return cls.OPEN

    @property
    def is_task_flow(self) -> bool:
        return self is not TaskMode.OPEN


class TaskStatus(str, Enum):
    PENDING = "pending"
    IN_PROGRESS = "in_progress"
    DONE = "done"
    PARTIAL = "partial"
    BLOCKED = "blocked"
    FAILED = "failed"
    SKIPPED = "skipped"

    @classmethod
    def parse(cls, raw: Any) -> "TaskStatus":
        s = str(raw or "").strip().lower()
        for m in cls:
            if m.value == s:
                return m
        return cls.PENDING


class TaskAction(str, Enum):
    PROCEED = "proceed"
    RETRY = "retry"
    SKIP = "skip"
    ABORT = "abort"
    REPLAN = "replan"

    @classmethod
    def parse(cls, raw: Any) -> Optional["TaskAction"]:
        s = str(raw or "").strip().lower()
        for m in cls:
            if m.value == s:
                return m
        return None


# ---------------------------------------------------------------------------
# Dataclasses
# ---------------------------------------------------------------------------


@dataclass
class Task:
    """One unit of work in a planned task list."""

    id: int
    name: str
    description: str = ""
    success_criteria: str = ""
    depends_on: List[int] = field(default_factory=list)
    status: TaskStatus = TaskStatus.PENDING

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["status"] = self.status.value
        return d


@dataclass
class TaskStatusEvent:
    id: int
    status: TaskStatus
    note: str = ""
    description: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "status": self.status.value,
            "note": self.note,
            "description": self.description,
        }


@dataclass
class TaskActionEvent:
    id: int
    action: TaskAction

    def to_dict(self) -> Dict[str, Any]:
        return {"id": self.id, "action": self.action.value}


# ---------------------------------------------------------------------------
# Regex parsers
# ---------------------------------------------------------------------------


# Tolerant: accepts <tasks>...</tasks> with arbitrary whitespace inside.
_TASKS_TAG_RE = re.compile(
    r"<\s*tasks\s*>(?P<body>.*?)<\s*/\s*tasks\s*>",
    re.DOTALL | re.IGNORECASE,
)

_TASK_STATUS_TAG_RE = re.compile(
    r"<\s*task_status\s*>(?P<body>.*?)<\s*/\s*task_status\s*>",
    re.DOTALL | re.IGNORECASE,
)

_TASK_ACTION_TAG_RE = re.compile(
    r"<\s*task_action\s*>(?P<body>.*?)<\s*/\s*task_action\s*>",
    re.DOTALL | re.IGNORECASE,
)


def _parse_json_body(body: str) -> Optional[Any]:
    """Best-effort JSON parse. Returns None on failure (no exception)."""
    if not body:
        return None
    try:
        return json.loads(body)
    except (ValueError, json.JSONDecodeError):
        return None


def parse_tasks(text: str) -> List[Task]:
    """Return every well-formed task in a ``<tasks>...</tasks>`` block.

    Multiple blocks in the same reply are merged. A block whose JSON is
    malformed is silently skipped (the orchestrator just won't see those
    tasks and the model will be nudged to re-emit on the next turn).
    """
    out: List[Task] = []
    if not text:
        return out
    for m in _TASKS_TAG_RE.finditer(text):
        body = (m.group("body") or "").strip()
        if not body:
            continue
        parsed = _parse_json_body(body)
        if not isinstance(parsed, list):
            continue
        for entry in parsed:
            if not isinstance(entry, dict):
                continue
            try:
                tid = int(entry.get("id"))
            except (TypeError, ValueError):
                continue
            name = str(entry.get("name") or "").strip()
            if not name:
                continue
            depends_raw = entry.get("depends_on") or []
            depends_on: List[int] = []
            if isinstance(depends_raw, list):
                for d in depends_raw:
                    try:
                        depends_on.append(int(d))
                    except (TypeError, ValueError):
                        continue
            out.append(
                Task(
                    id=tid,
                    name=name,
                    description=str(entry.get("description") or "").strip(),
                    success_criteria=str(entry.get("success_criteria") or "").strip(),
                    depends_on=depends_on,
                    status=TaskStatus.parse(entry.get("status")),
                )
            )
    return out


def parse_task_status(text: str) -> List[TaskStatusEvent]:
    """Return every ``<task_status>{...}</task_status>`` event in ``text``."""
    out: List[TaskStatusEvent] = []
    if not text:
        return out
    for m in _TASK_STATUS_TAG_RE.finditer(text):
        body = (m.group("body") or "").strip()
        parsed = _parse_json_body(body)
        if not isinstance(parsed, dict):
            continue
        try:
            tid = int(parsed.get("id"))
        except (TypeError, ValueError):
            continue
        out.append(
            TaskStatusEvent(
                id=tid,
                status=TaskStatus.parse(parsed.get("status")),
                note=str(parsed.get("note") or "").strip(),
                description=str(parsed.get("description") or "").strip(),
            )
        )
    return out


def parse_task_action(text: str) -> Optional[TaskActionEvent]:
    """Return the FIRST ``<task_action>{...}</task_action>`` event found.

    Used to interpret the next user prompt when the UI sends a Proceed /
    Retry / Abort / Replan / Skip command in compliance (non-auto) mode.
    """
    if not text:
        return None
    m = _TASK_ACTION_TAG_RE.search(text)
    if not m:
        return None
    body = (m.group("body") or "").strip()
    parsed = _parse_json_body(body)
    if not isinstance(parsed, dict):
        return None
    try:
        tid = int(parsed.get("id"))
    except (TypeError, ValueError):
        return None
    action = TaskAction.parse(parsed.get("action"))
    if action is None:
        return None
    return TaskActionEvent(id=tid, action=action)


# ---------------------------------------------------------------------------
# Tag stripping (after extraction, the visible reply must be clean)
# ---------------------------------------------------------------------------


def strip_task_tags(text: str) -> str:
    """Remove any task-protocol tag from ``text``.

    The orchestrator re-emits the same information as structured JSON
    envelopes on stdout, so the model-visible reply (and what the user
    eventually sees in the chat bubble) should not carry the raw tags.
    """
    if not text:
        return text
    cleaned = _TASKS_TAG_RE.sub("", text)
    cleaned = _TASK_STATUS_TAG_RE.sub("", cleaned)
    cleaned = _TASK_ACTION_TAG_RE.sub("", cleaned)
    return re.sub(r"\n{3,}", "\n\n", cleaned).strip()


# ---------------------------------------------------------------------------
# JSON envelope emitter
# ---------------------------------------------------------------------------


def _log(msg: str) -> None:
    """Human-readable line on stderr so the Flutter log panel reflects
    task-flow progress alongside the existing ``[orch]`` lines.
    """
    print(msg, file=sys.stderr, flush=True)


_MAX_ENVELOPE_LOG = 1200


def emit_event(event: str, payload: Dict[str, Any], stream=None) -> None:
    """Print a single ``{"event": "...", ...}`` JSON line on stdout.

    The Flutter ``OrchestratorManager._onStdoutLine`` recognises these
    envelopes by the presence of the ``event`` key and routes them to
    the task stream (instead of treating them as the final response
    envelope, which carries ``response`` instead).

    The same payload is also mirrored on stderr (prefixed with
    ``[task-envelope]``) so the Flutter orchestrator log panel shows
    the raw JSON that flowed to the UI. Over-long payloads
    (``tasks_proposed`` with many entries) are truncated so a single
    envelope cannot blow out the log buffer.
    """
    out = {"event": event, **payload}
    serialized = json.dumps(out, ensure_ascii=False)
    target = stream if stream is not None else sys.stdout
    target.write(serialized + "\n")
    target.flush()
    log_payload = serialized
    if len(log_payload) > _MAX_ENVELOPE_LOG:
        log_payload = log_payload[:_MAX_ENVELOPE_LOG] + "...(truncated)"
    _log(f"[task-envelope] {log_payload}")


def emit_tasks_proposed(tasks: List[Task], stream=None) -> None:
    emit_event(
        "tasks_proposed",
        {"tasks": [t.to_dict() for t in tasks]},
        stream=stream,
    )
    _log(f"[task] proposed plan with {len(tasks)} task(s)")
    for t in tasks:
        _log(f"[task]   #{t.id} {t.name}")


def emit_task_status(event: TaskStatusEvent, stream=None) -> None:
    emit_event("task_status", event.to_dict(), stream=stream)
    note = f": {event.note}" if event.note else ""
    _log(f"[task] #{event.id} -> {event.status.value}{note}")


def log_task_action_received(event: TaskActionEvent) -> None:
    """Called by the orchestrator when an incoming user prompt is
    recognised as a ``<task_action>`` directive (Proceed / Retry /
    Skip / Abort / Replan from the Flutter UI). Single stderr line so
    the log panel reflects the manual-mode control loop.
    """
    _log(f"[task-action] received #{event.id} {event.action.value}")


__all__ = [
    "TaskMode",
    "TaskStatus",
    "TaskAction",
    "Task",
    "TaskStatusEvent",
    "TaskActionEvent",
    "parse_tasks",
    "parse_task_status",
    "parse_task_action",
    "strip_task_tags",
    "emit_event",
    "emit_tasks_proposed",
    "emit_task_status",
    "log_task_action_received",
]
