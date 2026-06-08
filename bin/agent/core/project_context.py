"""Re-export shim: real implementation now lives in :mod:`common.core.project_context`.

Kept for backwards-compatibility with callers that import
``agent.core.project_context``. New code should import directly from
``common.core.project_context``.
"""

from __future__ import annotations

import sys as _sys

_sys.dont_write_bytecode = True

from common.core.project_context import *  # noqa: F401,F403
from common.core import project_context as _impl


def __getattr__(name):  # PEP 562
    return getattr(_impl, name)
