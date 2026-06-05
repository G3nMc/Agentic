"""Tool registry and executor for the agent workflow."""

from __future__ import annotations

import abc
import json
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional

from .state import ToolCall, ToolResult


class Tool(abc.ABC):
    """Abstract base class for a tool that can be called by the agent.

    Each tool must define:
    - name: Unique identifier
    - description: Human-readable description for the LLM
    - parameters: JSON Schema for the tool's arguments
    - execute: The actual implementation
    """

    name: str
    description: str
    parameters: Dict[str, Any]

    @abc.abstractmethod
    def execute(self, arguments: Dict[str, Any]) -> Any:
        """Execute the tool with the given arguments.

        Args:
            arguments: The arguments matching the tool's JSON Schema.

        Returns:
            The result of the tool execution (JSON-serializable).

        Raises:
            Exception: On execution failure.
        """
        ...

    def to_openai_tool(self) -> Dict[str, Any]:
        """Convert to OpenAI function-calling format."""
        return {
            "type": "function",
            "function": {
                "name": self.name,
                "description": self.description,
                "parameters": self.parameters,
            },
        }


class FunctionTool(Tool):
    """A tool backed by a simple callable function."""

    def __init__(
        self,
        name: str,
        description: str,
        parameters: Dict[str, Any],
        func: Callable[..., Any],
    ):
        self.name = name
        self.description = description
        self.parameters = parameters
        self._func = func

    def execute(self, arguments: Dict[str, Any]) -> Any:
        return self._func(**arguments)


class ToolRegistry:
    """Registry of available tools."""

    def __init__(self) -> None:
        self._tools: Dict[str, Tool] = {}

    def register(self, tool: Tool) -> None:
        """Register a tool."""
        if tool.name in self._tools:
            raise ValueError(f"Tool '{tool.name}' is already registered")
        self._tools[tool.name] = tool

    def unregister(self, name: str) -> None:
        """Remove a tool from the registry."""
        self._tools.pop(name, None)

    def get(self, name: str) -> Optional[Tool]:
        """Get a tool by name."""
        return self._tools.get(name)

    def list_tools(self) -> List[str]:
        """List all registered tool names."""
        return list(self._tools.keys())

    def to_openai_tools(self) -> List[Dict[str, Any]]:
        """Convert all registered tools to OpenAI format."""
        return [tool.to_openai_tool() for tool in self._tools.values()]


class ToolExecutor:
    """Executes tool calls with validation and parallel execution support."""

    def __init__(
        self,
        registry: ToolRegistry,
        timeout_seconds: float = 30.0,
        parallel: bool = True,
    ):
        self.registry = registry
        self.timeout_seconds = timeout_seconds
        self.parallel = parallel

    def execute(self, tool_call: ToolCall) -> ToolResult:
        """Execute a single tool call.

        Args:
            tool_call: The tool call to execute.

        Returns:
            ToolResult with success/error and timing.
        """
        tool = self.registry.get(tool_call.name)
        if tool is None:
            return ToolResult(
                tool_call_id=tool_call.id,
                name=tool_call.name,
                success=False,
                error=f"Unknown tool: {tool_call.name}",
            )

        start = time.time()
        try:
            result = tool.execute(tool_call.arguments)
            duration_ms = (time.time() - start) * 1000
            return ToolResult(
                tool_call_id=tool_call.id,
                name=tool_call.name,
                success=True,
                result=result,
                duration_ms=duration_ms,
            )
        except Exception as e:
            duration_ms = (time.time() - start) * 1000
            return ToolResult(
                tool_call_id=tool_call.id,
                name=tool_call.name,
                success=False,
                error=str(e),
                duration_ms=duration_ms,
            )

    def execute_batch(self, tool_calls: List[ToolCall]) -> List[ToolResult]:
        """Execute multiple tool calls, optionally in parallel.

        Args:
            tool_calls: List of tool calls to execute.

        Returns:
            List of ToolResults in the same order as tool_calls.
        """
        if not tool_calls:
            return []

        if not self.parallel or len(tool_calls) == 1:
            return [self.execute(tc) for tc in tool_calls]

        # Parallel execution
        results: Dict[int, ToolResult] = {}
        with ThreadPoolExecutor(max_workers=min(len(tool_calls), 10)) as executor:
            future_to_index = {
                executor.submit(self.execute, tc): i
                for i, tc in enumerate(tool_calls)
            }
            for future in as_completed(future_to_index):
                index = future_to_index[future]
                try:
                    results[index] = future.result(timeout=self.timeout_seconds)
                except Exception as e:
                    results[index] = ToolResult(
                        tool_call_id=tool_calls[index].id,
                        name=tool_calls[index].name,
                        success=False,
                        error=f"Execution timeout or error: {e}",
                    )

        return [results[i] for i in range(len(tool_calls))]


# ---------------------------------------------------------------------------
# Built-in tool definitions
# ---------------------------------------------------------------------------


def _create_read_file_tool() -> Tool:
    """Create the read_file tool."""

    def execute(path: str, start_line: Optional[int] = None, end_line: Optional[int] = None) -> str:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
        if start_line is not None and end_line is not None:
            lines = lines[start_line - 1 : end_line]
        elif start_line is not None:
            lines = lines[start_line - 1 :]
        return "".join(lines)

    return FunctionTool(
        name="read_file",
        description="Read a file from the local filesystem.",
        parameters={
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Path to the file"},
                "start_line": {
                    "type": "integer",
                    "description": "Optional start line (1-indexed)",
                },
                "end_line": {
                    "type": "integer",
                    "description": "Optional end line (1-indexed, inclusive)",
                },
            },
            "required": ["path"],
        },
        func=execute,
    )


def _create_write_file_tool() -> Tool:
    """Create the write_file tool."""

    def execute(path: str, content: str) -> str:
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        return f"File written: {path}"

    return FunctionTool(
        name="write_file",
        description="Write content to a file (creates or overwrites).",
        parameters={
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Path to the file"},
                "content": {"type": "string", "description": "Content to write"},
            },
            "required": ["path", "content"],
        },
        func=execute,
    )


def _create_patch_file_tool() -> Tool:
    """Create the patch_file tool."""

    def execute(path: str, old_content: str, new_content: str) -> str:
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
        if old_content not in content:
            return f"Error: old_content not found in {path}"
        content = content.replace(old_content, new_content, 1)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        return f"File patched: {path}"

    return FunctionTool(
        name="patch_file",
        description="Replace the first occurrence of old_content with new_content in a file.",
        parameters={
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Path to the file"},
                "old_content": {
                    "type": "string",
                    "description": "Exact content to replace",
                },
                "new_content": {
                    "type": "string",
                    "description": "New content to insert",
                },
            },
            "required": ["path", "old_content", "new_content"],
        },
        func=execute,
    )


def _create_search_in_files_tool() -> Tool:
    """Create the search_in_files tool."""

    def execute(pattern: str, path: str = ".", file_glob: Optional[str] = None) -> str:
        import fnmatch
        import os
        import re

        results = []
        regex = re.compile(pattern)
        for root, dirs, files in os.walk(path):
            # Skip hidden directories
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            for file in files:
                if file_glob and not fnmatch.fnmatch(file, file_glob):
                    continue
                filepath = os.path.join(root, file)
                try:
                    with open(filepath, "r", encoding="utf-8") as f:
                        for i, line in enumerate(f, 1):
                            if regex.search(line):
                                results.append(f"{filepath}:{i}: {line.rstrip()}")
                except Exception:
                    pass
        return "\n".join(results[:500]) if results else "No matches found"

    return FunctionTool(
        name="search_in_files",
        description="Search for a regex pattern in files.",
        parameters={
            "type": "object",
            "properties": {
                "pattern": {"type": "string", "description": "Regex pattern to search for"},
                "path": {
                    "type": "string",
                    "description": "Directory to search in (default: current)",
                },
                "file_glob": {
                    "type": "string",
                    "description": "Optional file glob pattern (e.g., '*.py')",
                },
            },
            "required": ["pattern"],
        },
        func=execute,
    )


def _create_list_files_tool() -> Tool:
    """Create the list_files tool."""

    def execute(path: str = ".") -> str:
        import os

        entries = []
        for entry in sorted(os.listdir(path)):
            full = os.path.join(path, entry)
            suffix = "/" if os.path.isdir(full) else ""
            entries.append(f"{entry}{suffix}")
        return "\n".join(entries) if entries else "Empty directory"

    return FunctionTool(
        name="list_files",
        description="List files and directories in a given path.",
        parameters={
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Directory path (default: current)",
                },
            },
        },
        func=execute,
    )


def _create_run_command_tool() -> Tool:
    """Create the run_command tool."""

    def execute(command: str) -> str:
        import subprocess

        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        output = result.stdout
        if result.stderr:
            output += "\n[STDERR]\n" + result.stderr
        return output.strip() or "(no output)"

    return FunctionTool(
        name="run_command",
        description="Run a shell command.",
        parameters={
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "Shell command to execute"},
            },
            "required": ["command"],
        },
        func=execute,
    )


def _create_flutter_analyze_tool() -> Tool:
    """Create the flutter_analyze tool."""

    def execute(path: str = ".") -> str:
        import subprocess

        result = subprocess.run(
            ["flutter", "analyze", path],
            capture_output=True,
            text=True,
            timeout=120,
        )
        return result.stdout + result.stderr

    return FunctionTool(
        name="flutter_analyze",
        description="Run Flutter static analysis.",
        parameters={
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Path to analyze (default: current)",
                },
            },
        },
        func=execute,
    )


def _create_python_check_tool() -> Tool:
    """Create the python_check tool."""

    def execute(path: str = ".") -> str:
        import subprocess

        result = subprocess.run(
            ["python", "-m", "py_compile", path],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode == 0:
            return "Python syntax check passed"
        return result.stderr or "Syntax check failed"

    return FunctionTool(
        name="python_check",
        description="Check Python syntax.",
        parameters={
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Path to check (default: current)",
                },
            },
        },
        func=execute,
    )


def create_default_registry() -> ToolRegistry:
    """Create a ToolRegistry with all built-in tools."""
    registry = ToolRegistry()
    for tool_factory in [
        _create_read_file_tool,
        _create_write_file_tool,
        _create_patch_file_tool,
        _create_search_in_files_tool,
        _create_list_files_tool,
        _create_run_command_tool,
        _create_flutter_analyze_tool,
        _create_python_check_tool,
    ]:
        registry.register(tool_factory())
    return registry
