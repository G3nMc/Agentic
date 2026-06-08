"""Agent-side tool wiring — re-exports the shared registry assembly from
:mod:`common.tools`. Kept for backwards-compatibility with callers that
import ``agent.tools``.
"""

from __future__ import annotations

import sys as _sys

_sys.dont_write_bytecode = True

from common.tools import collect_all_tools  # noqa: F401

__all__ = ["collect_all_tools"]
