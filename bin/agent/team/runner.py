"""Sequential worker runner.

The host process spawns one worker subprocess per group, in plan order,
and waits for each before launching the next. Responsibilities:

  * Build the subprocess argv + env (see :func:`build_worker_argv` and
    :func:`build_worker_env`).
  * Watch for non-zero exit, timeout, or missing terminal stamp →
    write ``INTERRUPTED`` into the board (because the worker can no
    longer stamp itself).
  * Pipe stdout/stderr to per-group log files so a crash is debuggable
    after the fact.
  * Optionally call a ``before_each`` hook so callers (the Workflow)
    can run leader compaction or recovery decisions between workers.

The runner is intentionally narrow: it does not know about the Leader
or the workflow loop. Phase 6 wires recovery on top of it.
"""
from __future__ import annotations

import logging
import os
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from .board import BoardFile, read_board, write_board
from .paths import TeamPaths
from .status import Status, is_terminal

logger = logging.getLogger(__name__)


DEFAULT_WORKER_TIMEOUT_S = 15 * 60


# ----------------------------------------------------------------------
# argv / env builders
# ----------------------------------------------------------------------
def build_worker_argv(
    group: str,
    *,
    python: Optional[str] = None,
    worker_entry: str = "agent.team.worker_entry",
    extra_args: Optional[List[str]] = None,
) -> List[str]:
    """argv for ``python -m agent.team.worker_entry --group <group>``."""
    py = python or sys.executable
    argv: List[str] = [py, "-B", "-m", worker_entry, "--group", group]
    if extra_args:
        argv.extend(extra_args)
    return argv


def build_worker_env(
    *,
    paths: TeamPaths,
    group: str,
    owner_model: str,
    deps: List[str],
    base_path: str,
    extra: Optional[Dict[str, str]] = None,
) -> Dict[str, str]:
    """Environment for a worker subprocess.

    Inherits the parent env (so API keys flow through) and overlays
    the team-mode contract variables.
    """
    env = dict(os.environ)
    env.update({
        "TEAM_BOARD_PATH": str(paths.board),
        "TEAM_ARTIFACT_DIR": str(paths.artifacts_dir),
        "TEAM_GROUP": group,
        "TEAM_OWNER_MODEL": owner_model,
        "TEAM_DEPS": ",".join(deps),
        "TEAM_BASE_PATH": str(base_path),
        "PYTHONDONTWRITEBYTECODE": "1",
    })
    if extra:
        env.update(extra)
    return env


# ----------------------------------------------------------------------
# Result of a single worker run
# ----------------------------------------------------------------------
@dataclass
class WorkerResult:
    group: str
    exit_code: int
    duration_s: float
    timed_out: bool
    final_status: Status
    stamped_by_host: bool = False
    notes: List[str] = field(default_factory=list)


# ----------------------------------------------------------------------
# Crash / interruption stamping
# ----------------------------------------------------------------------
def _stamp_interrupted(board_path: Path, group: str, reason: str) -> None:
    """Write INTERRUPTED into the board because the worker can no longer.

    Caller is the host process — it owns this responsibility because by
    definition the worker isn't around to do it.
    """
    try:
        bf = read_board(board_path)
    except FileNotFoundError:
        logger.error("Cannot stamp INTERRUPTED: board missing at %s", board_path)
        return
    bf.set_status(group, Status.INTERRUPTED)
    section = bf.sections.get(group)
    if section is not None:
        section.log.append(f"INTERRUPTED by host — {reason}")
    write_board(board_path, bf)


# ----------------------------------------------------------------------
# Sequential runner
# ----------------------------------------------------------------------
def run_worker(
    *,
    group: str,
    paths: TeamPaths,
    owner_model: str,
    deps: List[str],
    base_path: str,
    timeout_s: float = DEFAULT_WORKER_TIMEOUT_S,
    python: Optional[str] = None,
    worker_entry: str = "agent.team.worker_entry",
    extra_args: Optional[List[str]] = None,
    extra_env: Optional[Dict[str, str]] = None,
    cwd: Optional[str] = None,
) -> WorkerResult:
    """Spawn one worker subprocess and wait for it.

    On clean exit the worker is expected to have already stamped a
    terminal status into the board. If the section status is non-terminal
    when we return (process died, timed out, or exited 0 without
    stamping), the host writes ``INTERRUPTED``.
    """
    paths.ensure_dirs()
    argv = build_worker_argv(
        group, python=python,
        worker_entry=worker_entry, extra_args=extra_args,
    )
    env = build_worker_env(
        paths=paths, group=group, owner_model=owner_model,
        deps=deps, base_path=base_path, extra=extra_env,
    )

    stdout_path = paths.worker_stdout(group)
    stderr_path = paths.worker_stderr(group)
    started = time.monotonic()

    logger.info("Spawning worker | group=%s argv=%s timeout=%.0fs",
                group, argv, timeout_s)

    notes: List[str] = []
    timed_out = False
    exit_code = -1

    with open(stdout_path, "w", encoding="utf-8") as out_f, \
            open(stderr_path, "w", encoding="utf-8") as err_f:
        try:
            proc = subprocess.Popen(
                argv, env=env, cwd=cwd,
                stdout=out_f, stderr=err_f,
                stdin=subprocess.DEVNULL,
            )
        except Exception as e:
            duration = time.monotonic() - started
            logger.exception("Worker spawn failed | group=%s: %s", group, e)
            _stamp_interrupted(paths.board, group, f"spawn failed: {e}")
            return WorkerResult(
                group=group, exit_code=-1, duration_s=duration,
                timed_out=False, final_status=Status.INTERRUPTED,
                stamped_by_host=True, notes=[f"spawn-failed: {e}"],
            )

        try:
            exit_code = proc.wait(timeout=timeout_s)
        except subprocess.TimeoutExpired:
            timed_out = True
            notes.append(f"timeout after {timeout_s:.0f}s")
            logger.warning("Worker timed out | group=%s", group)
            try:
                proc.kill()
                proc.wait(timeout=10)
            except Exception:
                pass
            exit_code = proc.returncode if proc.returncode is not None else -9

    duration = time.monotonic() - started

    # Inspect the board to see what status the worker (or its absence)
    # left behind.
    try:
        bf = read_board(paths.board)
    except FileNotFoundError:
        # No board at all — this is a serious bug, but recover gracefully.
        logger.error("Board missing after worker exit | group=%s", group)
        return WorkerResult(
            group=group, exit_code=exit_code, duration_s=duration,
            timed_out=timed_out, final_status=Status.INTERRUPTED,
            stamped_by_host=True,
            notes=notes + ["board-missing-after-exit"],
        )

    row = bf.find_row(group)
    current = row.status if row is not None else Status.PENDING

    stamped_by_host = False
    if not is_terminal(current):
        reason = "timeout" if timed_out else f"exit={exit_code} no terminal stamp"
        _stamp_interrupted(paths.board, group, reason)
        current = Status.INTERRUPTED
        stamped_by_host = True
        notes.append(f"host-stamped-interrupted: {reason}")

    return WorkerResult(
        group=group, exit_code=exit_code, duration_s=duration,
        timed_out=timed_out, final_status=current,
        stamped_by_host=stamped_by_host, notes=notes,
    )


@dataclass
class SequentialRunner:
    """Drive a sequence of groups end-to-end.

    The runner owns the per-group subprocess lifecycle. Recovery
    decisions are delegated to ``before_each`` and ``on_failure``
    hooks so this module stays decoupled from the leader.
    """
    paths: TeamPaths
    base_path: str
    timeout_s: float = DEFAULT_WORKER_TIMEOUT_S
    python: Optional[str] = None
    worker_entry: str = "agent.team.worker_entry"
    extra_args: Optional[List[str]] = None
    extra_env: Optional[Dict[str, str]] = None
    cwd: Optional[str] = None

    def run_all(
        self,
        groups: List[str],
        owner_models: Dict[str, str],
        dependencies: Dict[str, List[str]],
        *,
        before_each: Optional[Callable[[str, BoardFile], None]] = None,
        on_failure: Optional[Callable[[WorkerResult, BoardFile], str]] = None,
    ) -> List[WorkerResult]:
        """Run ``groups`` in order. ``on_failure`` returns 'continue' or 'abort'."""
        results: List[WorkerResult] = []
        for group in groups:
            try:
                bf = read_board(self.paths.board)
            except FileNotFoundError:
                logger.error("Cannot run %s: board missing", group)
                break
            if before_each is not None:
                try:
                    before_each(group, bf)
                except Exception as e:
                    logger.exception("before_each hook failed for %s: %s", group, e)

            res = run_worker(
                group=group,
                paths=self.paths,
                owner_model=owner_models.get(group, ""),
                deps=dependencies.get(group, []),
                base_path=self.base_path,
                timeout_s=self.timeout_s,
                python=self.python,
                worker_entry=self.worker_entry,
                extra_args=self.extra_args,
                extra_env=self.extra_env,
                cwd=self.cwd,
            )
            results.append(res)

            if res.final_status in (Status.FAILED, Status.INTERRUPTED):
                if on_failure is None:
                    logger.warning("Worker %s ended %s; aborting (no recovery hook)",
                                   group, res.final_status.value)
                    break
                try:
                    bf = read_board(self.paths.board)
                except FileNotFoundError:
                    break
                decision = on_failure(res, bf) or "abort"
                logger.info("Recovery decision for %s: %s", group, decision)
                if decision == "abort":
                    break
                # 'continue' / 'skip_with_partial' / etc. — the hook is
                # expected to have already mutated the board (e.g.
                # marked the group as skipped) before returning.
        return results
