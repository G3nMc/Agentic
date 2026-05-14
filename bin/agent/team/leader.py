"""Team Leader agent.

A thin orchestrator that lives outside the regular Workflow loop.
Unlike Reasoner/Executor it has its OWN tool registry (the 7 verbs in
:mod:`leader_tools`) — no filesystem, no git, no shell. It only mutates
``team_board.md``.

Lifecycle:
  1. ``decompose(user_task)`` — first-pass planning. Calls create_group /
     assign_dependency until the leader produces a final answer. Returns
     the list of group names in run order.
  2. ``review_after(group, result)`` — between workers. Calls
     check_previous → either nothing (proceed) or decide_recovery.
     Returns ``"continue"`` | ``"abort"``.
  3. ``finalize(summary_hint)`` — at the end. Calls mark_done +
     compact_board (if needed) + finalize. Returns the user-visible
     summary text.

The leader uses the same ``<tool>{...}</tool>`` protocol as the rest of
the agents, so the existing parser in
``loop/tool_dispatch.parse_all_tag_tool_calls`` picks up its calls
without modification.
"""
from __future__ import annotations

import json
import logging
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

from ..agents.base import Agent
from ..backends.backend_base import ModelBackend
from ..core.state import WorkflowState
from ..loop import tool_dispatch as _td
from .leader_tools import (
    LEADER_TOOL_DEFINITIONS,
    LeaderTools,
    render_leader_system_prompt,
)
from .paths import TeamPaths
from .runner import WorkerResult
from .status import Status, is_clean, is_failure


logger = logging.getLogger(__name__)


# How many round-trips the leader gets per phase before we force a stop.
# Decompose tends to be the longest (one create_group call per group);
# review_after / finalize are single-decision phases.
_DECOMPOSE_MAX_TURNS = 12
_REVIEW_MAX_TURNS = 4
_FINALIZE_MAX_TURNS = 4


class LeaderAgent(Agent):
    """Run the leader phases against a TeamPaths.

    The leader does NOT inherit the global tool registry. It builds its
    own messages and dispatches tool calls directly to :class:`LeaderTools`.
    """
    name = "leader"

    def __init__(
        self,
        backend: ModelBackend,
        *,
        paths: TeamPaths,
        max_tokens: int = 4096,
        temperature: float = 0.2,
    ):
        super().__init__(
            backend=backend,
            system_prompt=render_leader_system_prompt(),
            temperature=temperature,
            max_tokens=max_tokens,
        )
        self.paths = paths
        self.tools = LeaderTools(paths)

    # The base Agent.run() shape is for the regular workflow — the
    # leader doesn't fit it. Implement a stub that just raises so a
    # mis-wired pipeline can't accidentally include the leader.
    def run(self, state: WorkflowState) -> WorkflowState:  # pragma: no cover
        raise NotImplementedError(
            "LeaderAgent is driven via decompose/review_after/finalize, "
            "not the workflow run() loop."
        )

    # ------------------------------------------------------------------
    # Phase 1: decompose
    # ------------------------------------------------------------------
    def decompose(self, user_task: str) -> List[str]:
        """Drive the leader to plan groups + dependencies.

        Returns the list of group names in the order the runner should
        spawn them. The order is the order create_group was called.

        Bails out early when the same call fails twice in a row — some
        models (notably gpt-oss variants) get stuck emitting an
        unrecognised tool name and would otherwise burn the entire
        ``_DECOMPOSE_MAX_TURNS`` budget on the same broken call.
        """
        history: List[Dict[str, Any]] = []
        prompt = self._decompose_prompt(user_task)
        order: List[str] = []
        last_failed_sig: Optional[str] = None
        consecutive_failures = 0
        _MAX_IDENTICAL_FAILURES = 2

        # Minimum inter-call delay for rate-limited backends (Gemini free
        # tier = 5 RPM). The backend's own retry logic handles 429s, but
        # a small pause between turns prevents hitting the limit at all.
        _MIN_TURN_INTERVAL_S = 3.0

        for turn in range(_DECOMPOSE_MAX_TURNS):
            if turn > 0:
                time.sleep(_MIN_TURN_INTERVAL_S)
            text = self._chat_once(history, prompt if turn == 0 else "")
            calls = self._extract_calls(text)
            if not calls and self._looks_like_final(text):
                break
            if not calls:
                # Nudge: leader emitted prose. Demand a tool call or final.
                history.append({"role": "assistant", "content": text})
                history.append({
                    "role": "user",
                    "content": (
                        "Reply with exactly ONE tool call, OR a single "
                        "sentence saying 'plan done' if no more groups."
                    ),
                })
                continue

            for name, params in calls:
                result = self.tools.execute(name, params or {})
                if name == "create_group" and result.get("status") == "success":
                    order.append(result.get("group", ""))

                # Anti-loop: if the same call signature fails repeatedly,
                # stop and return what we have. Better to abort with a
                # partial plan than to hammer the same broken call.
                sig = json.dumps(
                    {"tool": name, "params": params or {}},
                    sort_keys=True, ensure_ascii=False,
                )
                if result.get("status") == "error":
                    if sig == last_failed_sig:
                        consecutive_failures += 1
                    else:
                        consecutive_failures = 1
                        last_failed_sig = sig
                    if consecutive_failures >= _MAX_IDENTICAL_FAILURES:
                        logger.warning(
                            "Leader stuck on identical failing call "
                            "(%s) — aborting decompose",
                            name,
                        )
                        history.append({
                            "role": "user",
                            "content": (
                                "You repeated the same failing call. "
                                "Stop. If no more groups can be created, "
                                "say 'plan done'."
                            ),
                        })
                        return [g for g in order if g]
                else:
                    last_failed_sig = None
                    consecutive_failures = 0

                history.append({"role": "assistant", "content":
                    f'<tool>{json.dumps({"tool": name, "parameters": params}, ensure_ascii=False)}</tool>'})
                history.append({
                    "role": "user",
                    "content": json.dumps(result, ensure_ascii=False),
                })
                if name == "finalize":
                    return [g for g in order if g]

        # Filter empties (defensive)
        return [g for g in order if g]

    def _decompose_prompt(self, user_task: str) -> str:
        return (
            "USER TASK\n"
            f"{user_task}\n\n"
            "Plan this work as a sequence of worker groups. Each group "
            "must be self-contained and have 3-7 imperative plan steps. "
            "Express dependencies via depends_on. When done with planning "
            "say 'plan done'."
        )

    # ------------------------------------------------------------------
    # Phase 2: review between workers (called by the runner hook)
    # ------------------------------------------------------------------
    def review_after(self, completed: WorkerResult) -> str:
        """Decide what to do after one worker finishes.

        Returns ``"continue"`` to keep the chain going, ``"abort"`` to stop.
        On clean exits this is a no-op fast-path that does NOT call the
        model — saves a round-trip when nothing is wrong.
        """
        if is_clean(completed.final_status):
            return "continue"
        if not is_failure(completed.final_status):
            # Still running or pending — shouldn't happen here, but be safe.
            return "continue"

        # Failure: ask the leader to decide
        history: List[Dict[str, Any]] = []
        prompt = (
            "WORKER FAILURE\n"
            f"group: {completed.group}\n"
            f"final_status: {completed.final_status.value}\n"
            f"exit_code: {completed.exit_code}\n"
            f"timed_out: {completed.timed_out}\n"
            f"notes: {'; '.join(completed.notes) or '—'}\n\n"
            "Call decide_recovery with one of: retry, skip_with_partial, abort.\n"
            "Use 'retry' for transient issues (timeout, single crash). "
            "Use 'skip_with_partial' if the group is non-blocking. "
            "Use 'abort' if downstream groups depend on it AND retry is unlikely to help."
        )
        for turn in range(_REVIEW_MAX_TURNS):
            text = self._chat_once(history, prompt if turn == 0 else "")
            calls = self._extract_calls(text)
            if not calls:
                history.append({"role": "assistant", "content": text})
                history.append({"role": "user",
                                "content": "Reply with a decide_recovery tool call."})
                continue
            for name, params in calls:
                if name != "decide_recovery":
                    history.append({"role": "user",
                                    "content": "Only decide_recovery is allowed here."})
                    continue
                result = self.tools.execute(name, params or {})
                if result.get("status") == "success":
                    decision = result.get("decision", "abort")
                    if decision == "abort":
                        return "abort"
                    return "continue"
                # invalid — let the leader retry
                history.append({"role": "assistant", "content": text})
                history.append({"role": "user",
                                "content": json.dumps(result, ensure_ascii=False)})
        # Out of turns: default to abort (safest)
        return "abort"

    # ------------------------------------------------------------------
    # Phase 3: finalize (compact + summarize)
    # ------------------------------------------------------------------
    def finalize(self, summary_hint: str = "") -> str:
        """Wrap up the session.

        - If the board is over-budget, ask the leader to compact_board.
        - Always call mark_done + finalize.
        Returns the user-visible summary string.
        """
        # Programmatic compact if needed (don't waste a turn for this).
        from .artifact import read_artifact
        from .board import read_board, BOARD_HARD_LINES, BOARD_HARD_TOKENS
        from .status import is_failure
        try:
            bf = read_board(self.paths.board)
            if bf.is_oversized(BOARD_HARD_LINES, BOARD_HARD_TOKENS):
                self.tools.execute("compact_board", {})
        except FileNotFoundError:
            pass

        # mark_done first
        result = self.tools.execute("mark_done", {})
        ok = bool(result.get("ok"))
        pending = result.get("pending") or []

        # Synthesize a summary instead of looping through model turns —
        # the leader's job here is bookkeeping, not prose. The text is
        # what the user sees in chat.
        failure_lines: list = []
        warning_lines: list = []
        nothing_changed = True
        try:
            bf = read_board(self.paths.board)
            row_lines = []
            for r in bf.status_rows:
                ap = self.paths.artifact_path(r.group)
                files_count = 0
                if ap.exists():
                    try:
                        a = read_artifact(ap)
                        files_count = len(a.files_touched)
                        if files_count > 0:
                            nothing_changed = False
                    except Exception:  # noqa: BLE001
                        pass
                if files_count > 0:
                    suffix = f" ({files_count} file" \
                             f"{'s' if files_count != 1 else ''} modified)"
                else:
                    suffix = " (0 files modified)"
                row_lines.append(f"  - {r.group}: {r.status.value}{suffix}")
            body = "\n".join(row_lines) if row_lines else "(no groups)"

            # Surface failed-group reasons + worker-prose-only warnings so
            # the user sees actionable context instead of bare statuses.
            for r in bf.status_rows:
                ap = self.paths.artifact_path(r.group)
                if is_failure(r.status):
                    if not ap.exists():
                        failure_lines.append(
                            f"  - {r.group}: {r.status.value} "
                            f"(no artifact — worker died very early)")
                        continue
                    try:
                        a = read_artifact(ap)
                        s = a.summary or "(no error message)"
                        if len(s) > 300:
                            s = s[:297] + "..."
                        failure_lines.append(f"  - {r.group}: {s}")
                    except Exception as e:  # noqa: BLE001
                        failure_lines.append(
                            f"  - {r.group}: artifact unreadable ({e})")
                elif r.status.value == "DONE_WITH_WARNINGS" and ap.exists():
                    try:
                        a = read_artifact(ap)
                        if a.warnings:
                            warning_lines.append(
                                f"  - {r.group}: {a.warnings[0]}")
                    except Exception:  # noqa: BLE001
                        pass
        except FileNotFoundError:
            body = "(board missing)"

        summary = (summary_hint or "Team Mode session complete.").strip()
        if not ok:
            summary += f"\n\nPending groups: {', '.join(pending) or '—'}"
        summary += f"\n\nGroup outcomes:\n{body}"
        if failure_lines:
            summary += "\n\nFailure reasons:\n" + "\n".join(failure_lines)
        if warning_lines:
            summary += "\n\nWarnings:\n" + "\n".join(warning_lines)
        if nothing_changed:
            summary += (
                "\n\n⚠ NOTHING WAS CHANGED ON DISK. The workers reported "
                "completion but no files were modified. The result is "
                "likely hallucinated — check the artifacts under "
                f".agent/team/{self.paths.session_id}/artifacts/ for "
                "details, or re-run with a more capable worker model."
            )

        self.tools.execute("finalize", {"summary": summary})
        return summary

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------
    def _chat_once(self, history: List[Dict[str, Any]],
                   user_prompt: Optional[str]) -> str:
        messages: List[Dict[str, Any]] = [
            {"role": "system", "content": self.system_prompt}
        ]
        for m in history:
            messages.append(m)
        if user_prompt:
            messages.append({"role": "user", "content": user_prompt})
        text, _finish = self.backend.chat(
            messages=messages,
            max_tokens=self.max_tokens,
            temperature=self.temperature,
            tools=LEADER_TOOL_DEFINITIONS,
        )
        cleaned = _td.clean_history_text(text or "")
        print(f"[leader←{self.model_id}] {cleaned[:300]}",
              file=sys.stderr, flush=True)
        return cleaned

    def _extract_calls(self, text: str) -> List[Tuple[str, Dict[str, Any]]]:
        return _td.parse_all_tag_tool_calls(text, LEADER_TOOL_DEFINITIONS)

    def _looks_like_final(self, text: str) -> bool:
        if not text:
            return False
        lower = text.strip().lower()
        return ("plan done" in lower
                or lower.endswith("done.")
                or "no more groups" in lower)
