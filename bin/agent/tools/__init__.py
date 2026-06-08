"""Agent-side tool wiring — re-exports the shared registry assembly from
:mod:`common.tools`. Kept for backwards-compatibility with callers that
import ``agent.tools``.
"""

from __future__ import annotations

import sys as _sys

_sys.dont_write_bytecode = True

from bin.common.tools import collect_all_tools

__all__ = ["collect_all_tools"]
