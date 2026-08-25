"""Task-flow protocol shared by single-agent and multi-agent orchestrators.

The protocol is purely text-based and provider-agnostic: the model emits
three kinds of XML tags inside its reply, the orchestrator extracts them
and rewrites them as structured XML envelopes on stdout (between
the final response envelope and ``__RESPONSE_END__``) so the Flutter client
can intercept them without parsing prose.

FORMAT — pure XML child tags, NO attributes, NO JSON.
Same convention as the tool-calling protocol (<tool><name>...</name>...</tool>).
The tag body IS the value — no JSON escaping, no attribute parsing.

Tags
----
``<tasks>`` containing one or more ``<task>`` children:
    Emitted ONCE at the start of a multi-step request.

    <tasks>
      <task>
        <id>1</id>
        <name>short title</name>
        <description>what to do</description>
        <success_criteria>how you know it is done</success_criteria>
        <depends_on>2</depends_on>
      </task>
    </tasks>

    ``depends_on`` is optional and may be repeated or comma-separated
    (e.g. ``<depends_on>1,3</depends_on>`` or two separate tags).

``<task_status>``
    Emitted by the model after every task or partial step.

    <task_status>
      <id>1</id>
      <status>in_progress</status>
      <note>short summary</note>
    </task_status>

    ``status`` is one of :class:`TaskStatus` values.
    ``note`` is optional.

``<task_action>``
    Emitted by the *client* (e.g. the Flutter UI's Proceed button)
    addressed to the orchestrator. Carries a :class:`TaskAction` value.

    <task_action>
      <id>1</id>
      <action>proceed</action>
    </task_action>

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

import re
import sys
from dataclasses import dataclass, field, asdict
from enum import Enum
from typing import Any, List, Optional


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
# XML child-tag parsers (no attributes, no JSON — same convention as
# tool_dispatch.py's _parse_xml_tool_call)
# ---------------------------------------------------------------------------

# Outer block regexes — match <tag>...</tag> with tolerant whitespace.
_TASKS_BLOCK_RE = re.compile(
    r"<\s*tasks\s*>(?P<body>.*?)<\s*/\s*tasks\s*>",
    re.DOTALL | re.IGNORECASE,
)

_TASK_BLOCK_RE = re.compile(
    r"<\s*task\s*>(?P<body>.*?)<\s*/\s*task\s*>",
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

# Match any child tag: <tagname>value</tagname>
# Same pattern as tool_dispatch.py's _XML_CHILD_TAG_RE.
_XML_CHILD_TAG_RE = re.compile(
    r"<(\w+)\s*>(.*?)</\1\s*>",
    re.DOTALL | re.IGNORECASE,
)


def _extract_child_tags(body: str) -> Dict[str, str]:
    """Extract all child tags from *body* as a {tagname: value} dict.

    If the same tag appears multiple times (e.g. multiple <depends_on>),
    only the last occurrence is kept.  For list-valued fields the caller
    should use :func:`_extract_child_tags_multi` instead.
    """
    out: Dict[str, str] = {}
    if not body:
        return out
    for m in _XML_CHILD_TAG_RE.finditer(body):
        tag_name = m.group(1).lower()
        out[tag_name] = m.group(2)
    return out


def _extract_child_tags_multi(body: str) -> Dict[str, List[str]]:
    """Like :func:`_extract_child_tags` but collects repeated tags into lists."""
    out: Dict[str, List[str]] = {}
    if not body:
        return out
    for m in _XML_CHILD_TAG_RE.finditer(body):
        tag_name = m.group(1).lower()
        out.setdefault(tag_name, []).append(m.group(2))
    return out


def _parse_int(value: Optional[str]) -> Optional[int]:
    """Best-effort int parse. Returns None on failure."""
    if value is None:
        return None
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def _parse_int_list(values: List[str]) -> List[int]:
    """Parse a list of strings into ints, tolerating comma-separated values.

    Handles both:
      <depends_on>1</depends_on><depends_on>2</depends_on>
      <depends_on>1,2</depends_on>
    """
    out: List[int] = []
    for v in values:
        if not v:
            continue
        for part in v.split(","):
            part = part.strip()
            if not part:
                continue
            try:
                out.append(int(part))
            except (TypeError, ValueError):
                continue
    return out


def parse_tasks(text: str) -> List[Task]:
    """Return every well-formed task in a ``<tasks>...</tasks>`` block.

    Multiple <tasks> blocks in the same reply are merged.
    Each block must contain one or more <task> children with child tags
    for the task fields.  A malformed block is silently skipped (the
    orchestrator just won't see those tasks and the model will be
    nudged to re-emit on the next turn).

    Expected format::

        <tasks>
          <task>
            <id>1</id>
            <name>short title</name>
            <description>what to do</description>
            <success_criteria>done when...</success_criteria>
            <depends_on>2</depends_on>
          </task>
        </tasks>
    """
    out: List[Task] = []
    if not text:
        return out
    for m in _TASKS_BLOCK_RE.finditer(text):
        block_body = m.group("body") or ""
        if not block_body.strip():
            continue
        for tm in _TASK_BLOCK_RE.finditer(block_body):
            task_body = tm.group("body") or ""
            if not task_body.strip():
                continue
            # Use multi-extraction for depends_on (may be repeated or comma-separated).
            multi = _extract_child_tags_multi(task_body)
            # Use single-extraction for scalar fields.
            single = _extract_child_tags(task_body)

            tid = _parse_int(single.get("id"))
            if tid is None:
                continue
            name = (single.get("name") or "").strip()
            if not name:
                continue

            depends_on = _parse_int_list(multi.get("depends_on", []))

            status_str = (single.get("status") or "").strip()

            out.append(
                Task(
                    id=tid,
                    name=name,
                    description=(single.get("description") or "").strip(),
                    success_criteria=(single.get("success_criteria") or "").strip(),
                    depends_on=depends_on,
                    status=TaskStatus.parse(status_str),
                )
            )
    return out


def parse_task_status(text: str) -> List[TaskStatusEvent]:
    """Return every ``<task_status>...</task_status>`` event in *text*.

    Expected format::

        <task_status>
          <id>1</id>
          <status>in_progress</status>
          <note>short summary</note>
        </task_status>
    """
    out: List[TaskStatusEvent] = []
    if not text:
        return out
    for m in _TASK_STATUS_TAG_RE.finditer(text):
        body = m.group("body") or ""
        if not body.strip():
            continue
        tags = _extract_child_tags(body)
        tid = _parse_int(tags.get("id"))
        if tid is None:
            continue
        out.append(
            TaskStatusEvent(
                id=tid,
                status=TaskStatus.parse(tags.get("status")),
                note=(tags.get("note") or "").strip(),
                description=(tags.get("description") or "").strip(),
            )
        )
    return out


def parse_task_action(text: str) -> Optional[TaskActionEvent]:
    """Return the FIRST ``<task_action>...</task_action>`` event found.

    Used to interpret the next user prompt when the UI sends a Proceed /
    Retry / Abort / Replan / Skip command in compliance (non-auto) mode.

    Expected format::

        <task_action>
          <id>1</id>
          <action>proceed</action>
        </task_action>
    """
    if not text:
        return None
    m = _TASK_ACTION_TAG_RE.search(text)
    if not m:
        return None
    body = m.group("body") or ""
    if not body.strip():
        return None
    tags = _extract_child_tags(body)
    tid = _parse_int(tags.get("id"))
    if tid is None:
        return None
    action = TaskAction.parse(tags.get("action"))
    if action is None:
        return None
    return TaskActionEvent(id=tid, action=action)


# ---------------------------------------------------------------------------
# Tag stripping (after extraction, the visible reply must be clean)
# ---------------------------------------------------------------------------


def strip_task_tags(text: str) -> str:
    """Remove any task-protocol tag from *text*.

    The orchestrator re-emits the same information as structured JSON
    envelopes on stdout, so the model-visible reply (and what the user
    eventually sees in the chat bubble) should not carry the raw tags.

    Strips: <tasks>...</tasks>, <task>...</task>, <task_status>...</task_status>,
    <task_action>...</task_action>.
    """
    if not text:
        return text
    cleaned = _TASKS_BLOCK_RE.sub("", text)
    cleaned = _TASK_STATUS_TAG_RE.sub("", cleaned)
    cleaned = _TASK_ACTION_TAG_RE.sub("", cleaned)
    # Also strip any orphan <task>...</task> blocks that might remain
    # after the <tasks> wrapper was removed.
    cleaned = _TASK_BLOCK_RE.sub("", cleaned)
    return re.sub(r"\n{3,}", "\n\n", cleaned).strip()


# ---------------------------------------------------------------------------
# XML envelope emitter (stdout → Flutter UI)
# ---------------------------------------------------------------------------
# NOTE: These emit XML on stdout for the Flutter client, using the same
# child-tag convention as the model-facing protocol.  This is INTERNAL
# orchestrator→UI communication; the model never sees or produces these
# envelopes.


def _log(msg: str) -> None:
    """Human-readable line on stderr so the Flutter log panel reflects
    task-flow progress alongside the existing ``[orch]`` lines.
    """
    print(msg, file=sys.stderr, flush=True)


_MAX_ENVELOPE_LOG = 1200


def _escape_xml(value: Any) -> str:
    """Escape a string for use as XML text content.

    Also escapes newlines (\\n, \\r) as XML character references so the
    entire envelope stays on a single line.  The Flutter side reads
    stdout line-by-line via ``LineSplitter``; a literal newline inside
    an ``<event>`` envelope would split it across multiple lines and
    cause ``_tryParseTaskEvent`` to miss the event entirely.
    """
    s = str(value)
    s = s.replace("&", "&amp;")
    s = s.replace("<", "&lt;")
    s = s.replace(">", "&gt;")
    # Quotes are not required to be escaped in text content, but do it
    # anyway for symmetry and safety if a value later ends up in an attribute.
    s = s.replace('"', "&quot;")
    # Newlines MUST be escaped so the XML envelope stays on one line.
    # Order matters: escape \r before \n so \r\n becomes &#13;&#10;.
    s = s.replace("\r", "&#13;")
    s = s.replace("\n", "&#10;")
    return s


def _child(tag: str, value: Any) -> str:
    """Render ``<tag>value</tag>`` with XML-escaped text."""
    return f"<{tag}>{_escape_xml(value)}</{tag}>"


def _task_to_xml(task: Task) -> str:
    """Render a Task as XML child tags (single-line, no extra whitespace)."""
    lines = [
        _child("id", task.id),
        _child("name", task.name),
        _child("description", task.description),
        _child("success_criteria", task.success_criteria),
        _child("depends_on", ",".join(str(d) for d in task.depends_on)),
        _child("status", task.status.value),
    ]
    return "<task>" + "".join(lines) + "</task>"


def emit_tasks_proposed(tasks: List[Task], stream=None) -> None:
    task_xml = "".join(_task_to_xml(t) for t in tasks)
    out = f"<event>{_child('type', 'tasks_proposed')}<tasks>{task_xml}</tasks></event>"
    target = stream if stream is not None else sys.stdout
    target.write(out + "\n")
    target.flush()
    _log(f"[task] proposed plan with {len(tasks)} task(s)")
    for t in tasks:
        _log(f"[task]   #{t.id} {t.name}")


def emit_task_status(event: TaskStatusEvent, stream=None) -> None:
    body = "".join(
        line
        for line in [
            _child("type", "task_status"),
            _child("id", event.id),
            _child("status", event.status.value),
            _child("note", event.note),
            _child("description", event.description),
        ]
    )
    out = f"<event>{body}</event>"
    target = stream if stream is not None else sys.stdout
    target.write(out + "\n")
    target.flush()
    note = f": {event.note}" if event.note else ""
    _log(f"[task] #{event.id} -> {event.status.value}{note}")


# Backwards-compatible alias kept for callers that imported the old name.
emit_event = emit_task_status


def log_task_action_received(event: TaskActionEvent) -> None:
    """Called by the orchestrator when an incoming user prompt is
    recognised as a ``<task_action>`` directive (Proceed / Retry /
    Skip / Abort / Replan from the Flutter UI). Single stderr line so
    the log panel reflects the manual-mode control loop.
    """
    _log(f"[task-action] received #{event.id} {event.action.value}")


def emit_thinking(text: str, stream=None) -> None:
    """Emit the model's chain-of-thought as a structured XML envelope.

    The Flutter client intercepts ``<event type="thinking">`` lines on
    stdout and surfaces the reasoning in the chat view's activity strip,
    so the user can watch the model think in real time. The text is
    XML-escaped (including newlines) so the envelope stays on one line.

    Ollama/deepseek models emit ``:``-only chunks between reasoning phases
    and prefix their reasoning with a lone colon. Drop pure-noise chunks and
    strip the leading colon so the UI keeps showing the last real thinking
    instead of a bare ``:``.
    """
    if not text:
        return
    cleaned = text.strip()
    if not cleaned or cleaned == ":":
        return
    if cleaned.startswith(":"):
        cleaned = cleaned[1:].strip()
    if not cleaned:
        return
    out = f"<event>{_child('type', 'thinking')}{_child('text', cleaned)}</event>"
    target = stream if stream is not None else sys.stdout
    target.write(out + "\n")
    target.flush()


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
    "emit_thinking",
    "log_task_action_received",
]
