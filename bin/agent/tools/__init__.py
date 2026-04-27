"""Tool modules grouped by category. Each submodule defines a
``register(registry)`` function that adds its tools to a ToolRegistry.

Adding a new tool category is a two-step change:
  1. Create ``agent/tools/<name>.py`` exposing ``register(registry)``.
  2. Append it to the import list in :func:`collect_all_tools`.

The order in :func:`collect_all_tools` is also the order tools appear
in the system prompt — keep frequently-used categories near the top so
small models don't have to read past pages of git tools to find
read_file.
"""
from __future__ import annotations


def collect_all_tools(registry) -> None:
    """Populate ``registry.tools`` and ``registry.definitions`` in-place."""
    from . import fs_read, fs_write, shell, git, flutter
    fs_read.register(registry)
    fs_write.register(registry)
    shell.register(registry)
    git.register(registry)
    flutter.register(registry)
