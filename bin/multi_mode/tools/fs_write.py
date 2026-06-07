"""Mutating filesystem tools — create, modify, move, delete."""

from __future__ import annotations

import json
import shutil


def register(registry) -> None:
    def write_file(path: str, content: str) -> str:
        try:
            if registry.security_config.sandbox_mode:
                return json.dumps(
                    {
                        "status": "error",
                        "message": "write_file is disabled in sandbox mode.",
                    }
                )
            fp = registry.resolve_path(path)
            size_bytes = len(content.encode("utf-8"))
            limit = registry.security_config.max_file_size_bytes
            if limit > 0 and size_bytes > limit:
                limit_mb = limit / (1024 * 1024)
                return json.dumps(
                    {
                        "status": "error",
                        "message": (
                            f"Content too large: {size_bytes:,} bytes "
                            f"exceeds the {limit_mb:.0f} MB limit."
                        ),
                    }
                )
            fp.parent.mkdir(parents=True, exist_ok=True)
            fp.write_text(content, encoding="utf-8")
            return json.dumps(
                {
                    "status": "success",
                    "message": f"File written: {path}",
                    "size": len(content),
                }
            )
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def append_file(path: str, content: str) -> str:
        try:
            if registry.security_config.sandbox_mode:
                return json.dumps(
                    {
                        "status": "error",
                        "message": "append_file is disabled in sandbox mode.",
                    }
                )
            fp = registry.resolve_path(path)
            chunk_bytes = len(content.encode("utf-8"))
            limit = registry.security_config.max_file_size_bytes
            if limit > 0:
                existing_bytes = fp.stat().st_size if fp.exists() else 0
                total_bytes = existing_bytes + chunk_bytes
                if total_bytes > limit:
                    limit_mb = limit / (1024 * 1024)
                    return json.dumps(
                        {
                            "status": "error",
                            "message": (
                                f"Cannot append: resulting file size "
                                f"({total_bytes:,} bytes) would exceed "
                                f"the {limit_mb:.0f} MB limit."
                            ),
                        }
                    )
            with open(fp, "a", encoding="utf-8") as f:
                f.write(content)
            return json.dumps({"status": "success", "message": f"Appended to: {path}"})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def delete_file(path: str) -> str:
        try:
            if registry.security_config.sandbox_mode:
                return json.dumps(
                    {
                        "status": "error",
                        "message": "delete_file is disabled in sandbox mode.",
                    }
                )
            fp = registry.resolve_path(path)
            if not fp.exists():
                return json.dumps(
                    {"status": "error", "message": f"File not found: {path}"}
                )
            fp.unlink()
            return json.dumps({"status": "success", "message": f"Deleted: {path}"})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def patch_file(path: str, old_content: str, new_content: str) -> str:
        """Replace the FIRST occurrence of old_content with new_content in a file.
        Safer than write_file for targeted edits — use this to change a specific
        function, class, or block without rewriting the entire file."""
        try:
            fp = registry.resolve_path(path)
            if not fp.exists():
                return json.dumps(
                    {"status": "error", "message": f"File not found: {path}"}
                )
            text = fp.read_text(encoding="utf-8")
            if old_content not in text:
                return json.dumps(
                    {
                        "status": "error",
                        "message": "old_content not found in file — check exact whitespace and line endings",
                    }
                )
            count = text.count(old_content)
            text = text.replace(old_content, new_content, 1)
            fp.write_text(text, encoding="utf-8")
            return json.dumps(
                {
                    "status": "success",
                    "message": f"Patched {path} (replaced 1 of {count} occurrence(s))",
                }
            )
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def move_file(source: str, destination: str) -> str:
        """Move or rename a file or directory."""
        try:
            src = registry.resolve_path(source)
            dst = registry.resolve_path(destination)
            if not src.exists():
                return json.dumps(
                    {"status": "error", "message": f"Source not found: {source}"}
                )
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(src), str(dst))
            return json.dumps(
                {"status": "success", "message": f"Moved: {source} -> {destination}"}
            )
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def create_directory(path: str) -> str:
        """Create a directory (including any missing parent directories)."""
        try:
            dp = registry.resolve_path(path)
            dp.mkdir(parents=True, exist_ok=True)
            return json.dumps(
                {"status": "success", "message": f"Directory created: {path}"}
            )
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    registry.tools.update(
        {
            "write_file": write_file,
            "patch_file": patch_file,
            "append_file": append_file,
            "delete_file": delete_file,
            "move_file": move_file,
            "create_directory": create_directory,
        }
    )

    registry.definitions.extend(
        [
            {
                "type": "function",
                "function": {
                    "name": "write_file",
                    "description": "Create or overwrite a local file.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "path": {"type": "string"},
                            "content": {"type": "string"},
                        },
                        "required": ["path", "content"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "append_file",
                    "description": "Append content to an existing file.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "path": {"type": "string"},
                            "content": {"type": "string"},
                        },
                        "required": ["path", "content"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "delete_file",
                    "description": "Delete a local file.",
                    "parameters": {
                        "type": "object",
                        "properties": {"path": {"type": "string"}},
                        "required": ["path"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "patch_file",
                    "description": "Replace the FIRST occurrence of old_content with new_content in a file. Use this for targeted edits (a function, a block) instead of rewriting the whole file with write_file.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "path": {
                                "type": "string",
                                "description": "File path to edit",
                            },
                            "old_content": {
                                "type": "string",
                                "description": "Exact string to find and replace (must match exactly, including whitespace)",
                            },
                            "new_content": {
                                "type": "string",
                                "description": "Replacement string",
                            },
                        },
                        "required": ["path", "old_content", "new_content"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "move_file",
                    "description": "Move or rename a file or directory.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "source": {"type": "string", "description": "Source path"},
                            "destination": {
                                "type": "string",
                                "description": "Destination path",
                            },
                        },
                        "required": ["source", "destination"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "create_directory",
                    "description": "Create a directory and any missing parent directories.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "path": {
                                "type": "string",
                                "description": "Directory path to create",
                            },
                        },
                        "required": ["path"],
                    },
                },
            },
        ]
    )
