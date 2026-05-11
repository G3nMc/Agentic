"""Read-only filesystem tools — listing, reading, searching.

Discovery here (list_files / list_files_recursive / find_files /
search_in_files) consults `registry.path_filter` so the user-configured
exclude/include lists are respected. read_file is intentionally NOT
filtered — the user can still ask the model to operate on a specific
path inside an "excluded" location. See agent/path_filter.py.
"""
from __future__ import annotations

import sys as _sys
_sys.dont_write_bytecode = True

import fnmatch
import json
import re


def register(registry) -> None:
    base_path = registry.base_path
    pf = registry.path_filter

    def list_files(path: str = ".") -> str:
        try:
            target = registry.resolve_path(path)
            items = []
            for p in target.iterdir():
                if p.is_dir():
                    if not pf.is_dir_allowed(p):
                        continue
                    items.append(p.name + "/")
                else:
                    if not pf.is_file_allowed(p):
                        continue
                    items.append(p.name)
            items.sort()
            return json.dumps({"status": "success", "files": items, "count": len(items)})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def read_file(
        path: str,
        start_line: int | None = None,
        end_line: int | None = None,
        offset: int | None = None,
        limit: int | None = None,
    ) -> str:
        # Hard cap on returned content. Large files dumped into history
        # bloat every subsequent model call by their full size, slowing
        # the loop and burning tokens. 100 KB is plenty for typical
        # source files; bigger reads get a truncation marker.
        # start_line/end_line (1-indexed, inclusive) and offset/limit
        # (0-indexed offset, line count) let the model re-read a specific
        # window of a previously-read file instead of pulling the whole
        # thing again — this is what every other agent CLI's read_file
        # supports, and not supporting it caused the repeat-call cascade.
        MAX_BYTES = 100 * 1024
        try:
            fp = registry.resolve_path(path)
            if not fp.exists():
                return json.dumps({"status": "error", "message": f"File not found: {path}"})
            raw = fp.read_bytes()
            total = len(raw)
            full_text = raw.decode("utf-8", errors="replace")

            wants_range = any(
                v is not None for v in (start_line, end_line, offset, limit)
            )

            if wants_range:
                lines = full_text.splitlines()
                line_count = len(lines)

                # Normalize aliases: offset/limit -> start_line/end_line.
                if start_line is None and offset is not None:
                    try:
                        start_line = max(int(offset), 0) + 1
                    except (TypeError, ValueError):
                        start_line = 1
                if end_line is None and limit is not None:
                    try:
                        if start_line is None:
                            start_line = 1
                        end_line = start_line + max(int(limit), 0) - 1
                    except (TypeError, ValueError):
                        end_line = None

                try:
                    s = max(int(start_line), 1) if start_line is not None else 1
                except (TypeError, ValueError):
                    s = 1
                try:
                    e = (
                        min(int(end_line), line_count)
                        if end_line is not None
                        else line_count
                    )
                except (TypeError, ValueError):
                    e = line_count

                if e < s:
                    e = s
                window = lines[s - 1:e]
                # Prefix each line with its 1-indexed number so the model
                # has unambiguous offsets when it asks for a follow-up
                # range or composes a patch.
                pad = len(str(e))
                numbered = "\n".join(
                    f"{str(s + i).rjust(pad)}\t{ln}" for i, ln in enumerate(window)
                )
                return json.dumps({
                    "status": "success",
                    "path": path,
                    "content": numbered,
                    "size": total,
                    "line_count": line_count,
                    "start_line": s,
                    "end_line": e,
                    "truncated": False,
                })

            truncated = total > MAX_BYTES
            if truncated:
                line_count = full_text.count("\n") + 1
                content = full_text.encode("utf-8", errors="replace")[:MAX_BYTES].decode(
                    "utf-8", errors="replace"
                )
                content = (
                    f"[TRUNCATED: returned first {MAX_BYTES} bytes of {total} "
                    f"(~{line_count} lines total). "
                    f"Use read_file(\"{path}\", start_line=N, end_line=M) "
                    f"to read a specific section, or search_in_files to locate "
                    f"content without fetching the whole file.]\n\n"
                ) + content
            else:
                content = full_text

            return json.dumps({
                "status": "success",
                "path": path,
                "content": content,
                "size": total,
                "truncated": truncated,
            })
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def list_files_recursive(path: str = ".", max_depth: int = 3) -> str:
        """Recursively list directory tree up to max_depth levels."""
        try:
            target = registry.resolve_path(path)
            results = []

            def walk(p, depth):
                if depth > max_depth:
                    return
                try:
                    entries = sorted(p.iterdir(), key=lambda x: (x.is_file(), x.name.lower()))
                except PermissionError:
                    return
                for item in entries:
                    if item.is_dir():
                        if not pf.is_dir_allowed(item):
                            continue
                    else:
                        if not pf.is_file_allowed(item):
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
        try:
            target = registry.resolve_path(path)
            compiled = re.compile(pattern)
            matches = []
            # Walk manually so we can prune denied directories cheaply
            # instead of letting rglob descend into them.
            def walk(d):
                if not pf.is_dir_allowed(d):
                    return
                try:
                    entries = sorted(d.iterdir())
                except (PermissionError, OSError):
                    return
                for entry in entries:
                    if entry.is_dir():
                        walk(entry)
                        if len(matches) >= 300:
                            return
                    elif entry.is_file():
                        if not pf.is_file_allowed(entry):
                            continue
                        if not fnmatch.fnmatch(entry.name, file_glob):
                            continue
                        # Skip very large files — almost always binary
                        # blobs or generated bundles that drown real
                        # matches in noise.
                        try:
                            if entry.stat().st_size > 1_000_000:
                                continue
                        except OSError:
                            continue
                        try:
                            raw = entry.read_bytes()
                            if b"\x00" in raw[:8192]:
                                continue
                            text = raw.decode("utf-8", errors="ignore")
                            for i, line in enumerate(text.splitlines(), 1):
                                if compiled.search(line):
                                    rel = str(entry.relative_to(base_path))
                                    matches.append(f"{rel}:{i}: {line.rstrip()}")
                                    if len(matches) >= 300:
                                        return
                        except Exception:
                            pass

            if target.is_dir():
                walk(target)
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
        try:
            target = registry.resolve_path(path)
            matches = []

            def walk(d):
                if not pf.is_dir_allowed(d):
                    return
                try:
                    entries = sorted(d.iterdir())
                except (PermissionError, OSError):
                    return
                for entry in entries:
                    if entry.is_dir():
                        if fnmatch.fnmatch(entry.name, pattern):
                            rel = str(entry.relative_to(base_path))
                            matches.append(rel + "/")
                        walk(entry)
                    elif entry.is_file():
                        if not pf.is_file_allowed(entry):
                            continue
                        if fnmatch.fnmatch(entry.name, pattern):
                            rel = str(entry.relative_to(base_path))
                            matches.append(rel)

            if target.is_dir():
                walk(target)
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
                "description": "Read a local file. Pass only `path` to read the whole file (capped at 100 KB). For large files, pass start_line+end_line (1-indexed, inclusive) or offset+limit to read a specific window — the response includes the line-numbered slice plus the file's total line_count so you can ask for the next window.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "path": {"type": "string", "description": "File path"},
                        "start_line": {"type": "integer", "description": "1-indexed first line to return (inclusive). Optional."},
                        "end_line": {"type": "integer", "description": "1-indexed last line to return (inclusive). Optional."},
                        "offset": {"type": "integer", "description": "Alias: 0-indexed first line. Converted to start_line internally."},
                        "limit": {"type": "integer", "description": "Alias: number of lines to return from start_line/offset."},
                    },
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
