"""Re-export shim: real implementation now lives in :mod:`common.loop.tool_dispatch`.

Kept for backwards-compatibility with callers that import
``agent.loop.tool_dispatch``. New code should import directly from
``common.loop.tool_dispatch``.
"""

from __future__ import annotations

import sys as _sys

_sys.dont_write_bytecode = True

# Re-export everything from the canonical module.
import bin.common.loop.tool_dispatch as _impl


def __getattr__(name):  # PEP 562 module-level __getattr__
    return getattr(_impl, name)
