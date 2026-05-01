"""Worker status state machine.

Stamps live in two places (must stay in sync):
  - The status row in ``team_board.md``'s status table
  - The ``status:`` line at the top of the worker's section

Transitions:
    PENDING ──► RUNNING ──► DONE_CLEAN
                       ├──► DONE_WITH_WARNINGS
                       ├──► FAILED         (worker self-stamps)
                       └──► INTERRUPTED    (host stamps on crash/timeout)
"""
from __future__ import annotations

from enum import Enum


class Status(str, Enum):
    PENDING = "PENDING"
    RUNNING = "RUNNING"
    DONE_CLEAN = "DONE_CLEAN"
    DONE_WITH_WARNINGS = "DONE_WITH_WARNINGS"
    FAILED = "FAILED"
    INTERRUPTED = "INTERRUPTED"

    @classmethod
    def parse(cls, raw: str) -> "Status":
        """Lenient parse: unknown labels collapse to PENDING.

        We never want a malformed status string to crash the host —
        a sane default lets the leader recover.
        """
        if not raw:
            return cls.PENDING
        norm = str(raw).strip().upper().replace("-", "_").replace(" ", "_")
        for s in cls:
            if s.value == norm:
                return s
        return cls.PENDING


_TERMINAL = frozenset({
    Status.DONE_CLEAN,
    Status.DONE_WITH_WARNINGS,
    Status.FAILED,
    Status.INTERRUPTED,
})

_CLEAN = frozenset({
    Status.DONE_CLEAN,
    Status.DONE_WITH_WARNINGS,
})

_FAILURE = frozenset({
    Status.FAILED,
    Status.INTERRUPTED,
})


def is_terminal(s: Status) -> bool:
    """True if the worker has finished (cleanly or not) and won't update again."""
    return s in _TERMINAL


def is_clean(s: Status) -> bool:
    """True if the worker finished without giving up."""
    return s in _CLEAN


def is_failure(s: Status) -> bool:
    """True if the chain should consult the leader for recovery."""
    return s in _FAILURE
