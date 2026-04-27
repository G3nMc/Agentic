"""Read-only filesystem tools — listing, reading, searching."""
from __future__ import annotations

import fnmatch
import json
import re


def register(registry) -> None:
    base_path = registry.base_path

    def list_files(path: str = ".") -> str:
        try:
            target = registry._resolve_path(path)
            items = sorted(
                p.name + ("/" if p.is_dir() else "") for p in target.iterdir()
            )
            return json.dumps({"status": "success", "files": items, "count": len(items)})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def read_file(path: str) -> str:
        try:
            fp = registry._resolve_path(path)
            if not fp.exists():
                return json.dumps({"status": "error", "message": f"File not found: {path}"})
            content = fp.read_text(encoding="utf-8", errors="replace")
            return json.dumps({"status": "success", "path": path,
                               "content": content, "size": len(content)})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def list_files_recursive(path: str = ".", max_depth: int = 3) -> str:
        """Recursively list directory tree up to max_depth levels."""
        SKIP = {".git", "__pycache__", ".dart_tool", "build", "node_modules", ".gradle"}
        try:
            target = registry._resolve_path(path)
            results = []

            def walk(p, depth):
                if depth > max_depth:
                    return
                try:
                    entries = sorted(p.iterdir(), key=lambda x: (x.is_file(), x.name.lower()))
                except PermissionError:
                    return
                for item in entries:
                    if item.name in SKIP:
                        continue
                    indent = "  " * (depth - 1)
                    results.append(indent + item.name + ("/" if item.is_dir() else ""))
                    if item.is_dir() and depth < max_depth:
                        walk(item, depth + 1)

            walk(target, 1)
            return json.dumps({"status": "success", "tree": results, "total": len(results)})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def search_in_files(pattern: str, path: str = ".", file_glob: str = "*") -> str:
        """Grep-like search: find lines matching a regex in files. Returns file:line: content."""
        SKIP_DIRS = {".git", "__pycache__", ".dart_tool", "build", "node_modules"}
        try:
            target = registry._resolve_path(path)
            compiled = re.compile(pattern)
            matches = []
            for fp in sorted(target.rglob("*")):
                if any(part in SKIP_DIRS for part in fp.parts):
                    continue
                if not fp.is_file():
                    continue
                if not fnmatch.fnmatch(fp.name, file_glob):
                    continue
                try:
                    text = fp.read_text(encoding="utf-8", errors="ignore")
                    for i, line in enumerate(text.splitlines(), 1):
                        if compiled.search(line):
                            rel = str(fp.relative_to(base_path))
                            matches.append(f"{rel}:{i}: {line.rstrip()}")
                            if len(matches) >= 300:
                                break
                except Exception:
                    pass
                if len(matches) >= 300:
                    break
            return json.dumps({
                "status": "success",
                "matches": matches,
                "total": len(matches),
                "truncated": len(matches) >= 300,
            })
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def find_files(pattern: str, path: str = ".") -> str:
        """Find files or directories whose name matches a glob pattern (e.g. *.dart)."""
        SKIP_DIRS = {".git", "__pycache__", ".dart_tool", "build", "node_modules"}
        try:
            target = registry._resolve_path(path)
            matches = []
            for item in sorted(target.rglob("*")):
                if any(part in SKIP_DIRS for part in item.parts):
                    continue
                if fnmatch.fnmatch(item.name, pattern):
                    rel = str(item.relative_to(base_path))
                    matches.append(rel + ("/" if item.is_dir() else ""))
            return json.dumps({"status": "success", "matches": matches, "total": len(matches)})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    registry.tools.update({
        "list_files": list_files,
        "list_files_recursive": list_files_recursive,
        "read_file": read_file,
        "search_in_files": search_in_files,
        "find_files": find_files,
    })

    registry.definitions.extend([
        {
            "type": "function",
            "function": {
                "name": "list_files",
                "description": "List files in a directory (relative to project root).",
                "parameters": {
                    "type": "object",
                    "properties": {"path": {"type": "string", "description": "Directory path, defaults to '.'"}},
                    "required": [],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "read_file",
                "description": "Read the complete contents of a local file.",
                "parameters": {
                    "type": "object",
                    "properties": {"path": {"type": "string", "description": "File path"}},
                    "required": ["path"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "list_files_recursive",
                "description": "Recursively list the directory tree (up to max_depth levels). Better than list_files for exploring project structure.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "path": {"type": "string", "description": "Root directory (default '.')"},
                        "max_depth": {"type": "integer", "description": "Maximum depth to recurse (default 3)"},
                    },
                    "required": [],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "search_in_files",
                "description": "Grep-like search: find lines matching a regex pattern across all files in a directory. Use this to locate where a symbol, function, or string is defined or used.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "pattern": {"type": "string", "description": "Regular expression to search for"},
                        "path": {"type": "string", "description": "Directory to search in (default '.')"},
                        "file_glob": {"type": "string", "description": "Filename glob filter, e.g. '*.dart' or '*.py' (default '*')"},
                    },
                    "required": ["pattern"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "find_files",
                "description": "Find files or directories whose name matches a glob pattern, e.g. '*.dart', 'main.*', 'settings*'.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "pattern": {"type": "string", "description": "Glob pattern for filename, e.g. '*.dart'"},
                        "path": {"type": "string", "description": "Directory to search in (default '.')"},
                    },
                    "required": ["pattern"],
                },
            },
        },
    ])
