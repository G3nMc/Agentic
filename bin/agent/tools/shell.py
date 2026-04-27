"""Shell command execution."""
from __future__ import annotations

import json
import subprocess


def register(registry) -> None:
    def run_command(command: str, timeout: int = 120) -> str:
        try:
            if registry.security_config.sandbox_mode:
                return json.dumps({"status": "error",
                                   "message": "run_command is disabled in sandbox mode."})
            # Blocklist check: reject commands containing dangerous substrings.
            cmd_lower = command.lower().strip()
            for blocked in registry.security_config.command_blocklist:
                if blocked.lower() in cmd_lower:
                    return json.dumps({
                        "status": "error",
                        "message": (f"Command blocked by security policy "
                                    f"(matches forbidden pattern: '{blocked}')."),
                    })
            result = subprocess.run(
                command, shell=True, capture_output=True, text=True,
                timeout=timeout, cwd=str(registry.base_path),
            )
            output = (result.stdout or "") + (result.stderr or "")
            return json.dumps({
                "status": "success" if result.returncode == 0 else "error",
                "command": command,
                "output": output if output else "(no output)",
                "returncode": result.returncode,
            })
        except subprocess.TimeoutExpired:
            return json.dumps({"status": "error",
                               "message": f"Command timed out ({timeout}s limit)"})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    registry.tools["run_command"] = run_command
    registry.definitions.append({
        "type": "function",
        "function": {
            "name": "run_command",
            "description": "Run a shell command (30s timeout) inside the project root.",
            "parameters": {
                "type": "object",
                "properties": {"command": {"type": "string"}},
                "required": ["command"],
            },
        },
    })
