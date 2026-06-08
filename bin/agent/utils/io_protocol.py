"""Re-export shim: real implementation now lives in :mod:`common.utils.io_protocol`.

Kept for backwards-compatibility with callers that import
``agent.utils.io_protocol``. New code should import directly from
``common.utils.io_protocol``.
"""

from __future__ import annotations

import sys as _sys

_sys.dont_write_bytecode = True

from common.utils.io_protocol import (  # noqa: F401
    RESPONSE_SENTINEL,
    configure_stdio_utf8,
    read_interactive_request,
)

__all__ = ["RESPONSE_SENTINEL", "configure_stdio_utf8", "read_interactive_request"]
