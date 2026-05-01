"""Soft circuit breaker — worker-side self-summarization.

When a worker's section grows past :data:`SECTION_SOFT_LINES` /
:data:`SECTION_SOFT_TOKENS`, it folds older log entries into a single
roll-up line. The plan checklist is preserved verbatim.

Producer-side artifact trimming lives in :class:`agent.team.artifact.Artifact`
already — this module is the section-side complement. Both are "soft"
because they're triggered by the producer at write-time; the host's
"hard" breaker (Phase 6) operates on the whole board.
"""
from __future__ import annotations

from typing import Optional, Tuple

from .board import (
    SECTION_SOFT_LINES,
    SECTION_SOFT_TOKENS,
    BoardFile,
    BoardSection,
    read_board,
    write_board,
)
from .paths import TeamPaths


def maybe_compact_section(
    paths: TeamPaths,
    group: str,
    *,
    keep_last: int = 5,
    max_lines: int = SECTION_SOFT_LINES,
    max_tokens: int = SECTION_SOFT_TOKENS,
    summary_line: Optional[str] = None,
) -> Tuple[bool, int]:
    """Compact ``group``'s section in place if oversized.

    Returns ``(compacted, rolled_count)``. ``compacted`` is True when a
    rewrite happened. ``rolled_count`` is the number of older log
    entries folded into the summary.

    Idempotent: if the section is already under budget, no-op.
    """
    try:
        bf = read_board(paths.board)
    except FileNotFoundError:
        return False, 0
    section = bf.sections.get(group)
    if section is None:
        return False, 0
    if not section.is_oversized(max_lines, max_tokens):
        return False, 0

    rolled = section.compact_log(keep_last=keep_last,
                                 summary_line=summary_line)
    bf.touch()
    write_board(paths.board, bf)
    return True, rolled
