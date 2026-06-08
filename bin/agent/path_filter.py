"""Re-export shim: real implementation now lives in :mod:`common.path_filter`.

Kept for backwards-compatibility with callers that import
``agent.path_filter``. New code should import directly from
``common.path_filter``.
"""

from __future__ import annotations

import sys as _sys
_sys.dont_write_bytecode = True


from bin.common.path_filter import PathFilter




__all__ = ["PathFilter"]
