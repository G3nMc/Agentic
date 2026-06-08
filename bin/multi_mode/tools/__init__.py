"""Multi-mode tool system: lightweight registry, executor, and built-ins.

Note: this is a SEPARATE tool stack from :mod:`common.tools`. The
multi_mode workflow uses its own Tool/ToolRegistry/ToolExecutor
abstraction (see :mod:`multi_mode.tools.base`) — distinct API from the
richer agent-side stack in :mod:`common.tools.registry` (used by the
single-agent orchestrator). Tool implementations are registered via
:func:`multi_mode.tools.builtin.register_builtin_tools`.
"""

from bin.multi_mode import ToolResult
from bin.multi_mode.tools.base import Tool
from bin.multi_mode.tools.builtin import register_builtin_tools
from bin.multi_mode.tools.executor import ToolExecutor
from bin.multi_mode.tools.registry import ToolRegistry, get_tool_registry, register_tool

__all__ = [
    "Tool",
    "ToolResult",
    "ToolRegistry",
    "get_tool_registry",
    "register_tool",
    "register_builtin_tools",
    "ToolExecutor",
]
