"""Python SDK tools — lint (ruff), format (ruff format), test (pytest).

All three shell out to a CLI the user is expected to have on PATH. Missing
binaries surface a clear hint pointing at the install command rather than
a cryptic FileNotFoundError. Output is capped at 20 KB per tool so a noisy
test run doesn't blow the context window.

Sandbox policy:
  - python_lint   : read-only static analysis  → always allowed
  - python_format : rewrites files             → blocked in sandbox
  - python_test   : executes user code         → blocked in sandbox
"""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

# Cap on captured stdout+stderr. Pytest in particular can emit megabytes
# of tracebacks on a wide failure; truncating early saves the conversation.
_MAX_CHARS = 20000


def _truncate(output: str) -> tuple[str, bool]:
    if len(output) <= _MAX_CHARS:
        return output, False
    overflow = len(output) - _MAX_CHARS
    return output[:_MAX_CHARS] + f"\n... [truncated, {overflow} more chars]", True


def register(registry) -> None:
    def python_check(path: str = ".", max_files: int = 2000) -> str:
        """Compile Python source to detect syntax errors without writing files."""
        try:
            target = registry.resolve_path(path)
            rel_root = (
                str(target.relative_to(registry.base_path))
                if target != registry.base_path
                else "."
            )

            files: list[Path] = []
            if target.is_file():
                if target.suffix.lower() == ".py":
                    files = [target]
            elif target.is_dir():
                files = sorted(p for p in target.rglob("*.py") if p.is_file())
            else:
                return json.dumps(
                    {
                        "status": "error",
                        "message": f"Path does not exist: {path}",
                    }
                )

            checked = 0
            errors: list[dict] = []
            truncated = False

            for fp in files:
                if checked >= max_files:
                    truncated = True
                    break

                checked += 1
                rel = str(fp.relative_to(registry.base_path))
                try:
                    source = fp.read_text(encoding="utf-8", errors="replace")
                    compile(source, rel, "exec")
                except SyntaxError as e:
                    errors.append(
                        {
                            "path": rel,
                            "line": e.lineno or 0,
                            "column": e.offset or 0,
                            "message": str(e.msg or "Syntax error"),
                            "text": (e.text or "").strip(),
                        }
                    )
                except Exception as e:
                    errors.append(
                        {
                            "path": rel,
                            "line": 0,
                            "column": 0,
                            "message": str(e),
                            "text": "",
                        }
                    )

                if len(errors) >= 200:
                    truncated = True
                    break

            return json.dumps(
                {
                    "status": "success" if not errors else "error",
                    "path": rel_root,
                    "checked_files": checked,
                    "error_count": len(errors),
                    "truncated": truncated,
                    "errors": errors,
                }
            )
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def python_lint(path: str = ".", timeout: int = 120) -> str:
        """Run `ruff check` on a file or directory and tally severities.

        Read-only — safe in sandbox mode. Uses Ruff because it's two
        orders of magnitude faster than pylint/flake8 and ships a single
        binary, but the output line format is grep-friendly the same way.
        """
        try:
            target = registry.resolve_path(path)
            rel = (
                str(target.relative_to(registry.base_path))
                if target != registry.base_path
                else "."
            )
            result = subprocess.run(
                ["ruff", "check", rel],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout,
                cwd=str(registry.base_path),
            )
            output = (result.stdout or "") + (result.stderr or "")
            # Ruff prints either "All checks passed!" or one line per
            # issue: "path/file.py:12:5: E501 Line too long ...". Count
            # by matching the leading path:line:col: pattern.
            lines = output.splitlines()
            issue_lines = [ln for ln in lines if re.match(r".+:\d+:\d+:", ln)]
            issues = len(issue_lines)
            # Ruff's last summary line ("Found N errors") is also useful;
            # let it ride along in `output`.
            output, truncated = _truncate(output)
            return json.dumps(
                {
                    "status": "success" if result.returncode == 0 else "error",
                    "path": rel,
                    "returncode": result.returncode,
                    "issues": issues,
                    "truncated": truncated,
                    "output": output if output.strip() else "(no lint output)",
                }
            )
        except FileNotFoundError:
            return json.dumps(
                {
                    "status": "error",
                    "message": (
                        "ruff not found on PATH. Install with "
                        "`pip install ruff` (or `pipx install ruff`)."
                    ),
                }
            )
        except subprocess.TimeoutExpired:
            return json.dumps(
                {"status": "error", "message": f"ruff check timed out ({timeout}s)"}
            )
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def python_format(path: str = ".", timeout: int = 120) -> str:
        """Run `ruff format` on a file or directory.

        Mutates files — blocked in sandbox mode. Returns the count of
        files that were rewritten so the model knows whether to re-run
        analysis afterwards.
        """
        try:
            if registry.security_config.sandbox_mode:
                return json.dumps(
                    {
                        "status": "error",
                        "message": "python_format is disabled in sandbox mode.",
                    }
                )
            target = registry.resolve_path(path)
            rel = (
                str(target.relative_to(registry.base_path))
                if target != registry.base_path
                else "."
            )
            result = subprocess.run(
                ["ruff", "format", rel],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout,
                cwd=str(registry.base_path),
            )
            output = (result.stdout or "") + (result.stderr or "")
            # Ruff's summary line: "5 files reformatted, 12 files left unchanged".
            reformatted = 0
            m = re.search(r"(\d+)\s+files?\s+reformatted", output)
            if m:
                reformatted = int(m.group(1))
            output, truncated = _truncate(output)
            return json.dumps(
                {
                    "status": "success" if result.returncode == 0 else "error",
                    "path": rel,
                    "returncode": result.returncode,
                    "reformatted": reformatted,
                    "truncated": truncated,
                    "output": output if output.strip() else "(no format output)",
                }
            )
        except FileNotFoundError:
            return json.dumps(
                {
                    "status": "error",
                    "message": (
                        "ruff not found on PATH. Install with "
                        "`pip install ruff` (or `pipx install ruff`)."
                    ),
                }
            )
        except subprocess.TimeoutExpired:
            return json.dumps(
                {"status": "error", "message": f"ruff format timed out ({timeout}s)"}
            )
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def python_test(path: str = ".", timeout: int = 300) -> str:
        """Run pytest on a file or directory.

        Executes user code — blocked in sandbox mode. Returns parsed
        pass/fail counts plus the tail of pytest's output (which is where
        failure tracebacks live).
        """
        try:
            if registry.security_config.sandbox_mode:
                return json.dumps(
                    {
                        "status": "error",
                        "message": "python_test is disabled in sandbox mode.",
                    }
                )
            target = registry.resolve_path(path)
            rel = (
                str(target.relative_to(registry.base_path))
                if target != registry.base_path
                else "."
            )
            # `-q` keeps the output compact; `--no-header` drops the
            # pytest banner that wastes tokens on every call.
            cmd = ["pytest", "-q", "--no-header", rel]
            if rel == ".":
                cmd = ["pytest", "-q", "--no-header"]
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout,
                cwd=str(registry.base_path),
            )
            output = (result.stdout or "") + (result.stderr or "")
            # Pytest summary line examples:
            #   "5 passed in 0.42s"
            #   "1 failed, 4 passed in 0.51s"
            #   "no tests ran in 0.10s"
            passed = failed = errors = skipped = 0
            for kw, var in (
                ("passed", "passed"),
                ("failed", "failed"),
                ("error", "errors"),
                ("skipped", "skipped"),
            ):
                m = re.search(rf"(\d+)\s+{kw}", output)
                if m:
                    var = locals()[var]  # silence linter; we set via dict below

            # Re-extract directly into named ints (locals() trick above
            # doesn't write back in CPython).
            def _count(kw2: str) -> int:
                m2 = re.search(rf"(\d+)\s+{kw2}", output)
                return int(m2.group(1)) if m2 else 0

            passed = _count("passed")
            failed = _count("failed")
            errors = _count("error")
            skipped = _count("skipped")
            output, truncated = _truncate(output)
            return json.dumps(
                {
                    "status": "success" if result.returncode == 0 else "error",
                    "path": rel,
                    "returncode": result.returncode,
                    "passed": passed,
                    "failed": failed,
                    "errors": errors,
                    "skipped": skipped,
                    "truncated": truncated,
                    "output": output if output.strip() else "(no test output)",
                }
            )
        except FileNotFoundError:
            return json.dumps(
                {
                    "status": "error",
                    "message": (
                        "pytest not found on PATH. Install with `pip install pytest`."
                    ),
                }
            )
        except subprocess.TimeoutExpired:
            return json.dumps(
                {"status": "error", "message": f"pytest timed out ({timeout}s)"}
            )
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    registry.tools.update(
        {
            "python_check": python_check,
            "python_lint": python_lint,
            "python_format": python_format,
            "python_test": python_test,
        }
    )

    registry.definitions.extend(
        [
            {
                "type": "function",
                "function": {
                    "name": "python_check",
                    "description": (
                        "Compile Python source files to detect syntax errors "
                        "without writing artifacts. Read-only and safe in sandbox "
                        "mode. Use after editing Python code to ensure it still parses."
                    ),
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "path": {
                                "type": "string",
                                "description": "Optional Python file or directory to check (default '.', the whole project)",
                            },
                            "max_files": {
                                "type": "integer",
                                "description": "Maximum number of .py files to parse before truncating (default 2000)",
                            },
                        },
                        "required": [],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "python_lint",
                    "description": (
                        "Run `ruff check` on a Python file or directory and "
                        "return the lint diagnostics. Read-only — safe to call "
                        "in sandbox mode. Use after editing Python code to "
                        "verify there are no style/error issues."
                    ),
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "path": {
                                "type": "string",
                                "description": "Optional file or directory to lint (default '.', the whole project)",
                            },
                            "timeout": {
                                "type": "integer",
                                "description": "Seconds before ruff is killed (default 120)",
                            },
                        },
                        "required": [],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "python_format",
                    "description": (
                        "Run `ruff format` on a Python file or directory. "
                        "Rewrites files in place — call after large edits to "
                        "normalise quotes, indentation, and line length."
                    ),
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "path": {
                                "type": "string",
                                "description": "Optional file or directory to format (default '.', the whole project)",
                            },
                            "timeout": {
                                "type": "integer",
                                "description": "Seconds before ruff is killed (default 120)",
                            },
                        },
                        "required": [],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "python_test",
                    "description": (
                        "Run pytest on a Python file or directory. Returns "
                        "pass/fail/error/skipped counts plus the captured "
                        "output. Use after editing Python code to verify "
                        "behaviour. Executes user code — disabled in sandbox mode."
                    ),
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "path": {
                                "type": "string",
                                "description": "Optional file or directory to test (default '.', the whole project)",
                            },
                            "timeout": {
                                "type": "integer",
                                "description": "Seconds before pytest is killed (default 300)",
                            },
                        },
                        "required": [],
                    },
                },
            },
        ]
    )
