"""Team Mode — sequential, leader-orchestrated workflow groups.

A heavy task is split into named groups. A team-leader model decomposes
the work; each group runs in its own subprocess (fresh model context)
and writes a structured handoff artifact. A single shared
``team_board.md`` tracks state.

Design contract is frozen in the per-module docstrings here:
    status.py    — worker status state machine
    artifact.py  — handoff JSON schema
    board.py     — team_board.md format + section read/write
    paths.py     — on-disk layout
"""

import sys as _sys

_sys.dont_write_bytecode = True

from .status import (
    Status,
    is_terminal,
    is_clean,
    is_failure,
)
from .artifact import (
    Artifact,
    ARTIFACT_SCHEMA_VERSION,
    ARTIFACT_MAX_BYTES,
)
from .board import (
    BoardFile,
    BoardSection,
    StatusRow,
    PlanStep,
    SECTION_SOFT_LINES,
    SECTION_SOFT_TOKENS,
    BOARD_HARD_LINES,
    BOARD_HARD_TOKENS,
)
from .paths import TeamPaths, delete_session, session_dir_for

__all__ = [
    "Status",
    "is_terminal",
    "is_clean",
    "is_failure",
    "Artifact",
    "ARTIFACT_SCHEMA_VERSION",
    "ARTIFACT_MAX_BYTES",
    "BoardFile",
    "BoardSection",
    "StatusRow",
    "PlanStep",
    "SECTION_SOFT_LINES",
    "SECTION_SOFT_TOKENS",
    "BOARD_HARD_LINES",
    "BOARD_HARD_TOKENS",
    "TeamPaths",
    "delete_session",
    "session_dir_for",
]
