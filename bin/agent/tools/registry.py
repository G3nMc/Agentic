"""ToolRegistry — central dispatch for every tool the agent can call.

Tools themselves are defined in ``agent.tools.<category>`` modules and
attach themselves via :func:`agent.tools.collect_all_tools`.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from ..policy import SecurityConfig
from ..utils.audit import audit_log, setup_audit_logger
from ..utils.circuit_breaker import CircuitBreaker


class ToolRegistry:
    """
    Manages the tools the AI can call. Paths are confined to `base_path`.
    """

    def __init__(self, base_path: str = ".",
                 security_config: Optional[SecurityConfig] = None):
        self.base_path = Path(base_path).resolve()
        self.security_config: SecurityConfig = security_config or SecurityConfig()
        self._audit_logger = setup_audit_logger(self.security_config)
        # Per-tool circuit breakers: track consecutive failures on each tool.
        self._tool_circuit_breakers: Dict[str, CircuitBreaker] = {}
        self.tools: Dict[str, Callable] = {}
        self.definitions: List[Dict[str, Any]] = []
        # Late import — agent.tools depends on this module, so we can't pull
        # it at module top without a circular import.
        from . import collect_all_tools
        collect_all_tools(self)

    # ------------------------------------------------------------------
    # Path safety
    # ------------------------------------------------------------------
    def _resolve_path(self, path: str) -> Path:
        resolved = (self.base_path / path).resolve()
        if not str(resolved).startswith(str(self.base_path)):
            raise ValueError(f"Access denied: {path} is outside base directory")
        return resolved

    def _relativise(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Convert any absolute `path` value to a path relative to base_path.

        Models sometimes echo an absolute path the user typed (e.g.
        C:\\Users\\...\\project\\lib\\main.dart). If that path sits inside
        base_path we can silently fix it; otherwise the _resolve_path check
        will reject it with a clear error rather than crashing.
        """
        path = params.get("path")
        if not path or not isinstance(path, str):
            return params
        p = Path(path)
        if not p.is_absolute():
            return params
        try:
            relative = p.relative_to(self.base_path)
            return {**params, "path": str(relative)}
        except ValueError:
            # Not under base_path — leave as-is so _resolve_path can reject.
            return params

    # ------------------------------------------------------------------
    # Dispatch
    # ------------------------------------------------------------------
    def execute(self, tool_name: str, parameters: Dict[str, Any]) -> str:
        if tool_name not in self.tools:
            result = json.dumps({"status": "error", "message": f"Unknown tool: {tool_name}"})
            audit_log(self._audit_logger, tool_name, parameters or {}, result)
            return result

        # Per-tool circuit breaker: skip execution when the breaker is OPEN.
        cb = self._tool_circuit_breakers.setdefault(
            tool_name,
            CircuitBreaker(name=f"tool:{tool_name}", failure_threshold=5,
                           recovery_timeout=30.0),
        )
        if not cb.allow_request():
            result = json.dumps({
                "status": "error",
                "message": (f"Tool '{tool_name}' is temporarily disabled by circuit breaker "
                            f"(too many consecutive failures). Will retry after "
                            f"{cb.recovery_timeout:.0f}s."),
            })
            audit_log(self._audit_logger, tool_name, parameters or {}, result)
            return result

        try:
            safe_params = self._relativise(parameters or {})
            result = self.tools[tool_name](**safe_params)
            # Track success/failure for the per-tool circuit breaker.
            try:
                result_obj = json.loads(result)
                if result_obj.get("status") == "error":
                    cb.record_failure()
                else:
                    cb.record_success()
            except Exception:
                cb.record_success()
            audit_log(self._audit_logger, tool_name, safe_params, result)
            return result
        except TypeError as e:
            err = json.dumps({"status": "error", "message": f"Invalid parameters: {e}"})
            cb.record_failure()
            audit_log(self._audit_logger, tool_name, parameters or {}, err)
            return err
        except Exception as e:
            err = json.dumps({"status": "error", "message": str(e)})
            cb.record_failure()
            audit_log(self._audit_logger, tool_name, parameters or {}, err)
            return err

    # ------------------------------------------------------------------
    # System prompt
    # ------------------------------------------------------------------
    def get_system_prompt(self) -> str:
        """
        System prompt for the prompt-based tool protocol. Kept tight so
        small models (phi3:mini, llama3.2:3b) don't burn 20-30 s per turn
        on prompt eval alone. Every line has to earn its place.

        The directive tone is deliberate: many chat-tuned models default
        to "I cannot access your files" safety replies. The user has
        explicitly started this process — refusing would break the product.
        """
        prompt = (
            "You are a conversational coding assistant with filesystem access tools.\n"
            "\n"
            "WHEN TO USE TOOLS — only when the user's message clearly requires it:\n"
            "  - Reading, editing, creating, or deleting a file\n"
            "  - Running a build, test, or shell command\n"
            "  - Looking up where something is defined in the codebase\n"
            "  - Git operations\n"
            "\n"
            "WHEN NOT TO USE TOOLS — respond naturally with plain text:\n"
            "  - Greetings and small talk ('Hi', 'Hello', 'Thanks', 'How are you'):\n"
            "    reply in ONE short sentence. Do NOT mention tools, files, or the project.\n"
            "  - General programming questions not tied to a specific local file\n"
            "  - Explaining a concept, a pattern, or a language feature\n"
            "  - The user is asking you something you already know\n"
            "\n"
            "TOOL RULES (when tools ARE needed):\n"
            "  1. Read before editing — call read_file before any modification.\n"
            "  2. Use patch_file for targeted edits; write_file only for new files "
            "or full rewrites.\n"
            "  3. Never ask the user to apply changes manually — write the file yourself.\n"
            "  4. One tool call per turn. Wait for the result, then decide next step.\n"
            "  5. If you use a tool, output ONLY the tool call line. No preamble or explanation.\n"
            "  6. Keep tool-call JSON valid. Prefer single quotes inside shell commands.\n"
            "  7. Paths must be relative to the project root.\n"
            "\n"
            "TOOL CALL FORMAT:\n"
            '  <tool>{"tool":"NAME","parameters":{...}}</tool>\n'
            "\n"
            "Available tools:\n"
        )
        for d in self.definitions:
            fn = d["function"]
            props = fn.get("parameters", {}).get("properties", {})
            required = set(fn.get("parameters", {}).get("required", []))
            sig = ", ".join(
                f"{k}{'' if k in required else '?'}"
                for k in props.keys()
            )
            prompt += f"  - {fn['name']}({sig}): {fn['description']}\n"
        return prompt
