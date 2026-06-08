"""Re-export shim: real implementation now lives in :mod:`common.loop.tool_dispatch`.

Kept for backwards-compatibility with callers that import
``multi_mode.loop.tool_dispatch``. New code should import directly from
``common.loop.tool_dispatch``.
"""

from __future__ import annotations
import sys as _sys

_sys.dont_write_bytecode = True

import bin.common.loop.tool_dispatch as _impl


def __getattr__(name):
    return getattr(_impl, name)
