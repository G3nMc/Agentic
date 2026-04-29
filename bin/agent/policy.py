# """Operational policy applied by the tool registry.
#
# Kept as its own module (not under utils/) because this is policy, not
# infrastructure: changing it changes what the agent is allowed to do.
# """
# from __future__ import annotations
#
# import dataclasses
#
#
# @dataclasses.dataclass
# class SecurityConfig:
#     """
#     Operational policy applied by ToolRegistry.
#
#     sandbox_mode         -- when True, run_command is completely disabled
#                            and write/delete operations are blocked.
#                            Default: False — the agent operates with full
#                            freedom inside base_path; git is the safety net.
#     max_file_size_bytes  -- hard cap on content written by write_file /
#                            append_file. 0 means no limit (default).
#     enable_audit_log     -- when True, every tool call is appended to
#                            audit_log_path with timestamp, tool name,
#                            sanitized parameters, and result status.
#     audit_log_path       -- destination file for audit entries.
#     command_blocklist    -- substrings that must never appear in a
#                            run_command call (case-insensitive match).
#                            Default: empty — no commands are blocked.
#     """
#     sandbox_mode: bool = False
#     max_file_size_bytes: int = 0          # 0 = no limit
#     enable_audit_log: bool = True
#     audit_log_path: str = "orchestrator_audit.log"
#     command_blocklist: tuple = dataclasses.field(default_factory=tuple)


from __future__ import annotations
import dataclasses
from typing import Set, Optional

@dataclasses.dataclass
class SecurityConfig:
    """
    Operational policy for ToolRegistry, defining what the agent is allowed to do.

    Attributes:
        sandbox_mode: If True, disables all command execution and write/delete operations.
            Default: False (agent has full freedom within base_path).
        max_file_size_bytes: Hard cap on content size for write_file/append_file. 0 = no limit.
        enable_audit_log: If True, logs all tool calls to audit_log_path.
        audit_log_path: Path to the audit log file.
        command_blocklist: Substrings that must never appear in run_command calls (case-insensitive).
        allowed_file_extensions: If set, only files with these extensions can be read/written.
    """
    sandbox_mode: bool = False
    max_file_size_bytes: int = 0  # 0 = no limit
    enable_audit_log: bool = True
    audit_log_path: str = "orchestrator_audit.log"
    command_blocklist: Set[str] = dataclasses.field(default_factory=set)
    allowed_file_extensions: Optional[Set[str]] = None