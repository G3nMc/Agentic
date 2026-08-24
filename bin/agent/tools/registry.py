"""Tool registry: registration, strict protocol parsing, and sandboxed execution.

Responsibilities
----------------
* Own the canonical system prompt (base rules + optional task-flow protocol).
* Register AI-callable tools and render them as a catalog the model can read.
* Parse *only* the mandated ``<tool>...</tool>`` wire format, with no fuzzy fallbacks.
* Execute tools with path confinement, per-tool circuit breaking, and audit logging.
"""

from __future__ import annotations

import inspect
import json
import logging
import re
import threading
from pathlib import Path
from typing import (
    Any,
    Callable,
    Dict,
    Final,
    FrozenSet,
    List,
    Literal,
    Mapping,
    Optional,
    Tuple,
)

from agent.core.path_filter import PathFilter
from agent.core.policy import SecurityConfig
from agent.prompts import format_system_prompt, get_system_prompt_value
from agent.utils.audit import audit_log, setup_audit_logger
from agent.utils.circuit_breaker import CircuitBreaker

__all__ = ["ToolRegistry", "ResponseKind", "TaskMode"]

logger = logging.getLogger(__name__)

ToolFunc = Callable[..., Any]
ToolDefinition = Dict[str, Any]
ResponseKind = Literal["tool_call", "final_answer", "malformed"]
TaskMode = Literal["open", "task_compliance", "task_compliance_auto"]


# =====================================================================
# Prompts
# =====================================================================
# Prompt defaults and XML-backed overrides live in agent.prompts.
# =====================================================================
# Wire-format regexes
# =====================================================================

# The exact format the system prompt mandates: <tool>...</tool> with child tags.
# Anchored at both ends so any surrounding prose causes an immediate miss.
_STRICT_TOOL_RE: Final = re.compile(
    r"\A\s*<tool\s*>\s*(.*?)\s*</tool\s*>\s*\Z",
    re.DOTALL | re.IGNORECASE,
    )

# Lightweight heuristic: does the text contain ANY tool-like marker? Used only to
# decide whether to escalate to the malformed-call repair path.
_TOOL_MARKER_RE: Final = re.compile(
    r"<\s*/?\s*tool[\s>/]"
    r"|<\s*/?\s*tool_call[\s>/]"
    r"|<\s*/?\s*function_call[\s>/]"
    r"|<\s*/?\s*invoke[\s>/]"
    r"|\{\s*[\"']tool[\"']\s*:"
    r"|\{\s*[\"']name[\"']\s*:\s*[\"'][a-z_]+[\"']\s*,\s*[\"'](?:parameters|arguments)[\"']"
    r"|```\s*(?:json|tool|xml)\b",
    re.IGNORECASE,
)


# =====================================================================
# Category rules (data only -- no lambdas, so the table stays introspectable)
# =====================================================================

_EXACT_CATEGORIES: Final[Mapping[str, FrozenSet[str]]] = {
    "Filesystem": frozenset(
        {
            "read_file",
            "read_files",
            "write_file",
            "append_file",
            "patch_file",
            "delete_file",
            "delete_files",
            "move_file",
            "copy_file",
            "create_directory",
            "create_directories",
        }
    ),
    "Search": frozenset(
        {
            "list_files",
            "list_files_recursive",
            "search_in_files",
            "find_files",
            "grep",
        }
    ),
    "Shell": frozenset({"run_command", "run_commands"}),
    "Web": frozenset({"web_fetch", "web_search"}),
    "Database": frozenset({"db_query", "db_schema", "db_tables"}),
}

_PREFIX_CATEGORIES: Final[Tuple[Tuple[str, str], ...]] = (
    ("Git", "git_"),
    ("Flutter", "flutter_"),
    ("Dart", "dart_"),
    ("Python", "python_"),
    ("Node", "npm_"),
)

_FALLBACK_CATEGORY: Final[str] = "Other"

# Display order in the rendered catalog. Anything unlisted lands in "Other".
_CATEGORY_ORDER: Final[Tuple[str, ...]] = (
    "Filesystem",
    "Search",
    "Git",
    "Flutter",
    "Dart",
    "Python",
    "Node",
    "Shell",
    "Web",
    "Database",
    _FALLBACK_CATEGORY,
)

# Parameter names that hold a single path / a list of paths. Normalized to
# workspace-relative form before a tool ever sees them.
_PATH_PARAMS: Final[FrozenSet[str]] = frozenset(
    {"path", "file", "filename", "source", "destination", "src", "dst", "directory", "root", "cwd"}
)
_PATH_LIST_PARAMS: Final[FrozenSet[str]] = frozenset({"paths", "files", "sources", "targets"})

_MAX_AUDIT_VALUE_CHARS: Final[int] = 512


# =====================================================================
# Module-level helpers
# =====================================================================


def _error_result(message: str) -> str:
    """Serialize an error envelope the orchestrator and model both understand."""
    return json.dumps({"status": "error", "message": message}, ensure_ascii=False)


def _parse_tool_result(result: Any) -> Dict[str, Any]:
    """Best-effort decode of a tool's return value into a status envelope.

    A tool that returns a bare string (e.g. file contents) is treated as success;
    only an explicit ``{"status": "error"}`` counts as a failure for the breaker.
    """
    if isinstance(result, Mapping):
        return dict(result)
    if not isinstance(result, str):
        return {"status": "success"}
    try:
        parsed = json.loads(result)
    except (json.JSONDecodeError, ValueError, TypeError):
        return {"status": "success"}
    return parsed if isinstance(parsed, dict) else {"status": "success"}


def _stringify_result(result: Any) -> str:
    """Normalize any tool return value to the string contract of ``execute``."""
    if isinstance(result, str):
        return result
    if result is None:
        return json.dumps({"status": "success"}, ensure_ascii=False)
    if isinstance(result, (Mapping, list, tuple, int, float, bool)):
        try:
            return json.dumps(result, ensure_ascii=False, default=str)
        except (TypeError, ValueError):
            pass
    return json.dumps({"status": "success", "result": str(result)}, ensure_ascii=False)


def _audit_safe(params: Mapping[str, Any]) -> Dict[str, Any]:
    """Truncate bulky values so file bodies never bloat the audit log."""
    safe: Dict[str, Any] = {}
    for key, value in params.items():
        if isinstance(value, str) and len(value) > _MAX_AUDIT_VALUE_CHARS:
            safe[key] = f"{value[:_MAX_AUDIT_VALUE_CHARS]}... [{len(value)} chars total]"
        elif isinstance(value, (list, tuple)) and len(value) > 20:
            safe[key] = list(value[:20]) + [f"... [{len(value)} items total]"]
        else:
            safe[key] = value
    return safe


# =====================================================================
# Registry
# =====================================================================


class ToolRegistry:
    """Manages AI-callable tools with path confinement, auditing, and circuit breaking.

    Every filesystem-touching tool receives workspace-relative paths only; escape
    attempts are rejected in :meth:`resolve_path` before any I/O happens. Instances
    are safe to share across threads.
    """

    CIRCUIT_BREAKER_CONFIG: Final[Mapping[str, float]] = {
        "failure_threshold": 5,
        "recovery_timeout": 30.0,
    }

    DEFAULT_TIMEOUT: Final[float] = 30.0

    TOOL_TIMEOUTS: Final[Mapping[str, float]] = {
        "read_file": 20.0,
        "read_files": 60.0,
        "write_file": 20.0,
        "append_file": 20.0,
        "delete_file": 10.0,
        "delete_files": 30.0,
        "patch_file": 25.0,
        "move_file": 20.0,
        "create_directory": 10.0,
        "create_directories": 20.0,
        "list_files": 60.0,
        "list_files_recursive": 125.0,
        "search_in_files": 60.0,
        "find_files": 60.0,
        "git_status": 10.0,
        "git_branches": 5.0,
        "git_log": 10.0,
        "git_diff": 15.0,
        "git_checkout": 10.0,
        "git_commit": 15.0,
        "flutter_analyze": 45.0,
        "python_check": 30.0,
        "python_lint": 30.0,
        "python_format": 30.0,
        "python_test": 60.0,
        "run_command": 30.0,
        "web_fetch": 20.0,
        "web_search": 20.0,
    }

    def __init__(
            self,
            base_path: str | Path = ".",
            security_config: Optional[SecurityConfig] = None,
            path_filter: Optional[PathFilter] = None,
            db_connections: Optional[Dict[str, Dict[str, str]]] = None,
    ) -> None:
        self.base_path = Path(base_path).expanduser().resolve()
        self.security_config = security_config or SecurityConfig()
        self.path_filter = path_filter or PathFilter(base_path=self.base_path)
        self.db_connections = db_connections or {}

        self._audit_logger = setup_audit_logger(self.security_config)
        self._lock = threading.RLock()
        self._breakers: Dict[str, CircuitBreaker] = {}
        self._category_cache: Dict[str, str] = {}
        self._catalog_cache: Optional[str] = None

        self.tools: Dict[str, ToolFunc] = {}
        self.definitions: List[ToolDefinition] = []

        # Mutable per-instance copy so callers can tune individual timeouts.
        self.tool_timeouts: Dict[str, float] = dict(self.TOOL_TIMEOUTS)

        # Optional policy hook: tools the security config forbids outright.
        self.blocked_tools: set[str] = set(getattr(self.security_config, "blocked_tools", ()) or ())

        # Local import: the tool modules import this class, so this must stay lazy.
        from . import collect_all_tools

        collect_all_tools(self)

    def __contains__(self, name: object) -> bool:
        return isinstance(name, str) and name in self.tools

    def __len__(self) -> int:
        return len(self.tools)

    def __repr__(self) -> str:  # pragma: no cover - debug aid
        return f"<ToolRegistry base={self.base_path} tools={len(self.tools)}>"

    # ------------------------------------------------------------------
    # Path helpers
    # ------------------------------------------------------------------

    def resolve_path(self, path: str | Path) -> Path:
        """Resolve *path* against the workspace root, refusing anything outside it.

        Uses real path containment (not string prefixing), so a sibling directory
        named like the workspace plus a suffix cannot be reached, and symlinks that
        point outward are rejected after resolution.
        """
        raw = str(path).strip()
        candidate = self.base_path if not raw else (self.base_path / raw)
        resolved = candidate.expanduser().resolve()

        if resolved != self.base_path and not resolved.is_relative_to(self.base_path):
            raise ValueError(
                f"Access denied: '{path}' resolves outside the workspace "
                f"('{self.base_path}'). Use relative paths inside the project."
            )
        return resolved

    def is_within_workspace(self, path: str | Path) -> bool:
        """Non-raising variant of :meth:`resolve_path`."""
        try:
            self.resolve_path(path)
        except (ValueError, OSError):
            return False
        return True

    def _relativise_path(self, path: str) -> str:
        """Rewrite an absolute in-workspace path as workspace-relative."""
        try:
            candidate = Path(path)
        except (TypeError, ValueError):
            return path
        if not candidate.is_absolute():
            return path
        try:
            return candidate.resolve().relative_to(self.base_path).as_posix() or "."
        except (ValueError, OSError):
            return path

    def relativise(self, params: Mapping[str, Any]) -> Dict[str, Any]:
        """Normalize every known path-bearing parameter to relative form."""
        normalized: Dict[str, Any] = dict(params)
        for key, value in params.items():
            if key in _PATH_PARAMS and isinstance(value, str):
                normalized[key] = self._relativise_path(value)
            elif key in _PATH_LIST_PARAMS and isinstance(value, (list, tuple)):
                normalized[key] = [
                    self._relativise_path(item) if isinstance(item, str) else item
                    for item in value
                ]
        return normalized

    # ------------------------------------------------------------------
    # Registration
    # ------------------------------------------------------------------

    def register_tool(
            self,
            name: str,
            func: ToolFunc,
            definition: ToolDefinition,
            timeout: Optional[float] = None,
    ) -> None:
        """Register a tool implementation plus its OpenAPI-style definition.

        Re-registering an existing name replaces both the callable and the
        definition, so the rendered catalog never lists a tool twice.
        """
        if not name or not callable(func):
            raise ValueError(f"Invalid tool registration for {name!r}")

        with self._lock:
            self.tools[name] = func
            self.definitions = [d for d in self.definitions if self._definition_name(d) != name]
            self.definitions.append(definition)
            if timeout is not None:
                self.tool_timeouts[name] = timeout
            self._invalidate_caches()

    def unregister(self, name: str) -> bool:
        """Remove a tool. Returns ``True`` if it existed."""
        with self._lock:
            existed = self.tools.pop(name, None) is not None
            before = len(self.definitions)
            self.definitions = [d for d in self.definitions if self._definition_name(d) != name]
            if existed or len(self.definitions) != before:
                self._invalidate_caches()
            return existed

    def get_timeout(self, name: str) -> float:
        """Timeout for *name*, falling back to :attr:`DEFAULT_TIMEOUT`."""
        return self.tool_timeouts.get(name, self.DEFAULT_TIMEOUT)

    def tool_names(self) -> List[str]:
        return sorted(self.tools)

    def _invalidate_caches(self) -> None:
        self._category_cache.clear()
        self._catalog_cache = None

    @staticmethod
    def _definition_name(definition: Mapping[str, Any]) -> str:
        function = definition.get("function")
        if isinstance(function, Mapping):
            return str(function.get("name", ""))
        return str(definition.get("name", ""))

    def _get_tool_category(self, name: str) -> str:
        """Classify a tool name; exact matches win over prefix rules."""
        cached = self._category_cache.get(name)
        if cached is not None:
            return cached

        category = _FALLBACK_CATEGORY
        for candidate, members in _EXACT_CATEGORIES.items():
            if name in members:
                category = candidate
                break
        else:
            for candidate, prefix in _PREFIX_CATEGORIES:
                if name.startswith(prefix):
                    category = candidate
                    break

        self._category_cache[name] = category
        return category

    # ------------------------------------------------------------------
    # Response classification and strict parsing
    # ------------------------------------------------------------------

    def strict_parse_tool_call(self, text: str) -> Optional[Tuple[str, Dict[str, Any]]]:
        """Parse ONLY the mandated ``<tool>...</tool>`` format.

        Returns ``(tool_name, parameters)`` for a well-formed call to a *known*
        tool, else ``None``. No fuzzy matching and no repair — recovery is the
        malformed-call path's job.
        """
        if not text or "<tool" not in text.lower():
            return None

        match = _STRICT_TOOL_RE.match(text)
        if not match:
            return None
        body = match.group(1)
        if not body:
            return None

        # PRIMARY: XML child-tag format (what the prompt mandates).
        parsed = self._parse_xml_body(body)
        if parsed is not None:
            return parsed

        # FALLBACK: legacy JSON-in-tags format, kept for older transcripts.
        return self._parse_json_body(body)

    def _parse_xml_body(self, body: str) -> Optional[Tuple[str, Dict[str, Any]]]:
        # Local import breaks the tool_dispatch <-> registry import cycle.
        from agent.loop.tool_dispatch import parse_tool_call

        try:
            result = parse_tool_call(body, self.definitions)
        except Exception:  # noqa: BLE001 - a parser crash must not kill the turn
            logger.debug("XML tool-call parser raised; treating as unparsed", exc_info=True)
            return None

        if not result:
            return None
        name, params = result
        if not isinstance(name, str) or name not in self.tools:
            return None
        return name, dict(params) if isinstance(params, Mapping) else {}

    def _parse_json_body(self, body: str) -> Optional[Tuple[str, Dict[str, Any]]]:
        try:
            data = json.loads(body)
        except (json.JSONDecodeError, ValueError):
            return None
        if not isinstance(data, dict):
            return None

        name = data.get("tool") or data.get("name")
        if not isinstance(name, str) or name not in self.tools:
            return None

        params = data.get("parameters", data.get("arguments", {}))
        return name, dict(params) if isinstance(params, Mapping) else {}

    def classify_response(self, text: str) -> ResponseKind:
        """Classify a model reply without running the full repair chain.

        * ``tool_call``    — strict format matched a known tool; ready to execute.
        * ``final_answer`` — no tool markers; treat the reply as prose.
        * ``malformed``    — tool-like markers present but strict parsing failed;
          escalate to the malformed-call repair path.
        """
        if not text or not text.strip():
            return "final_answer"
        if self.strict_parse_tool_call(text) is not None:
            return "tool_call"
        if _TOOL_MARKER_RE.search(text):
            return "malformed"
        return "final_answer"

    @staticmethod
    def is_empty_response(text: Optional[str]) -> bool:
        """True when the model returned nothing usable (retry-worthy)."""
        return not text or not text.strip()

    # ------------------------------------------------------------------
    # Execution
    # ------------------------------------------------------------------

    def execute(self, tool_name: str, parameters: Optional[Mapping[str, Any]] = None) -> str:
        """Run a tool and return its result as a string.

        Handles policy checks, circuit breaking, path normalization, parameter
        validation, structured error reporting, and auditing. Never raises: every
        failure comes back as an ``{"status": "error"}`` envelope.
        """
        params: Dict[str, Any] = dict(parameters or {})

        if tool_name not in self.tools:
            return self._reject(
                tool_name,
                params,
                f"Unknown tool: '{tool_name}'. Available: {', '.join(self.tool_names())}",
            )

        if tool_name in self.blocked_tools:
            return self._reject(
                tool_name, params, f"Tool '{tool_name}' is disabled by security policy."
            )

        breaker = self._breaker_for(tool_name)
        if not breaker.allow_request():
            recovery = getattr(breaker, "recovery_timeout", self.CIRCUIT_BREAKER_CONFIG["recovery_timeout"])
            return self._reject(
                tool_name,
                params,
                f"Tool '{tool_name}' is temporarily disabled after repeated failures. "
                f"Recovers in ~{float(recovery):.0f}s. Use a different approach meanwhile.",
            )

        func = self.tools[tool_name]
        safe_params = self.relativise(params)

        # Validate the call signature BEFORE invoking, so a TypeError raised inside
        # the tool body is never misreported as "invalid parameters" -- and so the
        # model's own malformed calls do not trip the breaker for a healthy tool.
        signature_error = self._check_signature(func, safe_params)
        if signature_error is not None:
            return self._reject(
                tool_name,
                safe_params,
                f"Invalid parameters for '{tool_name}': {signature_error}. "
                f"Expected: {tool_name}({self.signature_of(tool_name)}).",
                record_failure=False,
            )

        try:
            result = _stringify_result(func(**safe_params))
        except ValueError as exc:
            return self._reject(tool_name, safe_params, f"Path or value error: {exc}", breaker=breaker)
        except (OSError, PermissionError) as exc:
            return self._reject(tool_name, safe_params, f"Filesystem error: {exc}", breaker=breaker)
        except Exception as exc:  # noqa: BLE001 - a tool crash must not kill the loop
            logger.exception("Tool '%s' raised", tool_name)
            return self._reject(
                tool_name, safe_params, f"{type(exc).__name__}: {exc}", breaker=breaker
            )

        if _parse_tool_result(result).get("status") == "error":
            breaker.record_failure()
        else:
            breaker.record_success()

        audit_log(self._audit_logger, tool_name, _audit_safe(safe_params), result)
        return result

    def _breaker_for(self, tool_name: str) -> CircuitBreaker:
        with self._lock:
            breaker = self._breakers.get(tool_name)
            if breaker is None:
                breaker = CircuitBreaker(
                    name=f"tool:{tool_name}",
                    failure_threshold=int(self.CIRCUIT_BREAKER_CONFIG["failure_threshold"]),
                    recovery_timeout=float(self.CIRCUIT_BREAKER_CONFIG["recovery_timeout"]),
                )
                self._breakers[tool_name] = breaker
            return breaker

    @staticmethod
    def _check_signature(func: ToolFunc, params: Mapping[str, Any]) -> Optional[str]:
        """Return an error message if *params* cannot bind to *func*, else ``None``."""
        try:
            inspect.signature(func).bind(**params)
        except TypeError as exc:
            return str(exc)
        except (ValueError, KeyError):
            # Builtins / C-extensions expose no signature: let the call decide.
            return None
        return None

    def _reject(
            self,
            tool_name: str,
            params: Mapping[str, Any],
            message: str,
            *,
            breaker: Optional[CircuitBreaker] = None,
            record_failure: bool = True,
    ) -> str:
        """Build, audit, and return an error envelope in one step."""
        if breaker is not None and record_failure:
            breaker.record_failure()
        error = _error_result(message)
        audit_log(self._audit_logger, tool_name, _audit_safe(params), error)
        return error

    # ------------------------------------------------------------------
    # System prompt generation
    # ------------------------------------------------------------------

    def get_system_prompt(
            self,
            project_context: Optional[str] = None,
            task_mode: TaskMode | str = "open",
    ) -> str:
        """Assemble the full system prompt: base rules, context, protocol, catalog.

        ``project_context`` (typically the contents of ``.agent.md``) is inserted
        between the base rules and the tool catalog. ``task_mode`` of
        ``task_compliance`` / ``task_compliance_auto`` appends the TASK FLOW
        PROTOCOL section; ``open`` omits it entirely.
        """
        sections: List[str] = [get_system_prompt_value("BASE_PROMPT").strip()]

        if project_context and project_context.strip():
            sections.append(
                format_system_prompt(
                    "PROJECT_CONTEXT_HEADER_TEMPLATE",
                    project_context=project_context.strip(),
                )
            )

        if task_mode in ("task_compliance", "task_compliance_auto"):
            sections.append(self._task_flow_prompt(auto=task_mode == "task_compliance_auto"))

        sections.append(self._tool_catalog())
        return "\n\n".join(sections)

    def _tool_catalog(self) -> str:
        """Render the tool catalog, grouped and alphabetized (cached per revision)."""
        if self._catalog_cache is not None:
            return self._catalog_cache

        grouped: Dict[str, List[str]] = {}
        for definition in self.definitions:
            function = definition.get("function")
            function = function if isinstance(function, Mapping) else definition
            name = str(function.get("name") or "unknown")
            description = " ".join(str(function.get("description") or "").split())
            entry = f"- {name}({self._format_signature(function)})"
            if description:
                entry = f"{entry}: {description}"
            grouped.setdefault(self._get_tool_category(name), []).append(entry)

        parts: List[str] = [get_system_prompt_value("TOOL_CATALOG_HEADER")]
        rendered_any = False
        known = set(_CATEGORY_ORDER)
        ordered = list(_CATEGORY_ORDER) + sorted(set(grouped) - known)

        for category in ordered:
            entries = grouped.get(category)
            if not entries:
                continue
            rendered_any = True
            parts.append(f"[{category}]\n" + "\n".join(sorted(entries)))

        if not rendered_any:
            if self.tools:
                parts.append(
                    "(No tool definitions registered; callables available: "
                    + ", ".join(self.tool_names())
                    + ")"
                )
            else:
                parts.append("(No tools registered — answer directly, do not emit tool calls.)")

        catalog = "\n\n".join(parts)
        self._catalog_cache = catalog
        return catalog

    @staticmethod
    def _task_flow_prompt(auto: bool) -> str:
        """Task-flow protocol section, parsed downstream by ``common.loop.task_protocol``."""
        hint_key = "PROCEED_HINT_AUTO" if auto else "PROCEED_HINT_MANUAL"
        hint = get_system_prompt_value(hint_key)
        return (
            get_system_prompt_value("TASK_FLOW_PROMPT")
            .strip()
            .replace("__PROCEED_HINT__", hint)
        )

    @staticmethod
    def _base_system_prompt() -> List[str]:
        """Immutable base prompt (no tools). Kept for backward compatibility."""
        return [get_system_prompt_value("BASE_PROMPT").strip()]

    def signature_of(self, tool_name: str) -> str:
        """Human-readable signature for *tool_name*, or ``unknown tool``."""
        for definition in self.definitions:
            function = definition.get("function")
            function = function if isinstance(function, Mapping) else definition
            if function.get("name") == tool_name:
                return self._format_signature(function)
        return "unknown tool"

    @staticmethod
    def _format_signature(function: Mapping[str, Any]) -> str:
        """Format an OpenAPI-style parameter spec as ``name:type, opt?:type``.

        Required parameters are listed first so the model sees them even if the
        line is truncated by a context squeeze.
        """
        parameters = function.get("parameters") or {}
        properties = parameters.get("properties") or {}
        if not properties:
            return "no parameters"

        required = set(parameters.get("required") or ())
        required_parts: List[str] = []
        optional_parts: List[str] = []

        for key, spec in properties.items():
            spec = spec if isinstance(spec, Mapping) else {}
            type_name = spec.get("type") or "any"
            if isinstance(type_name, (list, tuple)):
                type_name = "|".join(str(item) for item in type_name)
            if type_name == "array":
                items = spec.get("items")
                item_type = (items or {}).get("type") if isinstance(items, Mapping) else None
                type_name = f"array[{item_type or 'any'}]"

            if key in required:
                required_parts.append(f"{key}:{type_name}")
            else:
                optional_parts.append(f"{key}?:{type_name}")

        return ", ".join(required_parts + optional_parts)
