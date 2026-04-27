"""Flutter SDK tools — currently just `flutter analyze`."""
from __future__ import annotations

import json
import re
import subprocess


def register(registry) -> None:
    def flutter_analyze(path: str = ".", timeout: int = 180) -> str:
        """Run `flutter analyze` and return the diagnostics.

        Read-only static analysis — safe to run in sandbox mode. Honours
        `path` (file or directory) so the model can scope analysis to a
        single file after editing it. Returns parsed counts (errors /
        warnings / info) plus the raw output, capped to keep the tool
        result small enough for any context window.
        """
        try:
            target = registry._resolve_path(path)
            rel = (str(target.relative_to(registry.base_path))
                   if target != registry.base_path else ".")
            # Use the locally-installed flutter binary (caller's PATH).
            cmd = ["flutter", "analyze", "--no-pub"]
            if rel != ".":
                cmd.append(rel)
            result = subprocess.run(
                cmd,
                capture_output=True, text=True,
                timeout=timeout, cwd=str(registry.base_path),
            )
            output = (result.stdout or "") + (result.stderr or "")
            # Tally severities from the typical analyzer output, e.g.:
            #   "  error • Undefined name 'foo' • lib/main.dart:12:4"
            lines = output.splitlines()
            errors = sum(1 for ln in lines if re.search(r"^\s*error\b", ln))
            warnings = sum(1 for ln in lines if re.search(r"^\s*warning\b", ln))
            infos = sum(1 for ln in lines if re.search(r"^\s*info\b", ln))
            # Cap output so we don't blow up the context window on a
            # repo with thousands of lints.
            MAX_CHARS = 20000
            truncated = len(output) > MAX_CHARS
            if truncated:
                output = output[:MAX_CHARS] + f"\n... [truncated, {len(output) - MAX_CHARS} more chars]"
            return json.dumps({
                "status": "success" if result.returncode == 0 else "error",
                "path": rel,
                "returncode": result.returncode,
                "errors": errors,
                "warnings": warnings,
                "info": infos,
                "truncated": truncated,
                "output": output if output.strip() else "(no analyzer output)",
            })
        except FileNotFoundError:
            return json.dumps({
                "status": "error",
                "message": ("flutter CLI not found on PATH. Install Flutter and "
                            "ensure `flutter` is reachable from the orchestrator's shell."),
            })
        except subprocess.TimeoutExpired:
            return json.dumps({"status": "error",
                               "message": f"flutter analyze timed out ({timeout}s)"})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    registry.tools["flutter_analyze"] = flutter_analyze
    registry.definitions.append({
        "type": "function",
        "function": {
            "name": "flutter_analyze",
            "description": (
                "Run `flutter analyze` on the project (or a specific file/dir) "
                "and return the diagnostics. Use after editing Dart code to "
                "verify there are no static errors or new lints. Read-only — "
                "safe to call in sandbox mode."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Optional file or directory to analyze (default '.', the whole project)",
                    },
                    "timeout": {
                        "type": "integer",
                        "description": "Seconds before the analyzer is killed (default 180)",
                    },
                },
                "required": [],
            },
        },
    })
