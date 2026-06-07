"""Per-tool audit logging — sanitized parameter capture + status tracking."""

from __future__ import annotations

import json
import logging
import os
import sys
from typing import Any, Dict, Optional

from ..policy import SecurityConfig


def sanitize_params_for_log(tool_name: str, params: Dict[str, Any]) -> Dict[str, Any]:
    """
    Remove or truncate large / sensitive parameter values before audit logging.
    The `content` field of write_file / append_file can be megabytes long and
    may contain secrets — replace it with a byte-count placeholder.
    """
    if not params:
        return params
    sanitized = dict(params)
    for key in ("content", "old_content", "new_content"):
        if key in sanitized:
            val = sanitized[key]
            if isinstance(val, str):
                sanitized[key] = f"<{len(val.encode('utf-8'))} bytes>"
            else:
                sanitized[key] = "<non-string>"
    return sanitized


def setup_audit_logger(config: SecurityConfig) -> Optional[logging.Logger]:
    """
    Create (or reuse) a dedicated file logger for tool-call audit records.
    Returns None when audit logging is disabled in the config.
    """
    if not config.enable_audit_log:
        return None
    logger_name = f"orchestrator.audit.{config.audit_log_path}"
    logger = logging.getLogger(logger_name)
    if not logger.handlers:
        try:
            log_dir = os.path.dirname(config.audit_log_path)
            if log_dir:
                os.makedirs(log_dir, exist_ok=True)
            handler = logging.FileHandler(config.audit_log_path, encoding="utf-8")
            handler.setFormatter(
                logging.Formatter(
                    "%(asctime)s %(message)s", datefmt="%Y-%m-%dT%H:%M:%S"
                )
            )
            logger.addHandler(handler)
            logger.setLevel(logging.INFO)
            logger.propagate = False
        except OSError as e:
            print(
                f"[audit] Cannot open audit log '{config.audit_log_path}': {e}",
                file=sys.stderr,
            )
            return None
    return logger


def audit_log(
    logger: Optional[logging.Logger],
    tool_name: str,
    params: Dict[str, Any],
    result: str,
) -> None:
    """Append one structured line to the audit log."""
    if logger is None:
        return
    sanitized = sanitize_params_for_log(tool_name, params)
    try:
        result_obj = json.loads(result)
        status = result_obj.get("status", "unknown")
    except Exception:
        status = "unknown"
    logger.info("TOOL=%s PARAMS=%s STATUS=%s", tool_name, json.dumps(sanitized), status)
