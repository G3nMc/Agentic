"""``team_board.md`` — single shared board for a Team Mode session.

File shape (rendered):

    # TEAM BOARD
    session_id: ...
    leader_model: ...
    created_at: ...
    updated_at: ...

    ## Status
    | # | Group | Owner Model | Status | Artifact | Last Step |
    |---|-------|-------------|--------|----------|-----------|
    | 1 | a     | sonnet-4-6  | ...    | ...      | ...       |

    ## Plan
    1. a → ...

    ## Dependencies
    b ← a

    ────────────────────────────────────────────────────────────────────────
    ## <SECTION:a>
    status: DONE_CLEAN
    started_at: ...
    finished_at: ...
    last_completed_step: 5/5

    ### Plan
    - [x] 1. ...

    ### Log
    - 14:39 ...

Reading rules:
  - Workers read ONLY the status table + their own ``## <SECTION:NAME>``.
  - Leader reads the whole header (status table, plan, dependencies)
    and may read any section to compact it; never reads worker
    transcripts or tool outputs.
"""

from __future__ import annotations

import os
import re
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from .status import Status

# ----------------------------------------------------------------------
# Circuit-breaker thresholds
# ----------------------------------------------------------------------
# Soft: a worker self-summarizes its OWN section when it crosses these.
SECTION_SOFT_LINES = 150
SECTION_SOFT_TOKENS = 2000

# Hard: the host forces a leader compaction turn before launching the
# next worker if the WHOLE board crosses these.
BOARD_HARD_LINES = 600
BOARD_HARD_TOKENS = 6000


# Approximation: 1 token ≈ 4 chars. Good enough for circuit breakers;
# nobody is billed by these counts.
def _est_tokens(text: str) -> int:
    return max(1, len(text) // 4)


_DIVIDER = "─" * 72
_SECTION_RE = re.compile(r"^## <SECTION:([\w_-]+)>\s*$", re.MULTILINE)


def _utcnow_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ----------------------------------------------------------------------
# Header rows
# ----------------------------------------------------------------------
@dataclass
class StatusRow:
    group: str
    owner_model: str
    status: Status = Status.PENDING
    artifact: str = "—"
    last_step: str = "—"


# ----------------------------------------------------------------------
# Section
# ----------------------------------------------------------------------
@dataclass
class PlanStep:
    text: str
    done: bool = False


@dataclass
class BoardSection:
    group: str
    status: Status = Status.PENDING
    started_at: Optional[str] = None
    finished_at: Optional[str] = None
    last_completed_step: Optional[str] = None  # e.g. "3/5"
    plan: List[PlanStep] = field(default_factory=list)
    log: List[str] = field(default_factory=list)

    # ------------------------------------------------------------------
    # Render
    # ------------------------------------------------------------------
    def render(self) -> str:
        lines: List[str] = [f"## <SECTION:{self.group}>"]
        lines.append(f"status: {self.status.value}")
        if self.started_at:
            lines.append(f"started_at: {self.started_at}")
        if self.finished_at:
            lines.append(f"finished_at: {self.finished_at}")
        if self.last_completed_step:
            lines.append(f"last_completed_step: {self.last_completed_step}")

        if self.plan:
            lines.append("")
            lines.append("### Plan")
            for i, step in enumerate(self.plan, start=1):
                box = "[x]" if step.done else "[ ]"
                lines.append(f"- {box} {i}. {step.text}")

        if self.log:
            lines.append("")
            lines.append("### Log")
            for entry in self.log:
                lines.append(f"- {entry}")

        return "\n".join(lines).rstrip() + "\n"

    # ------------------------------------------------------------------
    # Parse
    # ------------------------------------------------------------------
    @classmethod
    def parse(cls, text: str) -> "BoardSection":
        """Parse the body of a section (i.e. text AFTER the ``## <SECTION:NAME>`` header).

        ``text`` is what ``BoardFile`` extracts between two section markers.
        """
        group = ""
        m = _SECTION_RE.match(text.lstrip())
        if m:
            group = m.group(1)
            text = text[m.end() :]

        section = cls(group=group)
        lines = text.splitlines()

        i = 0
        # Header key/value lines
        while i < len(lines):
            line = lines[i].strip()
            if not line:
                i += 1
                continue
            if line.startswith("###") or line.startswith("##"):
                break
            if ":" in line and not line.startswith("- "):
                key, _, value = line.partition(":")
                key = key.strip().lower()
                value = value.strip()
                if key == "status":
                    section.status = Status.parse(value)
                elif key == "started_at":
                    section.started_at = value or None
                elif key == "finished_at":
                    section.finished_at = value or None
                elif key == "last_completed_step":
                    section.last_completed_step = value or None
                i += 1
                continue
            break

        # Subsections
        while i < len(lines):
            line = lines[i].strip()
            if line.startswith("### Plan"):
                i += 1
                while i < len(lines):
                    s = lines[i].rstrip()
                    if not s.strip():
                        i += 1
                        continue
                    if s.startswith("###") or s.startswith("##"):
                        break
                    pm = re.match(r"-\s*\[(x| )\]\s*(?:\d+\.\s*)?(.*)$", s)
                    if pm:
                        section.plan.append(
                            PlanStep(text=pm.group(2).strip(), done=pm.group(1) == "x")
                        )
                    i += 1
                continue
            if line.startswith("### Log"):
                i += 1
                while i < len(lines):
                    s = lines[i].rstrip()
                    if not s.strip():
                        i += 1
                        continue
                    if s.startswith("###") or s.startswith("##"):
                        break
                    if s.startswith("- "):
                        section.log.append(s[2:].strip())
                    else:
                        section.log.append(s.strip())
                    i += 1
                continue
            i += 1

        return section

    # ------------------------------------------------------------------
    # Size measurements (for soft circuit breaker)
    # ------------------------------------------------------------------
    def line_count(self) -> int:
        return len(self.render().splitlines())

    def token_count(self) -> int:
        return _est_tokens(self.render())

    def is_oversized(
        self, max_lines: int = SECTION_SOFT_LINES, max_tokens: int = SECTION_SOFT_TOKENS
    ) -> bool:
        return self.line_count() > max_lines or self.token_count() > max_tokens

    def compact_log(
        self, keep_last: int = 5, summary_line: Optional[str] = None
    ) -> int:
        """Roll older log entries into a single 1-2 line summary.

        Returns the number of entries that were folded into the summary.
        """
        if len(self.log) <= keep_last:
            return 0
        rolled = len(self.log) - keep_last
        kept_recent = self.log[-keep_last:]
        summary = summary_line or f"(rolled {rolled} older entries)"
        self.log = [summary] + kept_recent
        return rolled


# ----------------------------------------------------------------------
# Board file
# ----------------------------------------------------------------------
@dataclass
class BoardFile:
    session_id: str
    leader_model: str
    created_at: str = field(default_factory=_utcnow_iso)
    updated_at: str = field(default_factory=_utcnow_iso)
    status_rows: List[StatusRow] = field(default_factory=list)
    plan_lines: List[str] = field(default_factory=list)
    dependencies: List[Tuple[str, List[str]]] = field(default_factory=list)
    sections: Dict[str, BoardSection] = field(default_factory=dict)

    # ------------------------------------------------------------------
    # Render
    # ------------------------------------------------------------------
    def render(self) -> str:
        lines: List[str] = []
        lines.append(
            "<!-- AUTO-GENERATED — leader edits header, workers edit own section -->"
        )
        lines.append("")
        lines.append("# TEAM BOARD")
        lines.append(f"session_id: {self.session_id}")
        lines.append(f"leader_model: {self.leader_model}")
        lines.append(f"created_at: {self.created_at}")
        lines.append(f"updated_at: {self.updated_at}")
        lines.append("")
        lines.append("## Status")
        lines.append("| # | Group | Owner Model | Status | Artifact | Last Step |")
        lines.append("|---|-------|-------------|--------|----------|-----------|")
        for i, row in enumerate(self.status_rows, start=1):
            lines.append(
                f"| {i} | {row.group} | {row.owner_model} | "
                f"{row.status.value} | {row.artifact} | {row.last_step} |"
            )
        lines.append("")

        lines.append("## Plan")
        if self.plan_lines:
            for entry in self.plan_lines:
                lines.append(
                    entry
                    if entry.startswith(
                        ("-", "1", "2", "3", "4", "5", "6", "7", "8", "9")
                    )
                    else f"- {entry}"
                )
        else:
            lines.append("(no plan)")
        lines.append("")

        lines.append("## Dependencies")
        if self.dependencies:
            for group, deps in self.dependencies:
                if deps:
                    lines.append(f"{group} ← {', '.join(deps)}")
                else:
                    lines.append(f"{group} ← (none)")
        else:
            lines.append("(none)")
        lines.append("")

        for row in self.status_rows:
            section = self.sections.get(row.group) or BoardSection(group=row.group)
            lines.append(_DIVIDER)
            lines.append(section.render().rstrip())
            lines.append("")

        return "\n".join(lines).rstrip() + "\n"

    # ------------------------------------------------------------------
    # Parse
    # ------------------------------------------------------------------
    @classmethod
    def parse(cls, text: str) -> "BoardFile":
        # Header key/value lines (between '# TEAM BOARD' and the next '##')
        session_id = ""
        leader_model = ""
        created_at = _utcnow_iso()
        updated_at = _utcnow_iso()

        # Split at first '## <SECTION:' marker — everything before is the
        # header, after is sections (with their dividers).
        first_section = _SECTION_RE.search(text)
        if first_section:
            header_text = text[: first_section.start()]
            sections_text = text[first_section.start() :]
        else:
            header_text = text
            sections_text = ""

        # Parse header line by line
        head_lines = header_text.splitlines()
        i = 0
        in_status = False
        in_plan = False
        in_deps = False
        status_rows: List[StatusRow] = []
        plan_lines: List[str] = []
        deps: List[Tuple[str, List[str]]] = []

        while i < len(head_lines):
            line = head_lines[i].rstrip()
            stripped = line.strip()
            if stripped.startswith("# TEAM BOARD"):
                in_status = in_plan = in_deps = False
                i += 1
                continue
            if stripped.startswith("## Status"):
                in_status, in_plan, in_deps = True, False, False
                i += 1
                continue
            if stripped.startswith("## Plan"):
                in_status, in_plan, in_deps = False, True, False
                i += 1
                continue
            if stripped.startswith("## Dependencies"):
                in_status, in_plan, in_deps = False, False, True
                i += 1
                continue

            if in_status:
                if (
                    stripped.startswith("|")
                    and "---" not in stripped
                    and not stripped.lower().startswith("| #")
                ):
                    cells = [c.strip() for c in stripped.strip("|").split("|")]
                    if len(cells) >= 6:
                        try:
                            _idx = cells[0]
                            row = StatusRow(
                                group=cells[1],
                                owner_model=cells[2],
                                status=Status.parse(cells[3]),
                                artifact=cells[4] or "—",
                                last_step=cells[5] or "—",
                            )
                            status_rows.append(row)
                        except Exception:
                            pass
            elif in_plan:
                if stripped and stripped != "(no plan)":
                    plan_lines.append(line)
            elif in_deps:
                if stripped and stripped != "(none)":
                    if "←" in stripped:
                        group, _, rhs = stripped.partition("←")
                        rhs = rhs.strip()
                        dep_list: List[str] = []
                        if rhs and rhs != "(none)":
                            dep_list = [d.strip() for d in rhs.split(",") if d.strip()]
                        deps.append((group.strip(), dep_list))
            else:
                # Header key/value
                if ":" in stripped and not stripped.startswith("|"):
                    key, _, value = stripped.partition(":")
                    key = key.strip().lower()
                    value = value.strip()
                    if key == "session_id":
                        session_id = value
                    elif key == "leader_model":
                        leader_model = value
                    elif key == "created_at":
                        created_at = value or created_at
                    elif key == "updated_at":
                        updated_at = value or updated_at
            i += 1

        # Sections
        sections: Dict[str, BoardSection] = {}
        section_starts = [m.start() for m in _SECTION_RE.finditer(sections_text)]
        section_starts.append(len(sections_text))
        for j in range(len(section_starts) - 1):
            chunk = sections_text[section_starts[j] : section_starts[j + 1]]
            # Strip trailing divider lines from the chunk
            chunk_lines = [
                ln
                for ln in chunk.splitlines()
                if ln.strip("─\t ").strip()  # drop pure-divider lines
            ]
            chunk = "\n".join(chunk_lines)
            section = BoardSection.parse(chunk)
            if section.group:
                sections[section.group] = section

        return cls(
            session_id=session_id,
            leader_model=leader_model,
            created_at=created_at,
            updated_at=updated_at,
            status_rows=status_rows,
            plan_lines=plan_lines,
            dependencies=deps,
            sections=sections,
        )

    # ------------------------------------------------------------------
    # Mutators
    # ------------------------------------------------------------------
    def touch(self) -> None:
        self.updated_at = _utcnow_iso()

    def find_row(self, group: str) -> Optional[StatusRow]:
        for r in self.status_rows:
            if r.group == group:
                return r
        return None

    def upsert_section(self, section: BoardSection) -> None:
        """Replace the section AND sync the matching status row."""
        self.sections[section.group] = section
        row = self.find_row(section.group)
        if row is not None:
            row.status = section.status
            if section.last_completed_step:
                row.last_step = section.last_completed_step
        self.touch()

    def add_group(
        self, group: str, owner_model: str, plan: List[str], artifact_relpath: str = "—"
    ) -> None:
        """Append a new group: new status row + empty section."""
        if self.find_row(group) is not None:
            return
        self.status_rows.append(
            StatusRow(
                group=group,
                owner_model=owner_model,
                status=Status.PENDING,
                artifact=artifact_relpath,
            )
        )
        self.sections[group] = BoardSection(
            group=group,
            status=Status.PENDING,
            plan=[PlanStep(text=t, done=False) for t in plan],
        )
        self.touch()

    def set_status(
        self, group: str, status: Status, last_step: Optional[str] = None
    ) -> None:
        row = self.find_row(group)
        if row is not None:
            row.status = status
            if last_step is not None:
                row.last_step = last_step
        section = self.sections.get(group)
        if section is not None:
            section.status = status
            if last_step is not None:
                section.last_completed_step = last_step
            if status == Status.RUNNING and not section.started_at:
                section.started_at = _utcnow_iso()
            if (
                status
                in (
                    Status.DONE_CLEAN,
                    Status.DONE_WITH_WARNINGS,
                    Status.FAILED,
                    Status.INTERRUPTED,
                )
                and not section.finished_at
            ):
                section.finished_at = _utcnow_iso()
        self.touch()

    # ------------------------------------------------------------------
    # Size (for hard circuit breaker)
    # ------------------------------------------------------------------
    def line_count(self) -> int:
        return len(self.render().splitlines())

    def token_count(self) -> int:
        return _est_tokens(self.render())

    def is_oversized(
        self, max_lines: int = BOARD_HARD_LINES, max_tokens: int = BOARD_HARD_TOKENS
    ) -> bool:
        return self.line_count() > max_lines or self.token_count() > max_tokens


# ----------------------------------------------------------------------
# Atomic file I/O
# ----------------------------------------------------------------------
def write_board(path: Path, board: BoardFile) -> None:
    """Atomically overwrite ``team_board.md`` with ``board``'s rendering."""
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = board.render()
    fd, tmp_path = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=str(path.parent),
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            f.write(payload)
            f.flush()
            try:
                os.fsync(f.fileno())
            except OSError:
                pass
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def read_board(path: Path) -> BoardFile:
    """Read and parse ``team_board.md``. Raises FileNotFoundError if absent."""
    with open(path, "r", encoding="utf-8") as f:
        return BoardFile.parse(f.read())


def slice_section(text: str, group: str) -> Optional[str]:
    """Extract just one section's raw body from a board file's text.

    Used by workers that don't want to parse the whole file — they only
    need their own section + the status table.
    """
    starts = list(_SECTION_RE.finditer(text))
    for i, m in enumerate(starts):
        if m.group(1) != group:
            continue
        end = starts[i + 1].start() if i + 1 < len(starts) else len(text)
        return text[m.start() : end]
    return None


def slice_status_table(text: str) -> str:
    """Extract just the ``## Status`` section as raw text (header + rows).

    Returns empty string if not found.
    """
    m = re.search(r"^##\s+Status\s*$", text, flags=re.MULTILINE)
    if not m:
        return ""
    start = m.start()
    # Find next '## ' header (not '##<SECTION...' which has no space)
    after = text[m.end() :]
    nm = re.search(r"^##\s+\w", after, flags=re.MULTILINE)
    end = m.end() + nm.start() if nm else len(text)
    return text[start:end].rstrip() + "\n"
