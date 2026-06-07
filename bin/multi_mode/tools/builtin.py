"""Built-in tools for filesystem, search, and execution."""

import os
import json
import subprocess
from pathlib import Path
from typing import Dict, Any, List, Optional

from multi_mode.core.tool_schema import ToolSchema, ParameterSchema
from multi_mode.tools.base import Tool, ToolResult
from multi_mode.tools.registry import ToolRegistry


class ReadFileTool(Tool):
    name = "read_file"
    description = "Read a file from the filesystem"
    schema = ToolSchema(
        name="read_file",
        description="Read a file from the filesystem",
        parameters=ParameterSchema(
            type="object",
            properties={
                "path": ParameterSchema(type="string", description="Path to the file"),
                "start_line": ParameterSchema(type="integer", description="Start line (1-indexed)"),
                "end_line": ParameterSchema(type="integer", description="End line (1-indexed)"),
                "offset": ParameterSchema(type="integer", description="Byte offset"),
                "limit": ParameterSchema(type="integer", description="Max bytes to read"),
            },
            required=["path"],
        ),
    )
    
    def execute(self, arguments: Dict[str, Any]) -> ToolResult:
        path = arguments["path"]
        start_line = arguments.get("start_line")
        end_line = arguments.get("end_line")
        offset = arguments.get("offset")
        limit = arguments.get("limit")
        
        try:
            full_path = Path(path)
            if not full_path.exists():
                return ToolResult(
                    tool_call_id=arguments.get("tool_call_id", ""),
                    name=self.name,
                    content="",
                    error=f"File not found: {path}",
                )
            
            content = full_path.read_text(encoding="utf-8")
            lines = content.splitlines()
            
            if start_line is not None and end_line is not None:
                start = max(0, start_line - 1)
                end = min(len(lines), end_line)
                content = "\n".join(lines[start:end])
            elif offset is not None and limit is not None:
                content = content[offset:offset+limit]
            
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content=content,
                metadata={"line_count": len(lines), "path": str(full_path)},
            )
        except Exception as e:
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content="",
                error=str(e),
            )


class WriteFileTool(Tool):
    name = "write_file"
    description = "Write content to a file"
    schema = ToolSchema(
        name="write_file",
        description="Write content to a file",
        parameters=ParameterSchema(
            type="object",
            properties={
                "path": ParameterSchema(type="string", description="Path to the file"),
                "content": ParameterSchema(type="string", description="Content to write"),
            },
            required=["path", "content"],
        ),
    )
    
    def execute(self, arguments: Dict[str, Any]) -> ToolResult:
        path = arguments["path"]
        content = arguments["content"]
        
        try:
            full_path = Path(path)
            full_path.parent.mkdir(parents=True, exist_ok=True)
            full_path.write_text(content, encoding="utf-8")
            
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content=f"File written: {path}",
                metadata={"path": str(full_path), "bytes": len(content)},
            )
        except Exception as e:
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content="",
                error=str(e),
            )


class PatchFileTool(Tool):
    name = "patch_file"
    description = "Patch a file by replacing old content with new content"
    schema = ToolSchema(
        name="patch_file",
        description="Patch a file by replacing old content with new content",
        parameters=ParameterSchema(
            type="object",
            properties={
                "path": ParameterSchema(type="string", description="Path to the file"),
                "old_content": ParameterSchema(type="string", description="Content to replace"),
                "new_content": ParameterSchema(type="string", description="New content"),
            },
            required=["path", "old_content", "new_content"],
        ),
    )
    
    def execute(self, arguments: Dict[str, Any]) -> ToolResult:
        path = arguments["path"]
        old_content = arguments["old_content"]
        new_content = arguments["new_content"]
        
        try:
            full_path = Path(path)
            if not full_path.exists():
                return ToolResult(
                    tool_call_id=arguments.get("tool_call_id", ""),
                    name=self.name,
                    content="",
                    error=f"File not found: {path}",
                )
            
            content = full_path.read_text(encoding="utf-8")
            
            if old_content not in content:
                return ToolResult(
                    tool_call_id=arguments.get("tool_call_id", ""),
                    name=self.name,
                    content="",
                    error=f"Old content not found in file: {path}",
                )
            
            new_file_content = content.replace(old_content, new_content, 1)
            full_path.write_text(new_file_content, encoding="utf-8")
            
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content=f"File patched: {path}",
                metadata={"path": str(full_path)},
            )
        except Exception as e:
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content="",
                error=str(e),
            )


class SearchInFilesTool(Tool):
    name = "search_in_files"
    description = "Search for a pattern in files"
    schema = ToolSchema(
        name="search_in_files",
        description="Search for a pattern in files",
        parameters=ParameterSchema(
            type="object",
            properties={
                "pattern": ParameterSchema(type="string", description="Regex pattern to search"),
                "path": ParameterSchema(type="string", description="Directory to search"),
                "file_glob": ParameterSchema(type="string", description="File glob pattern"),
            },
            required=["pattern"],
        ),
    )
    
    def execute(self, arguments: Dict[str, Any]) -> ToolResult:
        pattern = arguments["pattern"]
        path = arguments.get("path", ".")
        file_glob = arguments.get("file_glob", "**/*")
        
        try:
            import re
            from pathlib import Path
            
            root = Path(path)
            matches = []
            
            for file_path in root.rglob(file_glob):
                if file_path.is_file():
                    try:
                        content = file_path.read_text(encoding="utf-8")
                        for i, line in enumerate(content.splitlines(), 1):
                            if re.search(pattern, line):
                                matches.append({
                                    "file": str(file_path),
                                    "line": i,
                                    "content": line.strip(),
                                })
                    except Exception:
                        continue
            
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content=json.dumps(matches, indent=2),
                metadata={"match_count": len(matches)},
            )
        except Exception as e:
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content="",
                error=str(e),
            )


class ListFilesTool(Tool):
    name = "list_files"
    description = "List files in a directory"
    schema = ToolSchema(
        name="list_files",
        description="List files in a directory",
        parameters=ParameterSchema(
            type="object",
            properties={
                "path": ParameterSchema(type="string", description="Directory path"),
            },
            required=["path"],
        ),
    )
    
    def execute(self, arguments: Dict[str, Any]) -> ToolResult:
        path = arguments["path"]
        
        try:
            from pathlib import Path
            root = Path(path)
            files = []
            
            for item in root.iterdir():
                files.append({
                    "name": item.name,
                    "type": "directory" if item.is_dir() else "file",
                    "size": item.stat().st_size if item.is_file() else None,
                })
            
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content=json.dumps(files, indent=2),
                metadata={"count": len(files)},
            )
        except Exception as e:
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content="",
                error=str(e),
            )


class RunCommandTool(Tool):
    name = "run_command"
    description = "Run a shell command"
    schema = ToolSchema(
        name="run_command",
        description="Run a shell command",
        parameters=ParameterSchema(
            type="object",
            properties={
                "command": ParameterSchema(type="string", description="Command to run"),
                "cwd": ParameterSchema(type="string", description="Working directory"),
                "timeout": ParameterSchema(type="integer", description="Timeout in seconds"),
            },
            required=["command"],
        ),
    )
    
    def execute(self, arguments: Dict[str, Any]) -> ToolResult:
        command = arguments["command"]
        cwd = arguments.get("cwd", ".")
        timeout = arguments.get("timeout", 30)
        
        try:
            result = subprocess.run(
                command,
                shell=True,
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            
            output = result.stdout
            if result.stderr:
                output += f"\nSTDERR: {result.stderr}"
            
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content=output,
                error=result.stderr if result.returncode != 0 else None,
                metadata={"return_code": result.return_code},
            )
        except subprocess.TimeoutExpired:
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content="",
                error=f"Command timed out after {timeout}s",
            )
        except Exception as e:
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content="",
                error=str(e),
            )


class FlutterAnalyzeTool(Tool):
    name = "flutter_analyze"
    description = "Run flutter analyze on the project"
    schema = ToolSchema(
        name="flutter_analyze",
        description="Run flutter analyze on the project",
        parameters=ParameterSchema(
            type="object",
            properties={
                "path": ParameterSchema(type="string", description="Path to analyze"),
                "timeout": ParameterSchema(type="integer", description="Timeout in seconds"),
            },
            required=[],
        ),
    )
    
    def execute(self, arguments: Dict[str, Any]) -> ToolResult:
        path = arguments.get("path", ".")
        timeout = arguments.get("timeout", 60)
        
        try:
            result = subprocess.run(
                ["flutter", "analyze", path],
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            
            output = result.stdout
            if result.stderr:
                output += f"\nSTDERR: {result.stderr}"
            
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content=output,
                error=result.stderr if result.returncode != 0 else None,
                metadata={"return_code": result.return_code},
            )
        except subprocess.TimeoutExpired:
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content="",
                error=f"Flutter analyze timed out after {timeout}s",
            )
        except Exception as e:
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content="",
                error=str(e),
            )


class PythonCheckTool(Tool):
    name = "python_check"
    description = "Run python syntax check on the project"
    schema = ToolSchema(
        name="python_check",
        description="Run python syntax check on the project",
        parameters=ParameterSchema(
            type="object",
            properties={
                "path": ParameterSchema(type="string", description="Path to check"),
                "max_files": ParameterSchema(type="integer", description="Max files to check"),
            },
            required=[],
        ),
    )
    
    def execute(self, arguments: Dict[str, Any]) -> ToolResult:
        path = arguments.get("path", ".")
        max_files = arguments.get("max_files", 100)
        
        try:
            import py_compile
            from pathlib import Path
            
            root = Path(path)
            errors = []
            checked = 0
            
            for py_file in root.rglob("*.py"):
                if checked >= max_files:
                    break
                try:
                    py_compile.compile(str(py_file), doraise=True)
                except py_compile.PyCompileError as e:
                    errors.append(f"{py_file}: {e}")
                checked += 1
            
            if errors:
                return ToolResult(
                    tool_call_id=arguments.get("tool_call_id", ""),
                    name=self.name,
                    content="\n".join(errors),
                    error="Syntax errors found",
                    metadata={"error_count": len(errors), "checked": checked},
                )
            else:
                return ToolResult(
                    tool_call_id=arguments.get("tool_call_id", ""),
                    name=self.name,
                    content=f"All {checked} Python files passed syntax check",
                    metadata={"checked": checked},
                )
        except Exception as e:
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content="",
                error=str(e),
            )


class ListFilesRecursiveTool(Tool):
    name = "list_files_recursive"
    description = "Recursively list files in a directory tree"
    schema = ToolSchema(
        name="list_files_recursive",
        description="Recursively list files in a directory tree",
        parameters=ParameterSchema(
            type="object",
            properties={
                "path": ParameterSchema(type="string", description="Directory path"),
                "max_depth": ParameterSchema(type="integer", description="Maximum depth"),
            },
            required=["path"],
        ),
    )
    
    def execute(self, arguments: Dict[str, Any]) -> ToolResult:
        path = arguments["path"]
        max_depth = arguments.get("max_depth", 3)
        
        try:
            from pathlib import Path
            root = Path(path)
            
            def list_recursive(current_path: Path, current_depth: int, prefix: str = "") -> List[str]:
                if current_depth > max_depth:
                    return []
                result = []
                try:
                    items = sorted(current_path.iterdir(), key=lambda x: (not x.is_dir(), x.name.lower()))
                    for i, item in enumerate(items):
                        is_last = i == len(items) - 1
                        current_prefix = "â””â”€â”€ " if is_last else "â”œâ”€â”€ "
                        result.append(f"{prefix}{current_prefix}{item.name}")
                        if item.is_dir():
                            next_prefix = prefix + ("    " if is_last else "â”‚   ")
                            result.extend(list_recursive(item, current_depth + 1, next_prefix))
                except PermissionError:
                    result.append(f"{prefix}â””â”€â”€ [Permission denied]")
                return result
            
            tree = [root.name]
            tree.extend(list_recursive(root, 1))
            
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content="\n".join(tree),
                metadata={"root": str(root)},
            )
        except Exception as e:
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content="",
                error=str(e),
            )


class FindFilesTool(Tool):
    name = "find_files"
    description = "Find files matching a glob pattern"
    schema = ToolSchema(
        name="find_files",
        description="Find files matching a glob pattern",
        parameters=ParameterSchema(
            type="object",
            properties={
                "pattern": ParameterSchema(type="string", description="Glob pattern to match"),
                "path": ParameterSchema(type="string", description="Directory to search"),
            },
            required=["pattern"],
        ),
    )
    
    def execute(self, arguments: Dict[str, Any]) -> ToolResult:
        pattern = arguments["pattern"]
        path = arguments.get("path", ".")
        
        try:
            from pathlib import Path
            root = Path(path)
            matches = []
            
            for file_path in root.rglob(pattern):
                if file_path.is_file():
                    matches.append(str(file_path))
            
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content=json.dumps(matches, indent=2),
                metadata={"match_count": len(matches)},
            )
        except Exception as e:
            return ToolResult(
                tool_call_id=arguments.get("tool_call_id", ""),
                name=self.name,
                content="",
                error=str(e),
            )


# Register all builtin tools
def register_builtin_tools(registry: "ToolRegistry") -> None:
    """Register all built-in tools into the given registry."""
    registry.register(ReadFileTool())
    registry.register(WriteFileTool())
    registry.register(PatchFileTool())
    registry.register(SearchInFilesTool())
    registry.register(ListFilesTool())
    registry.register(ListFilesRecursiveTool())
    registry.register(FindFilesTool())
    registry.register(RunCommandTool())
    registry.register(FlutterAnalyzeTool())
    registry.register(PythonCheckTool())
