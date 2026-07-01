"""Common tools package — shared tool implementations and registry.

Each tool submodule (fs_read, fs_write, shell, git, flutter,
python_tools, database, web) exposes a ``register(registry)`` callable
that adds its tools to a :class:`common.tools.registry.ToolRegistry`.

``collect_all_tools`` wires them all into a registry in the canonical
order (filesystem first, validation/web last). The order matters
because it controls how tools appear in the system prompt — small
models scan top-down.
"""

from __future__ import annotations

import sys as _sys

_sys.dont_write_bytecode = True


def collect_all_tools(registry) -> None:
    """Populate ``registry.tools`` and ``registry.definitions`` in-place."""
    from . import (
        fs_read,
        fs_write,
        shell,
        git,
        flutter,
        python_tools,
        database,
        web,
    )

    fs_read.register(registry)
    fs_write.register(registry)
    shell.register(registry)
    git.register(registry)
    flutter.register(registry)
    python_tools.register(registry)
    database.register(registry)
    web.register(registry)


__all__ = ["collect_all_tools"]
