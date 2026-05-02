"""End-to-end Team Mode session driver.

Composes the leader, runner, and circuit breakers into a single
:meth:`TeamSession.run` call. Phases 1-5 own the building blocks;
this module is just glue plus two policies the user-facing spec
requires:

  * Hard board circuit breaker — before spawning each worker, if the
    board is over budget, force a leader compaction turn.
  * Retry cap — a group can be retried at most :data:`MAX_RETRIES`
    times before any further failure forces ``skip_with_partial`` or
    ``abort``.
"""
from __future__ import annotations

import logging
import sys
import uuid
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Callable, Dict, List, Optional

from .board import (
    BOARD_HARD_LINES,
    BOARD_HARD_TOKENS,
    BoardFile,
    read_board,
    write_board,
)
from .leader import LeaderAgent
from .leader_tools import LeaderTools
from .paths import TeamPaths
from .runner import (
    DEFAULT_WORKER_TIMEOUT_S,
    SequentialRunner,
    WorkerResult,
)
from .status import Status, is_clean, is_failure


logger = logging.getLogger(__name__)

MAX_RETRIES = 2


def _utcnow_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class TeamSession:
    """Drive one Team Mode session from user task → final summary."""
    paths: TeamPaths
    leader: LeaderAgent
    base_path: str
    timeout_s: float = DEFAULT_WORKER_TIMEOUT_S
    python: Optional[str] = None
    worker_entry: str = "agent.team.worker_entry"
    worker_extra_args: Optional[List[str]] = None
    worker_extra_env: Optional[Dict[str, str]] = None
    cwd: Optional[str] = None
    leader_model_id: str = "leader"
    max_retries: int = MAX_RETRIES

    _retry_counts: Dict[str, int] = field(default_factory=lambda: defaultdict(int))

    # ------------------------------------------------------------------
    def run(self, user_task: str) -> Dict[str, Any]:
        """Plan → execute groups → summarize.

        Pre-flight invariants — both must hold before any worker spawns:
          (a) Reset the board to a fresh state. Stale content from a prior
              session must NEVER leak into a new one. ``write_board`` is
              atomic (write-temp-then-rename), so partial overwrites are
              impossible.
          (b) After the leader's decomposition, the board must contain
              at least one group AND the in-memory ``order`` list must be
              non-empty. If the leader fails reasoning, no worker chain
              starts.
        """
        # (a) Wipe + initialize.
        self.paths.ensure_dirs()
        bf = BoardFile(
            session_id=f"{_utcnow_iso()}-{uuid.uuid4().hex[:6]}",
            leader_model=self.leader_model_id,
        )
        write_board(self.paths.board, bf)

        # (b) Decompose — bail out before runner if the leader produced
        # nothing usable. We check BOTH the in-memory result and the
        # board file on disk; if they disagree we still refuse to start.
        try:
            order = self.leader.decompose(user_task)
        except Exception as e:  # noqa: BLE001
            logger.exception("Leader.decompose crashed: %s", e)
            return {"status": "error",
                    "message": f"leader reasoning failed: {e}",
                    "summary": "", "results": []}

        if not order:
            return {"status": "error",
                    "message": "leader produced no groups",
                    "summary": "", "results": []}

        try:
            on_disk = read_board(self.paths.board)
        except FileNotFoundError:
            return {"status": "error",
                    "message": "board missing after decompose",
                    "summary": "", "results": []}
        if not on_disk.status_rows:
            return {"status": "error",
                    "message": "board is empty after decompose; refusing to start",
                    "summary": "", "results": []}

        # 2. Build the runner
        runner = SequentialRunner(
            paths=self.paths, base_path=self.base_path,
            timeout_s=self.timeout_s, python=self.python,
            worker_entry=self.worker_entry,
            extra_args=self.worker_extra_args,
            extra_env=self.worker_extra_env, cwd=self.cwd,
        )

        # Resolve owner_models + dependencies from the freshly-built board.
        bf = read_board(self.paths.board)
        owner_models = {r.group: r.owner_model for r in bf.status_rows}
        deps_map = dict(bf.dependencies)
        # Prepare a mutable list of groups to run. We may insert retries.
        pending = list(order)
        results: List[WorkerResult] = []

        # 3. Sequential loop with hooks
        while pending:
            group = pending.pop(0)

            # Hard breaker: force leader compaction if board is over budget
            try:
                bf = read_board(self.paths.board)
                if bf.is_oversized(BOARD_HARD_LINES, BOARD_HARD_TOKENS):
                    logger.info("Board over hard budget — forcing compact_board")
                    self.leader.tools.execute("compact_board", {})
            except FileNotFoundError:
                logger.error("Board missing before %s; aborting", group)
                break

            # Spawn the worker
            from .runner import run_worker  # local import keeps mock-test isolation simple
            res = run_worker(
                group=group, paths=self.paths,
                owner_model=owner_models.get(group, ""),
                deps=deps_map.get(group, []),
                base_path=self.base_path,
                timeout_s=self.timeout_s, python=self.python,
                worker_entry=self.worker_entry,
                extra_args=self.worker_extra_args,
                extra_env=self.worker_extra_env, cwd=self.cwd,
            )
            results.append(res)

            if is_clean(res.final_status):
                continue

            if not is_failure(res.final_status):
                # Should not happen — non-clean, non-failure means RUNNING/PENDING.
                logger.warning("Group %s ended in non-terminal state %s; aborting",
                               group, res.final_status.value)
                break

            # Failure path — consult leader, but cap retries.
            attempts = self._retry_counts[group]
            if attempts >= self.max_retries:
                logger.warning(
                    "Retry cap reached for %s (%d/%d) — forcing skip_with_partial",
                    group, attempts, self.max_retries,
                )
                # Bypass the leader: directly record skip_with_partial.
                self.leader.tools.execute("decide_recovery", {
                    "failed_group": group, "decision": "skip_with_partial",
                    "reason": f"retry cap {self.max_retries} reached",
                })
                continue

            decision = self.leader.review_after(res)
            if decision == "abort":
                logger.info("Leader chose abort after %s failure", group)
                break

            # Did the leader's decision result in 'retry' or 'skip_with_partial'?
            # Inspect the LATEST recovery decision and act accordingly.
            decisions = self.leader.tools.recovery_decisions()
            last = decisions[-1] if decisions else None
            if last is not None and last.group == group and last.decision == "retry":
                self._retry_counts[group] += 1
                logger.info("Re-queuing %s (retry %d/%d)",
                            group, self._retry_counts[group], self.max_retries)
                pending.insert(0, group)
            # 'skip_with_partial' or unknown → just continue with the next group

        # 4. Finalize (compact + summary)
        summary = self.leader.finalize(self._compose_summary_hint(results))
        return {
            "status": "ok",
            "summary": summary,
            "results": [
                {
                    "group": r.group,
                    "status": r.final_status.value,
                    "exit_code": r.exit_code,
                    "duration_s": r.duration_s,
                    "timed_out": r.timed_out,
                }
                for r in results
            ],
        }

    # ------------------------------------------------------------------
    def _compose_summary_hint(self, results: List[WorkerResult]) -> str:
        if not results:
            return "Team Mode session: no groups ran."
        clean = sum(1 for r in results if is_clean(r.final_status))
        failed = sum(1 for r in results if is_failure(r.final_status))
        return (
            f"Team Mode session: {clean}/{len(results)} groups clean, "
            f"{failed} failed."
        )
