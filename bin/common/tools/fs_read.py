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
            return json.dumps(
                {"status": "success", "files": items, "count": len(items)}
            )
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
                return json.dumps(
                    {"status": "error", "message": f"File not found: {path}"}
                )
            if fp.is_dir():
                return json.dumps(
                    {"status": "error", "message": f"Path is a directory, not a file: {path}"}
                )
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
                window = lines[s - 1 : e]
                # Prefix each line with its 1-indexed number so the model
                # has unambiguous offsets when it asks for a follow-up
                # range or composes a patch.
                pad = len(str(e))
                numbered = "\n".join(
                    f"{str(s + i).rjust(pad)}\t{ln}" for i, ln in enumerate(window)
                )
                return json.dumps(
                    {
                        "status": "success",
                        "path": path,
                        "content": numbered,
                        "size": total,
                        "line_count": line_count,
                        "start_line": s,
                        "end_line": e,
                        "truncated": False,
                    }
                )

            truncated = total > MAX_BYTES
            if truncated:
                line_count = full_text.count("\n") + 1
                content = full_text.encode("utf-8", errors="replace")[
                    :MAX_BYTES
                ].decode("utf-8", errors="replace")
                content = (
                    f"[TRUNCATED: returned first {MAX_BYTES} bytes of {total} "
                    f"(~{line_count} lines total). "
                    f'Use read_file("{path}", start_line=N, end_line=M) '
                    f"to read a specific section, or search_in_files to locate "
                    f"content without fetching the whole file.]\n\n"
                ) + content
            else:
                content = full_text

            return json.dumps(
                {
                    "status": "success",
                    "path": path,
                    "content": content,
                    "size": total,
                    "truncated": truncated,
                }
            )
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
                    entries = sorted(
                        p.iterdir(), key=lambda x: (x.is_file(), x.name.lower())
                    )
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
            return json.dumps(
                {"status": "success", "tree": results, "total": len(results)}
            )
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def search_in_files(
        pattern: str = "",
        path: str = ".",
        file_glob: str = "*",
        patterns=None,
    ) -> str:
        """Grep-like search: find lines matching a regex in files.

        Backward-compatible single-pattern mode:
            pattern="foo"  -> returns {matches: [...], total: N, ...}

        BATCH multi-pattern mode (avoids N separate iterations):
            patterns=["foo","bar","baz"]
            -> returns {results: {"foo": {...}, "bar": {...}, ...}}
        Each per-pattern entry has its own matches / total /
        truncated fields. The walk is performed ONCE across the file
        tree and every line is tested against every pattern, so the
        cost is roughly one search regardless of how many patterns are
        passed.
        """
        try:
            # Normalise pattern inputs.
            if patterns is not None:
                if not isinstance(patterns, list) or not patterns:
                    return json.dumps(
                        {
                            "status": "error",
                            "message": "patterns must be a non-empty list of strings",
                        }
                    )
                pattern_list = [p for p in patterns if isinstance(p, str) and p]
                if not pattern_list:
                    return json.dumps(
                        {
                            "status": "error",
                            "message": "patterns must contain at least one non-empty string",
                        }
                    )
                batch_mode = True
            else:
                if not isinstance(pattern, str) or not pattern:
                    return json.dumps(
                        {
                            "status": "error",
                            "message": "pattern (or patterns) is required",
                        }
                    )
                pattern_list = [pattern]
                batch_mode = False

            target = registry.resolve_path(path)
            compiled = [(p, re.compile(p)) for p in pattern_list]
            # Per-pattern accumulator.
            per_pattern_matches = {p: [] for p in pattern_list}
            cap_per_pattern = 300

            def walk(d):
                if not pf.is_dir_allowed(d):
                    return
                try:
                    entries = sorted(d.iterdir())
                except (PermissionError, OSError):
                    return
                # Early exit when every pattern has hit its cap.
                if all(
                    len(per_pattern_matches[p]) >= cap_per_pattern
                    for p in pattern_list
                ):
                    return
                for entry in entries:
                    if entry.is_dir():
                        walk(entry)
                        if all(
                            len(per_pattern_matches[p]) >= cap_per_pattern
                            for p in pattern_list
                        ):
                            return
                    elif entry.is_file():
                        if not pf.is_file_allowed(entry):
                            continue
                        if not fnmatch.fnmatch(entry.name, file_glob):
                            continue
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
                            rel = str(entry.relative_to(base_path))
                            for i, line in enumerate(text.splitlines(), 1):
                                for p, cr in compiled:
                                    if len(per_pattern_matches[p]) >= cap_per_pattern:
                                        continue
                                    if cr.search(line):
                                        per_pattern_matches[p].append(
                                            f"{rel}:{i}: {line.rstrip()}"
                                        )
                        except Exception:
                            pass

            if target.is_dir():
                walk(target)

            if not batch_mode:
                # Preserve legacy response shape.
                matches = per_pattern_matches[pattern_list[0]]
                return json.dumps(
                    {
                        "status": "success",
                        "matches": matches,
                        "total": len(matches),
                        "truncated": len(matches) >= cap_per_pattern,
                    }
                )
            # Batch response: per-pattern breakdown.
            results = {}
            grand_total = 0
            for p in pattern_list:
                ms = per_pattern_matches[p]
                results[p] = {
                    "matches": ms,
                    "total": len(ms),
                    "truncated": len(ms) >= cap_per_pattern,
                }
                grand_total += len(ms)
            return json.dumps(
                {
                    "status": "success",
                    "results": results,
                    "patterns": pattern_list,
                    "grand_total": grand_total,
                }
            )
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
            return json.dumps(
                {"status": "success", "matches": matches, "total": len(matches)}
            )
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def read_files(
        paths: list,
        max_lines_per_file: int | None = 200,
    ) -> str:
        """Read multiple files in one call. Returns concatenated contents with
        file headers, ideal for loading several related files at once instead
        of making separate read_file calls for each one.

        Each file's content is prefixed with a ``=== path ===`` separator so
        the model can distinguish where one file ends and another begins.
        Output is capped at ``MAX_TOTAL_BYTES`` (200 KB) to avoid flooding
        the context window; files beyond the cap are listed by name only.

        ``max_lines_per_file`` (default 200) limits how many lines are
        returned per file.  Set to ``null`` / omit to get the full file
        (still subject to the per-file 100 KB cap used by read_file).
        """
        MAX_TOTAL_BYTES = 200 * 1024
        PER_FILE_BYTE_CAP = 100 * 1024

        if not isinstance(paths, list) or len(paths) == 0:
            return json.dumps(
                {
                    "status": "error",
                    "message": "paths must be a non-empty list of file paths",
                }
            )

        # Cap the number of files to prevent abuse / context explosion.
        if len(paths) > 50:
            return json.dumps(
                {
                    "status": "error",
                    "message": (
                        f"Too many paths ({len(paths)}); maximum is 50. "
                        "Reduce the list or use search_in_files to narrow down."
                    ),
                }
            )

        results: list[dict] = []
        total_bytes = 0
        truncated_files: list[str] = []

        for file_path in paths:
            try:
                fp = registry.resolve_path(file_path)
            except ValueError as exc:
                results.append(
                    {
                        "path": file_path,
                        "status": "error",
                        "message": str(exc),
                    }
                )
                continue

            if not fp.exists():
                results.append(
                    {
                        "path": file_path,
                        "status": "error",
                        "message": f"File not found: {file_path}",
                    }
                )
                continue

            if fp.is_dir():
                results.append(
                    {
                        "path": file_path,
                        "status": "error",
                        "message": f"Path is a directory, not a file: {file_path}",
                    }
                )
                continue

            try:
                raw = fp.read_bytes()
                total_size = len(raw)
                full_text = raw.decode("utf-8", errors="replace")
            except Exception as exc:
                results.append(
                    {
                        "path": file_path,
                        "status": "error",
                        "message": str(exc),
                    }
                )
                continue

            # Apply line limit if requested.
            if max_lines_per_file is not None:
                lines = full_text.splitlines()
                line_count = len(lines)
                if line_count > max_lines_per_file:
                    window = lines[:max_lines_per_file]
                    pad = len(str(max_lines_per_file))
                    content = "\n".join(
                        f"{str(i + 1).rjust(pad)}\t{ln}" for i, ln in enumerate(window)
                    )
                    content += (
                        f"\n\n[... {line_count - max_lines_per_file} more lines "
                        f"(total {line_count} lines). "
                        f'Use read_file("{file_path}", start_line={max_lines_per_file + 1}) '
                        f"to continue reading.]"
                    )
                    was_truncated = True
                else:
                    content = full_text
                    was_truncated = False
            else:
                # No line limit — apply byte cap like read_file does.
                if total_size > PER_FILE_BYTE_CAP:
                    line_count = full_text.count("\n") + 1
                    content = full_text.encode("utf-8", errors="replace")[
                        :PER_FILE_BYTE_CAP
                    ].decode("utf-8", errors="replace")
                    content = (
                        f"[TRUNCATED: returned first {PER_FILE_BYTE_CAP} bytes "
                        f"of {total_size} (~{line_count} lines total). "
                        f'Use read_file("{file_path}", start_line=N, end_line=M) '
                        f"to read a specific section.]\\n\\n"
                    ) + content
                    was_truncated = True
                else:
                    content = full_text
                    was_truncated = False

            entry_bytes = len(content.encode("utf-8", errors="replace"))

            # If adding this file would exceed the total budget, list it by
            # name only instead of including its full content.
            if total_bytes + entry_bytes > MAX_TOTAL_BYTES:
                truncated_files.append(file_path)
                continue

            total_bytes += entry_bytes
            results.append(
                {
                    "path": file_path,
                    "status": "success",
                    "content": content,
                    "size": total_size,
                    "truncated": was_truncated,
                }
            )

        # Build the concatenated output with clear file separators.
        parts: list[str] = []
        for r in results:
            if r["status"] == "error":
                parts.append(f"=== {r['path']} ===\nERROR: {r['message']}")
            else:
                header = f"=== {r['path']} ==="
                if r.get("truncated"):
                    header += "  (truncated)"
                parts.append(f"{header}\n{r['content']}")

        if truncated_files:
            parts.append(
                "[OUTPUT TRUNCATED: the following files were omitted because "
                "the total output exceeded the size cap. "
                "Use read_file to read them individually: "
                + ", ".join(truncated_files)
                + "]"
            )

        return json.dumps(
            {
                "status": "success",
                "files_read": len([r for r in results if r["status"] == "success"]),
                "files_error": len([r for r in results if r["status"] == "error"]),
                "files_omitted": len(truncated_files),
                "total_bytes": total_bytes,
                "content": "\n\n".join(parts),
            }
        )

    registry.tools.update(
        {
            "list_files": list_files,
            "list_files_recursive": list_files_recursive,
            "read_file": read_file,
            "read_files": read_files,
            "search_in_files": search_in_files,
            "find_files": find_files,
        }
    )

    registry.definitions.extend(
        [
            {
                "type": "function",
                "function": {
                    "name": "list_files",
                    "description": "List files in a directory (relative to project root).",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "path": {
                                "type": "string",
                                "description": "Directory path, defaults to '.'",
                            }
                        },
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
                            "start_line": {
                                "type": "integer",
                                "description": "1-indexed first line to return (inclusive). Optional.",
                            },
                            "end_line": {
                                "type": "integer",
                                "description": "1-indexed last line to return (inclusive). Optional.",
                            },
                            "offset": {
                                "type": "integer",
                                "description": "Alias: 0-indexed first line. Converted to start_line internally.",
                            },
                            "limit": {
                                "type": "integer",
                                "description": "Alias: number of lines to return from start_line/offset.",
                            },
                        },
                        "required": ["path"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "read_files",
                    "description": "Read multiple files in one call. Returns concatenated contents with file headers, ideal for loading several related files at once instead of making separate read_file calls for each one. Each file is prefixed with a === path === separator. Output is capped at 200 KB total; files beyond the cap are listed by name only. Use max_lines_per_file to limit lines per file (default 200).",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "paths": {
                                "type": "array",
                                "items": {"type": "string"},
                                "description": "List of file paths (relative to project root) to read. Maximum 50 files.",
                            },
                            "max_lines_per_file": {
                                "type": "integer",
                                "description": "Maximum lines to return per file (default 200). Set to null for full content (subject to 100 KB per-file cap).",
                            },
                        },
                        "required": ["paths"],
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
                            "path": {
                                "type": "string",
                                "description": "Root directory (default '.')",
                            },
                            "max_depth": {
                                "type": "integer",
                                "description": "Maximum depth to recurse (default 3)",
                            },
                        },
                        "required": [],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "search_in_files",
                    "description": (
                        "Grep-like search: recursively find lines matching "
                        "regex pattern(s) across files in a directory tree. "
                        "Pass EITHER ``pattern`` (single regex) OR "
                        "``patterns`` (list of regexes for a BATCH search -- "
                        "the file tree is walked ONCE for all patterns, so "
                        "this saves N-1 iterations vs. calling the tool "
                        "repeatedly). Single-pattern returns {matches, "
                        "total, truncated}. Multi-pattern returns "
                        "{results: {pattern -> {matches, total, "
                        "truncated}}, grand_total}."
                    ),
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "pattern": {
                                "type": "string",
                                "description": "Regular expression to search for (single-pattern mode).",
                            },
                            "patterns": {
                                "type": "array",
                                "description": "List of regexes to search for in one pass (batch mode). Mutually exclusive with ``pattern``.",
                                "items": {"type": "string"},
                            },
                            "path": {
                                "type": "string",
                                "description": "Directory to search in (default '.')",
                            },
                            "file_glob": {
                                "type": "string",
                                "description": "Filename glob filter, e.g. '*.dart' or '*.py' (default '*')",
                            },
                        },
                        "required": [],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "find_files",
                    "description": "Recursively find files or directories whose name matches a glob pattern, e.g. '*.dart', 'main.*', 'settings*'.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "pattern": {
                                "type": "string",
                                "description": "Glob pattern for filename, e.g. '*.dart'",
                            },
                            "path": {
                                "type": "string",
                                "description": "Directory to search in (default '.')",
                            },
                        },
                        "required": ["pattern"],
                    },
                },
            },
        ]
    )
