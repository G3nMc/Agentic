"""Re-export shim: real implementation now lives in :mod:`common.tools.registry`.

Kept for backwards-compatibility with callers that import
``agent.tools.registry``. New code should import directly from
``common.tools.registry``.
"""

from __future__ import annotations

import sys as _sys

_sys.dont_write_bytecode = True

from common.tools.registry import *  # noqa: F401,F403
from common.tools import registry as _impl

def __getattr__(name):  # PEP 562
    return getattr(_impl, name)
