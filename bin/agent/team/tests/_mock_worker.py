"""Mock worker used by runner tests.

Behavior is controlled by the ``MOCK_BEHAVIOR`` env var:
  - "clean"     → stamps DONE_CLEAN, exits 0
  - "warnings"  → stamps DONE_WITH_WARNINGS, exits 0
  - "fail"      → stamps FAILED, exits 1
  - "crash"     → exits 2 WITHOUT stamping (host should fill in INTERRUPTED)
  - "hang"      → sleeps long, never returns (timeout path)

Reads the same env contract a real worker uses: TEAM_BOARD_PATH,
TEAM_GROUP, TEAM_ARTIFACT_DIR, TEAM_OWNER_MODEL, TEAM_DEPS.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True

# Make sure the agent package on disk is importable when this runs as a
# subprocess. PYTHONPATH is normally set to bin/ by the test harness.
_THIS = Path(__file__).resolve()
_BIN = _THIS.parents[3]  # bin/
if str(_BIN) not in sys.path:
    sys.path.insert(0, str(_BIN))

from agent.team.artifact import Artifact, write_artifact  # noqa: E402
from agent.team.board import read_board, write_board  # noqa: E402
from agent.team.status import Status  # noqa: E402


def _stamp(board_path: Path, group: str, status: Status, log_line: str) -> None:
    bf = read_board(board_path)
    bf.set_status(group, status, last_step="1/1")
    section = bf.sections.get(group)
    if section is not None:
        section.log.append(log_line)
        if section.plan:
            section.plan[0].done = True
    write_board(board_path, bf)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--group", required=True)
    args = parser.parse_args()

    behavior = os.environ.get("MOCK_BEHAVIOR", "clean").strip().lower()
    board_path = Path(os.environ["TEAM_BOARD_PATH"])
    artifact_dir = Path(os.environ["TEAM_ARTIFACT_DIR"])
    owner_model = os.environ.get("TEAM_OWNER_MODEL", "mock")
    group = args.group

    # Mark RUNNING
    bf = read_board(board_path)
    bf.set_status(group, Status.RUNNING, last_step="0/1")
    write_board(board_path, bf)

    if behavior == "hang":
        time.sleep(30)
        return 0

    if behavior == "crash":
        # exit without stamping a terminal status
        return 2

    if behavior == "fail":
        _stamp(board_path, group, Status.FAILED, "mock failure")
        artifact = Artifact(
            group=group,
            producer_model=owner_model,
            status=Status.FAILED,
            summary="mock failure",
        )
        write_artifact(artifact_dir / f"{group}.json", artifact)
        return 1

    if behavior == "warnings":
        _stamp(board_path, group, Status.DONE_WITH_WARNINGS, "mock with warnings")
        artifact = Artifact(
            group=group,
            producer_model=owner_model,
            status=Status.DONE_WITH_WARNINGS,
            summary="mock ok with warnings",
            warnings=["stub warning"],
        )
        write_artifact(artifact_dir / f"{group}.json", artifact)
        return 0

    # default: clean
    _stamp(board_path, group, Status.DONE_CLEAN, "mock clean")
    artifact = Artifact(
        group=group,
        producer_model=owner_model,
        status=Status.DONE_CLEAN,
        summary="mock ok",
    )
    write_artifact(artifact_dir / f"{group}.json", artifact)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
