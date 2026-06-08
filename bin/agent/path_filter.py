"""Re-export shim: real implementation now lives in :mod:`common.path_filter`.

Kept for backwards-compatibility with callers that import
``agent.path_filter``. New code should import directly from
``common.path_filter``.
"""

from __future__ import annotations

import sys as _sys

_sys.dont_write_bytecode = True

from common.path_filter import (  # noqa: F401
    PathFilter,
    _BASELINE_EXCLUDE_DIRS,
    _fix_missing_dot,
    _is_absolute,
    _is_ext_glob,
    _looks_like_ext_glob_loose,
    _normalize_abs,
    _normalize_user_filter_entries,
)

__all__ = ["PathFilter"]
