"""Re-export shim: real implementation now lives in :mod:`common.path_filter`.

Kept for backwards-compatibility with callers that import
``multi_mode.path_filter``. New code should import directly from
``common.path_filter``.
"""

from __future__ import annotations

import sys as _sys

from bin.common.path_filter import *

_sys.dont_write_bytecode = True

__all__ = ["PathFilter"]
