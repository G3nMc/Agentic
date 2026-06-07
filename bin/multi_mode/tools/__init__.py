"""Tool system: registry, executor, and built-in tools."""

from multi_mode.tools.base import Tool, ToolResult
from multi_mode.tools.registry import ToolRegistry, get_tool_registry, register_tool
from multi_mode.tools.builtin import register_builtin_tools
from multi_mode.tools.executor import ToolExecutor


def collect_all_tools(registry) -> None:
    """Populate ``registry.tools`` and ``registry.definitions`` in-place."""
    from . import fs_read, fs_write, shell, git, flutter, python_tools, database, web

    fs_read.register(registry)
    fs_write.register(registry)
    shell.register(registry)
    git.register(registry)
    flutter.register(registry)
    python_tools.register(registry)
    database.register(registry)
    web.register(registry)


__all__ = [
    "Tool",
    "ToolResult",
    "ToolRegistry",
    "get_tool_registry",
    "register_tool",
    "register_builtin_tools",
    "ToolExecutor",
    "collect_all_tools",
]
