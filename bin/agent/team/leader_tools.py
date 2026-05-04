"""The 7 verbs available to the team leader.

Each tool is a pure operation against the on-disk ``team_board.md``.
Verbs are intentionally narrow — anything richer (re-planning,
talking to the user, inspecting tool transcripts) is OUT of scope
to keep the leader from accumulating context.

Tools:
    create_group(name, owner_model, plan_steps, depends_on?)
    assign_dependency(group, depends_on)
    check_previous(group)
    decide_recovery(failed_group, decision)
    mark_done()
    compact_board()
    finalize(summary)
"""
from __future__ import annotations

import json
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from .board import (
    BOARD_HARD_LINES,
    BOARD_HARD_TOKENS,
    BoardFile,
    BoardSection,
    PlanStep,
    StatusRow,
    read_board,
    write_board,
)
from .paths import TeamPaths
from .status import Status, is_clean, is_failure, is_terminal


def _utcnow_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ----------------------------------------------------------------------
# Tool definitions (OpenAPI-ish — keep the same shape used elsewhere
# in the codebase so prompts can be rendered uniformly).
# ----------------------------------------------------------------------
LEADER_TOOL_DEFINITIONS: List[Dict[str, Any]] = [
    {
        "function": {
            "name": "create_group",
            "description": (
                "Create a new worker group. Adds a row to the status table "
                "and an empty section to the board. Plan_steps is the list "
                "of imperative-form sub-tasks the worker must complete."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "name":         {"type": "string"},
                    "owner_model":  {"type": "string"},
                    "plan_steps":   {"type": "array", "items": {"type": "string"}},
                    "depends_on":   {"type": "array", "items": {"type": "string"}},
                },
                "required": ["name", "owner_model", "plan_steps"],
            },
        }
    },
    {
        "function": {
            "name": "assign_dependency",
            "description": (
                "Add or replace the dependency edge for a group. "
                "depends_on is the list of upstream group names."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "group":      {"type": "string"},
                    "depends_on": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["group", "depends_on"],
            },
        }
    },
    {
        "function": {
            "name": "check_previous",
            "description": (
                "Inspect the upstream dependency chain of a group. Returns "
                "{prev_group, status, warnings, last_step} for each direct "
                "dependency. Call before deciding whether to spawn a worker."
            ),
            "parameters": {
                "type": "object",
                "properties": {"group": {"type": "string"}},
                "required": ["group"],
            },
        }
    },
    {
        "function": {
            "name": "decide_recovery",
            "description": (
                "Record a recovery decision for a group whose last run failed. "
                "decision must be one of: 'retry', 'skip_with_partial', 'abort'. "
                "On 'retry' the row is reset to PENDING; on 'skip_with_partial' "
                "the group is left in its terminal state and the chain proceeds; "
                "on 'abort' the chain stops."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "failed_group": {"type": "string"},
                    "decision":     {"type": "string",
                                     "enum": ["retry", "skip_with_partial", "abort"]},
                    "reason":       {"type": "string"},
                },
                "required": ["failed_group", "decision"],
            },
        }
    },
    {
        "function": {
            "name": "mark_done",
            "description": (
                "Verify all groups are in a terminal status. Returns "
                "{ok: bool, pending: [groups]}."
            ),
            "parameters": {"type": "object", "properties": {}, "required": []},
        }
    },
    {
        "function": {
            "name": "compact_board",
            "description": (
                "Collapse DONE_CLEAN sections to one-line summaries. Run when "
                "the board is over the hard token/line budget. Active "
                "(RUNNING/PENDING/FAILED) sections are left intact."
            ),
            "parameters": {"type": "object", "properties": {}, "required": []},
        }
    },
    {
        "function": {
            "name": "finalize",
            "description": (
                "Close out the session. Writes a final 'session_summary' row "
                "into the board. The leader should not call any further tools "
                "after this."
            ),
            "parameters": {
                "type": "object",
                "properties": {"summary": {"type": "string"}},
                "required": ["summary"],
            },
        }
    },
]

LEADER_TOOL_NAMES = frozenset(d["function"]["name"] for d in LEADER_TOOL_DEFINITIONS)


# ----------------------------------------------------------------------
# Recovery decision record
# ----------------------------------------------------------------------
@dataclass
class RecoveryDecision:
    group: str
    decision: str  # "retry" | "skip_with_partial" | "abort"
    reason: str
    at: str

    def to_log_line(self) -> str:
        return json.dumps({
            "at": self.at, "group": self.group,
            "decision": self.decision, "reason": self.reason,
        }, ensure_ascii=False)


# ----------------------------------------------------------------------
# Tool dispatcher
# ----------------------------------------------------------------------
class LeaderTools:
    """Stateful dispatcher: holds the TeamPaths and routes tool calls.

    Loads / saves the board on every call so concurrent edits from a
    worker (which only writes its OWN section) merge cleanly. The
    leader never overwrites worker-owned sections.
    """

    def __init__(self, paths: TeamPaths):
        self.paths = paths
        self._recovery_log: List[RecoveryDecision] = []
        self._finalized: bool = False

    # ------------------------------------------------------------------
    # Public dispatch
    # ------------------------------------------------------------------
    # Some models (gpt-oss, older OpenAI-style fine-tunes) emit tool
    # names with a namespacing prefix like ``tool.create_group``,
    # ``functions.create_group``. Strip those before lookup so the
    # dispatcher tolerates the quirk instead of rejecting every call.
    _NAME_PREFIXES = ("tool.", "tools.", "function.", "functions.",
                      "namespace.", "leader.", "team.")

    def execute(self, name: str, params: Dict[str, Any]) -> Dict[str, Any]:
        canonical = self._canonicalize_name(name)
        if canonical not in LEADER_TOOL_NAMES:
            return {"status": "error",
                    "message": f"Unknown leader tool: {name!r}. "
                               f"Valid names: {sorted(LEADER_TOOL_NAMES)}"}
        method: Callable = getattr(self, f"_do_{canonical}")
        try:
            return method(**(params or {}))
        except TypeError as e:
            return {"status": "error", "message": f"Invalid params: {e}"}
        except Exception as e:  # noqa: BLE001
            return {"status": "error", "message": str(e)}

    @classmethod
    def _canonicalize_name(cls, name: str) -> str:
        if not name:
            return name
        s = str(name).strip()
        lowered = s.lower()
        for pfx in cls._NAME_PREFIXES:
            if lowered.startswith(pfx):
                return s[len(pfx):]
        return s

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------
    def _load(self) -> BoardFile:
        try:
            return read_board(self.paths.board)
        except FileNotFoundError:
            raise RuntimeError(
                f"Board not found at {self.paths.board}. The host must "
                "create it before invoking the leader."
            )

    def _save(self, bf: BoardFile) -> None:
        write_board(self.paths.board, bf)

    def recovery_decisions(self) -> List[RecoveryDecision]:
        return list(self._recovery_log)

    # ------------------------------------------------------------------
    # Verbs
    # ------------------------------------------------------------------
    def _do_create_group(
        self,
        name: str,
        owner_model: str,
        plan_steps: List[str],
        depends_on: Optional[List[str]] = None,
    ) -> Dict[str, Any]:
        if not name or not isinstance(name, str):
            return {"status": "error", "message": "name must be a non-empty string"}
        if not owner_model:
            return {"status": "error", "message": "owner_model required"}
        if not isinstance(plan_steps, list) or not plan_steps:
            return {"status": "error", "message": "plan_steps must be a non-empty list"}

        bf = self._load()
        if bf.find_row(name) is not None:
            return {"status": "error", "message": f"group {name!r} already exists"}

        # Validate dependencies exist (tolerant: unknown deps are an error
        # because they would silently leave a group unrunnable).
        deps = [str(d) for d in (depends_on or []) if d]
        for d in deps:
            if bf.find_row(d) is None:
                return {"status": "error",
                        "message": f"unknown dependency {d!r} for {name!r}"}

        artifact_relpath = f"artifacts/{name}.json"
        bf.add_group(name, owner_model=owner_model,
                     plan=[str(s) for s in plan_steps],
                     artifact_relpath=artifact_relpath)
        # Replace any existing dep row for this group (fresh insert)
        bf.dependencies = [d for d in bf.dependencies if d[0] != name]
        bf.dependencies.append((name, deps))
        self._save(bf)
        return {"status": "success", "group": name, "deps": deps}

    def _do_assign_dependency(
        self, group: str, depends_on: List[str],
    ) -> Dict[str, Any]:
        bf = self._load()
        if bf.find_row(group) is None:
            return {"status": "error", "message": f"unknown group {group!r}"}
        deps = [str(d) for d in (depends_on or []) if d]
        for d in deps:
            if bf.find_row(d) is None:
                return {"status": "error", "message": f"unknown dependency {d!r}"}
        bf.dependencies = [d for d in bf.dependencies if d[0] != group]
        bf.dependencies.append((group, deps))
        bf.touch()
        self._save(bf)
        return {"status": "success", "group": group, "deps": deps}

    def _do_check_previous(self, group: str) -> Dict[str, Any]:
        bf = self._load()
        if bf.find_row(group) is None:
            return {"status": "error", "message": f"unknown group {group!r}"}
        deps_map = dict(bf.dependencies)
        deps = deps_map.get(group, [])
        out: List[Dict[str, Any]] = []
        for d in deps:
            row = bf.find_row(d)
            section = bf.sections.get(d)
            warnings: List[str] = []
            if section is not None:
                warnings = [ln for ln in section.log if "warn" in ln.lower()]
            out.append({
                "prev_group": d,
                "status": row.status.value if row else "PENDING",
                "last_step": row.last_step if row else "—",
                "warnings": warnings,
            })
        return {"status": "success", "deps": out}

    def _do_decide_recovery(
        self,
        failed_group: str,
        decision: str,
        reason: str = "",
    ) -> Dict[str, Any]:
        if decision not in ("retry", "skip_with_partial", "abort"):
            return {"status": "error",
                    "message": f"decision must be retry|skip_with_partial|abort, got {decision!r}"}
        bf = self._load()
        row = bf.find_row(failed_group)
        if row is None:
            return {"status": "error", "message": f"unknown group {failed_group!r}"}
        if not is_failure(row.status):
            return {"status": "error",
                    "message": f"{failed_group!r} is not in a failure state ({row.status.value})"}

        rec = RecoveryDecision(
            group=failed_group, decision=decision,
            reason=reason or "", at=_utcnow_iso(),
        )
        self._recovery_log.append(rec)

        if decision == "retry":
            # Reset row + section to PENDING; keep the existing plan but
            # clear the log of the failed run (it confuses the next worker).
            row.status = Status.PENDING
            row.last_step = "—"
            section = bf.sections.get(failed_group)
            if section is not None:
                section.status = Status.PENDING
                section.started_at = None
                section.finished_at = None
                section.last_completed_step = None
                section.log.append(
                    f"{_utcnow_iso()} reset for retry — {reason or 'no reason'}"
                )
        elif decision == "skip_with_partial":
            # Leave terminal status; just append a warning marker.
            section = bf.sections.get(failed_group)
            if section is not None:
                section.log.append(
                    f"{_utcnow_iso()} skipped after failure — {reason or 'no reason'}"
                )
        # 'abort': board untouched; the runner reads the recovery log.
        bf.touch()
        self._save(bf)

        # Append to recovery audit log on disk too
        try:
            with open(self.paths.recovery_log, "a", encoding="utf-8") as f:
                f.write(rec.to_log_line() + "\n")
        except OSError:
            pass

        return {"status": "success", "decision": decision, "group": failed_group}

    def _do_mark_done(self) -> Dict[str, Any]:
        bf = self._load()
        pending = [r.group for r in bf.status_rows if not is_terminal(r.status)]
        return {"status": "success", "ok": not pending, "pending": pending}

    def _do_compact_board(self) -> Dict[str, Any]:
        """Collapse DONE_CLEAN sections to a one-line summary.

        The summary keeps the section header + status + a short log
        derived from the section's existing log. Saves a lot of tokens
        when the board has grown long.
        """
        bf = self._load()
        compacted: List[str] = []
        for row in bf.status_rows:
            if row.status != Status.DONE_CLEAN:
                continue
            section = bf.sections.get(row.group)
            if section is None:
                continue
            if len(section.log) <= 1 and not section.plan:
                continue
            short = section.log[-1] if section.log else "ok"
            collapsed = BoardSection(
                group=row.group,
                status=Status.DONE_CLEAN,
                started_at=section.started_at,
                finished_at=section.finished_at,
                last_completed_step=section.last_completed_step,
                log=[f"compacted: {short}"],
                plan=[],
            )
            bf.sections[row.group] = collapsed
            compacted.append(row.group)

        bf.touch()
        self._save(bf)
        return {"status": "success", "compacted": compacted,
                "lines": bf.line_count(), "tokens": bf.token_count()}

    def _do_finalize(self, summary: str) -> Dict[str, Any]:
        if self._finalized:
            return {"status": "error", "message": "already finalized"}
        bf = self._load()
        # Append the summary as a synthetic 'session_summary' tail in plan_lines.
        bf.plan_lines.append("")
        bf.plan_lines.append(f"Session summary: {summary.strip()}")
        bf.touch()
        self._save(bf)
        self._finalized = True
        return {"status": "success", "summary": summary}


# ----------------------------------------------------------------------
# System prompt (small, fixed verb list)
# ----------------------------------------------------------------------
def render_leader_system_prompt(*, max_tokens_per_group: int = 600) -> str:
    """The leader's system prompt — short, opinionated, scope-locked.

    The leader uses the SAME ``<tool>{...}</tool>`` protocol the rest of
    the agents use, so the existing parser in ``loop/tool_dispatch`` can
    pick it up without modification.
    """
    tool_lines: List[str] = []
    for d in LEADER_TOOL_DEFINITIONS:
        fn = d["function"]
        params = (fn.get("parameters") or {}).get("properties") or {}
        required = set((fn.get("parameters") or {}).get("required") or [])
        sig_parts: List[str] = []
        for k, spec in params.items():
            t = spec.get("type", "any")
            if isinstance(t, list):
                t = "|".join(t)
            sig_parts.append(f"{k}{'?' if k not in required else ''}:{t}")
        tool_lines.append(
            f"  - {fn['name']}({', '.join(sig_parts)}): "
            f"{fn.get('description', '').strip()}"
        )

    return "\n".join([
        "You are the TEAM LEADER. Your only job is to decompose a heavy task "
        "into named worker groups and orchestrate them sequentially. You DO "
        "NOT write code, read files, run commands, or talk to the user.",
        "",
        "RESPONSIBILITIES",
        "  1. On the first turn, call create_group repeatedly to build the plan. "
        "     Use assign_dependency to record ordering constraints.",
        "  2. Between workers, call check_previous to confirm the upstream "
        "     finished cleanly. If it failed, call decide_recovery.",
        "  3. When the board grows past its budget, call compact_board.",
        "  4. When all groups are terminal, call mark_done; if ok, call finalize.",
        "",
        "STRICT RULES",
        "  - Each worker group must have a clear, narrow purpose and 3-7 plan steps.",
        "  - You must NEVER add tools beyond the 7 listed below.",
        "  - You must NEVER ask the user questions or produce free-form prose "
        "    instead of a tool call. Each turn is exactly ONE tool call OR a "
        "    final answer that summarizes the run.",
        "  - Plan groups so each worker stays under ~"
            f"{max_tokens_per_group} tokens of context — split heavy work.",
        "",
        "PLAN STEPS MUST BE CONCRETE AND TOOL-MAPPABLE",
        "  Workers have these tools available: read_file, write_file, "
        "  patch_file, append_file, search_in_files, list_files, "
        "  flutter_analyze, python_check, run_command, git_*.",
        "  Every plan step you write MUST imply at least one of those tools.",
        "",
        "  GOOD steps (concrete, imperative, tool-mappable):",
        "    - 'Read lib/ui/widgets/message_bubble.dart'",
        "    - 'Replace AppTheme.userBubble with AppTheme.bgSecondary in message_bubble.dart'",
        "    - 'Run flutter_analyze and fix any reported errors'",
        "    - 'Patch the build() method to use AppTheme.textPrimary for the timestamp'",
        "    - 'Search lib/ for hardcoded Color(0x... usages'",
        "",
        "  BAD steps (forbidden — purely conceptual, produce hallucinated 'work'):",
        "    - 'Document hardcoded colors'        ← workers can't 'document'",
        "    - 'Verify accessibility / contrast'  ← no contrast tool",
        "    - 'Ensure backward compatibility'    ← vague, no action",
        "    - 'Confirm coverage is complete'     ← meta-task",
        "    - 'Review architecture'              ← no edit, no test",
        "    - 'Specify migration path'           ← prose only",
        "    - 'Run visual diff tests'            ← no such tool",
        "    - 'Add unit tests for color rendering'  ← OK only if you "
        "      include a follow-up step that writes the test file",
        "",
        "  If your task seems to need a 'verify' or 'document' step, replace "
        "  it with the concrete check the worker would actually do "
        "  ('Run flutter_analyze', 'Search for the new token usages').",
        "",
        "TOOL OUTPUT FORMAT",
        '  <tool>{"tool":"NAME","parameters":{...}}</tool>',
        "",
        "AVAILABLE TOOLS",
        *tool_lines,
    ])
