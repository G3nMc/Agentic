#!/usr/bin/env python3
"""
Multi-slot Orchestrator — entry point for Workflow Agents (multi-slot) mode.
==============================================================

The Workflow Agents panel configures two model slots:

  * REASONER ("Assistant") — drives the tool loop and produces the answer.
  * USER ("User")          — the second Workflow Agents slot. When present it
                             reviews the Assistant's work in AUTO INPUT mode on
                             its own model and context, so the Assistant never
                             judges its own output.

The tool loop itself lives in :mod:`agent.loop.run_loop` — the same loop the
single-agent ``orchestrator.py`` uses — so this entry point only maps the
Workflow Agents settings onto backends and speaks the stdin/stdout protocol
the Flutter UI expects.

Protocol (when run with --interactive, used by the Flutter UI):
  - The client writes exactly one JSON object per line to stdin:
      {"prompt": "...", "new_session": true|false, "history": [...],
       "task_mode": "open|user_input|auto_input", "thinking": bool,
       "effort": "minimal|low|medium|high|max"}
  - The orchestrator answers with the full text response on stdout, followed
    by a single line containing exactly `__RESPONSE_END__`.
  - Diagnostics go to stderr so they don't corrupt the response stream.

Other modes:
  --install-deps   Install required Python dependencies and exit.
  (no flag)        Read one prompt from stdin (raw text), answer once, exit.

Usage:
  python orchestrator_multi.py --reasoner-provider openai --reasoner-model gpt-4o --interactive
  python orchestrator_multi.py --reasoner-provider ollama --reasoner-model llama3:8b
"""

from __future__ import annotations

import os
import sys

# Disable .pyc generation for every module imported below.
sys.dont_write_bytecode = True

# Make ``import agent`` / ``import orchestrator_base`` resolve whether this
# script is launched as ``python bin/orchestrator_multi.py`` or from bin/
# itself (the Flutter client uses the latter).
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_PROJECT_ROOT = os.path.dirname(_THIS_DIR)
for _entry in (_THIS_DIR, _PROJECT_ROOT):
    if _entry not in sys.path:
        sys.path.insert(0, _entry)

import argparse  # noqa: E402  (imports follow the sys.path bootstrap above)
import json  # noqa: E402
import subprocess  # noqa: E402
from typing import Any, Dict, Optional  # noqa: E402

from agent.backends import RateLimitedBackend, build_backend  # noqa: E402
from agent.core.policy import SecurityConfig  # noqa: E402
from agent.loop.run_loop import (  # noqa: E402
    _DEFAULT_MAX_AUTO_ROUNDS,
    Orchestrator,
)
from agent.loop.task_protocol import TaskMode  # noqa: E402
from agent.prompts import sync_prompts_config  # noqa: E402
from agent.utils.io_protocol import (  # noqa: E402
    RESPONSE_SENTINEL,
    configure_stdio_utf8,
    read_interactive_request,
)

# Shared helpers between the two CLI orchestrators. The two ``_load_*`` names
# are rebound to multi-mode wrappers below so the historical "[orch_multi]"
# log prefix survives without touching call sites.
from orchestrator_base import (  # noqa: E402
    _append_debug_response,
    _build_user_backend_for_args,
    _build_user_generation_defaults,
    _load_db_connections as _base_load_db_connections,
    _load_path_filter as _base_load_path_filter,
    _normalise_external_history,
    _read_last_user_turn,
    _resolve_debug_chat_path,
)


def _load_path_filter(filters_config_path: str, base_path: str):
    """Multi-mode wrapper preserving the historical ``[orch_multi]`` log prefix."""
    return _base_load_path_filter(filters_config_path, base_path, log_prefix="orch_multi")


def _load_db_connections(config_path: str):
    """Multi-mode wrapper preserving the historical ``[orch_multi]`` log prefix."""
    return _base_load_db_connections(config_path, log_prefix="orch_multi")


configure_stdio_utf8()


def _install_dependencies() -> None:
    """Install the single HTTP dependency every backend needs.

    After the SDK-free refactor every model backend talks to its provider via
    plain REST through ``requests``. No provider SDK is required anymore.
    """
    packages = [
        "requests",
    ]
    python_exe = sys.executable
    for pkg in packages:
        print(f"[deps] Installing {pkg}...", file=sys.stderr)
        try:
            subprocess.check_call(
                [python_exe, "-m", "pip", "install", "--user", pkg],
                stdout=sys.stderr,
                stderr=sys.stderr,
            )
        except subprocess.CalledProcessError as ex:
            print(f"[deps] Failed to install {pkg}: {ex}", file=sys.stderr)
            sys.exit(1)
    print("[deps] All dependencies installed.", file=sys.stderr)


# ======================================================================
# Workflow Agents slot -> backend mapping
# ======================================================================

# ``build_backend`` only accepts a custom ``base_url`` for these providers;
# the OpenAI-compatible subclasses (groq / github / huggingface) pin their own
# endpoint and would raise TypeError on an unexpected keyword.
_BASE_URL_PROVIDERS = frozenset({"ollama", "openrouter", "gemini"})

# Providers that take an explicit context window. Ollama maps it to num_ctx
# (KV-cache RAM), OpenRouter to the catalog context_length.
_CONTEXT_WINDOW_PROVIDERS = frozenset({"ollama", "openrouter"})

# Environment fallbacks per provider, mirroring orchestrator_base.
_API_KEY_ENV_VARS: Dict[str, tuple] = {
    "huggingface": ("HF_TOKEN",),
    "ollama": ("OLLAMA_API_KEY",),
    "gemini": ("GEMINI_API_KEY", "GOOGLE_API_KEY"),
    "groq": ("GROQ_API_KEY",),
    "openrouter": ("OPENROUTER_API_KEY",),
    "github": ("GITHUB_TOKEN", "GITHUB_API_KEY"),
}


def _resolve_api_key(provider: str, api_key: str) -> str:
    """Return *api_key*, falling back to the provider's env var(s)."""
    key = (api_key or "").strip()
    if key:
        return key
    for env_name in _API_KEY_ENV_VARS.get(provider, ()):
        value = (os.environ.get(env_name) or "").strip()
        if value:
            return value
    return ""


def _build_slot_backend(
        provider: str,
        model: str,
        api_key: str,
        base_url: str,
        context_window: Optional[int],
        slot_label: str,
):
    """Build the backend for one Workflow Agents slot.

    Returns ``None`` (after logging why) when the slot has no model, names an
    unknown provider, or the provider rejects the configuration — the caller
    then falls back to the next slot instead of aborting the session.
    """
    provider = (provider or "").strip().lower()
    model = (model or "").strip()
    if not provider or not model:
        print(
            f"[orch_multi] {slot_label} slot has no provider/model configured.",
            file=sys.stderr, flush=True,
        )
        return None

    kwargs: Dict[str, Any] = {"model_id": model}
    key = _resolve_api_key(provider, api_key)
    if key:
        kwargs["api_key"] = key

    url = (base_url or "").strip()
    if url and provider in _BASE_URL_PROVIDERS:
        kwargs["base_url"] = url

    if context_window:
        if provider == "ollama":
            kwargs["num_ctx"] = int(context_window)
        elif provider == "openrouter":
            kwargs["context_limit"] = int(context_window)
        else:
            print(
                f"[orch_multi] {slot_label}: context_window={context_window} "
                f"ignored by {provider} (managed by the provider).",
                file=sys.stderr, flush=True,
            )

    try:
        backend = build_backend(provider, **kwargs)
    except Exception as ex:  # noqa: BLE001 - a broken slot must not kill startup
        print(
            f"[orch_multi] Could not build {slot_label} backend "
            f"({provider}:{model}): {ex}",
            file=sys.stderr, flush=True,
        )
        return None

    print(
        f"[orch_multi] {slot_label} backend ready: {provider}:{model}",
        file=sys.stderr, flush=True,
    )
    return backend


def _apply_tpm_limit(backend, tpm_limit: int, slot_label: str):
    """Wrap *backend* in a RateLimitedBackend when a TPM cap was configured.

    Returns *backend* unchanged for ``tpm_limit <= 0`` (the default), so an
    unconfigured slot keeps the exact behaviour it had before the per-role cap
    existed.
    """
    limit = int(tpm_limit or 0)
    if backend is None or limit <= 0:
        return backend
    wrapped = RateLimitedBackend(backend, tpm_limit=limit, label=slot_label)
    print(
        f"[orch_multi] {slot_label} TPM rate limiter active: {limit} tokens/min "
        f"(effective {int(limit * 0.95)}).",
        file=sys.stderr, flush=True,
    )
    return wrapped


def _create_orchestrator(
        args,
        path_filter=None,
        db_connections=None,
        task_mode: str = "open",
) -> Orchestrator:
    """Build the run-loop Orchestrator that drives this session.

    The REASONER slot (the Workflow Agents "Assistant") drives the session and
    is the only driver: no second slot can take over.

    Raises :class:`RuntimeError` when its backend cannot be built — the caller
    converts that into an error reply instead of letting the process die.
    """
    backend = _build_slot_backend(
        args.reasoner_provider,
        args.reasoner_model,
        args.reasoner_api_key,
        args.reasoner_base_url,
        args.reasoner_context_window,
        "REASONER",
    )
    driver_label = "REASONER (Workflow Agents Assistant)"
    if backend is None:
        raise RuntimeError(
            "No usable model backend. Configure the Assistant (REASONER) slot "
            "in Settings -> Workflow Agents MaM."
        )

    # AUTO INPUT "User" agent (second Workflow Agents slot). When it is absent
    # the run loop fails safe: one answer plus the missing-agent notice.
    user_backend = _build_user_backend_for_args(args, log_prefix="orch_multi")
    if user_backend is None:
        print(
            "[orch_multi] No User agent configured; AUTO INPUT stops after one "
            "answer and waits for real input.",
            file=sys.stderr, flush=True,
        )
    else:
        print(
            f"[orch_multi] AUTO INPUT User agent -> "
            f"{getattr(user_backend, 'model_id', '(unknown)')}",
            file=sys.stderr, flush=True,
        )
        # Per-slot TPM cap. 0 (the default) leaves the backend untouched.
        user_backend = _apply_tpm_limit(
            user_backend,
            getattr(args, "user_tpm_limit", 0),
            "USER",
        )

    # Generation knobs for the User slot, forwarded from the matching
    # ``--user-*`` flags. Unset values keep the loop's documented fallbacks so
    # an unconfigured slot behaves exactly as it did before.
    user_defaults = _build_user_generation_defaults(args)
    if user_backend is not None:
        print(
            f"[orch_multi] User agent generation: "
            f"temperature={user_defaults.temperature}, "
            f"max_tokens={user_defaults.max_tokens or 'default'}, "
            f"effort={user_defaults.effort or 'default'}, "
            f"thinking={user_defaults.thinking}",
            file=sys.stderr, flush=True,
        )

    orchestrator = Orchestrator(
        backend=backend,
        base_path=args.base_path,
        temperature=float(args.temperature),
        max_tokens=int(args.max_tokens),
        security_config=SecurityConfig(sandbox_mode=bool(getattr(args, "sandbox", False))),
        disable_tools=bool(getattr(args, "disable_tools", False)),
        path_filter=path_filter,
        db_connections=db_connections,
        task_mode=task_mode,
        effort=(args.reasoning_level or None),
        max_iterations=int(args.max_iterations),
        max_auto_rounds=int(
            getattr(args, "max_agent_rounds", _DEFAULT_MAX_AUTO_ROUNDS)
        ),
        user_backend=user_backend,
        user_temperature=user_defaults.temperature,
        user_max_tokens=user_defaults.max_tokens,
        user_effort=user_defaults.effort,
        user_thinking=user_defaults.thinking,
    )
    orchestrator.driver_label = driver_label

    print(
        f"[orch_multi] Session driver: {driver_label} "
        f"({getattr(backend, 'model_id', '(unknown)')}), "
        f"task_mode={orchestrator.task_mode.value}, "
        f"max_auto_rounds={orchestrator.max_auto_rounds}.",
        file=sys.stderr, flush=True,
    )
    if bool(getattr(args, "sandbox", False)):
        print(
            "[orch_multi] SANDBOX MODE: write/delete/run_command are disabled.",
            file=sys.stderr, flush=True,
        )
    if bool(getattr(args, "disable_tools", False)):
        print(
            "[orch_multi] Tools disabled — running in plain-chat mode.",
            file=sys.stderr, flush=True,
        )
    return orchestrator


def _run_interactive_loop(args, path_filter=None, db_connections=None) -> None:
    """Interactive loop (JSON-per-line protocol) driven by the REASONER slot."""

    # Ensure stdout is line-buffered so the Flutter side sees __READY__ immediately.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(line_buffering=True)
    print("__READY__", flush=True)
    print("[orch_multi] Ready for requests.", file=sys.stderr, flush=True)

    debug_mode = bool(getattr(args, "is_debug", False))
    debug_chat_path = (
        _resolve_debug_chat_path(args.base_path, args.file_name) if debug_mode else ""
    )
    if debug_mode:
        print(
            f"[orch_multi] DEBUG MODE active. Chat file: {debug_chat_path}",
            file=sys.stderr, flush=True,
        )

    orchestrator: Optional[Orchestrator] = None
    try:
        while True:
            req = read_interactive_request(sys.stdin)
            if req is None:
                break  # EOF
            # Control line: the client is shutting the session down. Leave the
            # read loop cleanly so the audit log and chat log are flushed.
            if req.get("action") == "shutdown":
                break
            request_id = req.get("request_id")

            history = _normalise_external_history(req.get("history"))
            prompt = (req.get("prompt") or "").strip()

            # Debug mode: ignore the incoming prompt and read the latest user
            # turn from the chat file, so a developer can edit the file and
            # rerun the backend without touching the Flutter UI.
            if debug_mode:
                file_prompt, file_history = _read_last_user_turn(debug_chat_path)
                if file_prompt:
                    prompt = file_prompt
                    history = file_history
                    print(
                        f"[orch_multi] Debug: loaded prompt ({len(prompt)} chars) "
                        f"with {len(history)} history turns from {debug_chat_path}",
                        file=sys.stderr, flush=True,
                    )

            requested_mode_raw = str(req.get("task_mode") or "").strip()

            if orchestrator is None:
                try:
                    orchestrator = _create_orchestrator(
                        args,
                        path_filter,
                        db_connections,
                        task_mode=TaskMode.parse(requested_mode_raw or "open").value,
                    )
                except Exception as ex:  # noqa: BLE001 - keep the UI alive
                    print(
                        f"[orch_multi] Could not start a session: {ex}",
                        file=sys.stderr, flush=True,
                    )
                    # Retry on the next request: a configuration change in the
                    # UI must be able to fix the session without a restart.
                    print(json.dumps({"response": f"Error: {ex}", "request_id": request_id}))
                    print(RESPONSE_SENTINEL)
                    sys.stdout.flush()
                    continue

            # Session seeding: the Flutter side ships the visible chat log so
            # the orchestrator's hidden memory cannot drift away from what the
            # user sees. A new session always resets; a history-carrying
            # request treats the external log as authoritative (same contract
            # as the single-agent orchestrator).
            if req.get("new_session") or history:
                orchestrator.reset()
                if history:
                    orchestrator.import_history(history)

            # Per-request task-mode override: the Flutter dropdown can switch
            # between USER INPUT / AUTO INPUT at any time without restarting the
            # subprocess. Legacy mode names (open, task_compliance,
            # task_compliance_auto) are remapped to those two by
            # TaskMode.parse. The system prompt is re-derived on the next turn,
            # so a switch resets the conversation.
            if requested_mode_raw:
                new_mode = TaskMode.parse(requested_mode_raw)
                if new_mode is not orchestrator.task_mode:
                    orchestrator.task_mode = new_mode
                    orchestrator.reset()
                    if history:
                        orchestrator.import_history(history)
                    print(
                        f"[orch_multi] task_mode switched to {new_mode.value}.",
                        file=sys.stderr, flush=True,
                    )

            # Per-request thinking/effort override: the Flutter UI controls
            # take effect immediately without restarting the subprocess.
            thinking_val = req.get("thinking")
            if isinstance(thinking_val, bool):
                orchestrator.thinking = thinking_val
            effort_val = req.get("effort")
            if isinstance(effort_val, str) and effort_val.strip():
                orchestrator.effort = effort_val.strip().lower()

            if not prompt:
                # Respect the protocol even for empty prompts.
                print(RESPONSE_SENTINEL)
                sys.stdout.flush()
                continue

            try:
                response = orchestrator.run(prompt)
            except Exception as ex:  # noqa: BLE001 - the UI must always get a reply
                print(
                    f"[orch_multi] Request failed: {ex}",
                    file=sys.stderr, flush=True,
                )
                response = f"Error: {ex}"

            # Serialize as a single JSON string so embedded newlines survive.
            # `request_id` is echoed untouched so the Flutter side can discard
            # an envelope belonging to a turn it already aborted.
            print(json.dumps({"response": response, "request_id": request_id}))
            print(RESPONSE_SENTINEL)
            sys.stdout.flush()

            if debug_mode:
                _append_debug_response(debug_chat_path, response)
    except KeyboardInterrupt:
        print("[orch_multi] Shutdown requested.", file=sys.stderr)


def _run_oneshot(args, path_filter=None, db_connections=None) -> None:
    """One-shot mode: read prompt from stdin, answer once, exit."""
    prompt = sys.stdin.read().strip()
    if not prompt:
        return
    try:
        orchestrator = _create_orchestrator(args, path_filter, db_connections)
        response = orchestrator.run(prompt)
    except Exception as ex:  # noqa: BLE001 - report, never traceback to stdout
        response = f"Error: {ex}"
    print(response)
    print(RESPONSE_SENTINEL)


def _build_arg_parser() -> argparse.ArgumentParser:
    """Build the CLI parser.

    Extracted from :func:`main` so the flag contract — in particular
    ``--max-agent-rounds``, forwarded by the Flutter launcher — can be asserted
    without patching ``sys.argv``.
    """
    parser = argparse.ArgumentParser(
        description="Multi-slot Orchestrator — Workflow Agents (Assistant / User)",
    )

    # Reasoner model
    parser.add_argument(
        "--reasoner-provider",
        default="openai",
        help="Provider for the reasoner model (openai, anthropic, gemini, ollama, openrouter, groq, huggingface, github, etc.).",
    )
    parser.add_argument(
        "--reasoner-model",
        default="gpt-4o",
        help="Model ID for the reasoner.",
    )
    parser.add_argument(
        "--reasoner-api-key",
        default="",
        help="API key for the reasoner provider (or set env var).",
    )
    parser.add_argument(
        "--reasoner-base-url",
        default="",
        help="Base URL for the reasoner provider (if using custom endpoint).",
    )
    parser.add_argument(
        "--reasoner-context-window",
        type=int,
        default=None,
        help="Context window size for the reasoner model. Omit to use the "
             "backend default (recommended for Ollama: a large num_ctx "
             "explodes KV-cache RAM).",
    )
    parser.add_argument(
        "--reasoning-level",
        default="max",
        choices=["minimal", "low", "medium", "high", "max"],
        help="Reasoning effort level for the reasoner model. "
             "Maps to OpenAI reasoning_effort, Anthropic thinking.budget_tokens, "
             "Gemini thinkingConfig.thinkingBudget. Default: max.",
    )
    parser.add_argument(
        "--thinking",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="Extended thinking ON/OFF for the reasoner model (the Workflow "
             "Agents 'Assistant' slot). Seeded at launch because the chat-view "
             "toggle is hidden while MaM is enabled. Default: off.",
    )
    parser.add_argument(
        "--reasoner-tpm-limit",
        type=int,
        default=0,
        help="Tokens-per-minute cap for the reasoner backend. 0 = unlimited "
             "(default). When > 0 the backend is wrapped in RateLimitedBackend.",
    )

    # AUTO INPUT "User" agent (second Workflow Agents slot). Optional: when
    # omitted, AUTO INPUT fails safe with one answer plus a UI notice instead
    # of letting the assistant judge its own work.
    parser.add_argument(
        "--user-provider",
        default="",
        help="Provider for the AUTO INPUT 'User' agent (second Workflow Agents slot). Empty disables the User agent.",
    )
    parser.add_argument(
        "--user-model",
        default="",
        help="Model ID for the AUTO INPUT 'User' agent.",
    )
    parser.add_argument(
        "--user-api-key",
        default="",
        help="API key for the User agent provider.",
    )
    parser.add_argument(
        "--user-base-url",
        default="",
        help="Base URL override for the User agent (Ollama / OpenRouter).",
    )
    parser.add_argument(
        "--user-num-ctx",
        type=int,
        default=0,
        help="Legacy alias of --user-context-window. Kept so older launchers "
             "keep working. 0 = backend default.",
    )
    parser.add_argument(
        "--user-context-window",
        type=int,
        default=0,
        help="Context window override for the User agent. Applied to Ollama "
             "(num_ctx) and OpenRouter (context_limit); ignored by providers "
             "that manage it internally. Takes precedence over --user-num-ctx.",
    )
    parser.add_argument(
        "--user-temperature",
        type=float,
        default=None,
        help="Sampling temperature for the User agent's AUTO INPUT evaluation. "
             "Omit to keep the low deterministic default.",
    )
    parser.add_argument(
        "--user-max-tokens",
        type=int,
        default=0,
        help="Max output tokens for the User agent's AUTO INPUT evaluation. "
             "0 = the built-in 1024 default.",
    )
    parser.add_argument(
        "--user-reasoning-level",
        default=None,
        choices=["minimal", "low", "medium", "high", "max"],
        help="Reasoning effort level for the User agent.",
    )
    # Two explicit flags on one dest. ``BooleanOptionalAction`` would only
    # generate ``--no-user-thinking``, while the Flutter client emits
    # ``--user-no-thinking`` when the switch is OFF — which argparse then
    # rejects as an unrecognized argument.
    parser.add_argument(
        "--user-thinking",
        dest="user_thinking",
        action="store_true",
        default=False,
        help="Extended thinking ON for the User agent.",
    )
    parser.add_argument(
        "--user-no-thinking",
        dest="user_thinking",
        action="store_false",
        help="Extended thinking OFF for the User agent (default).",
    )
    parser.add_argument(
        "--user-tpm-limit",
        type=int,
        default=0,
        help="Tokens-per-minute cap for the User agent backend. 0 = unlimited "
             "(default).",
    )

    # General settings
    parser.add_argument(
        "--temperature",
        type=float,
        default=0.1,
        help="Sampling temperature.",
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=32768,
        help="Max tokens per model call. FALLBACK only — the Flutter UI "
             "passes this explicitly from the per-role Workflow Agents "
             "settings. Default 32768 for thinking models.",
    )
    parser.add_argument(
        "--max-iterations",
        type=int,
        default=100,
        help="Maximum number of model/tool iterations per request.",
    )
    parser.add_argument(
        "--max-agent-rounds",
        dest="max_agent_rounds",
        type=int,
        default=_DEFAULT_MAX_AUTO_ROUNDS,
        help="Maximum AUTO INPUT rounds (Assistant <-> User exchanges) per "
             "request. Clamped to 1-200 by the run loop. Default: 20. "
             "Settings -> Workflow Agents MaM -> Maximum Auto Round Actions.",
    )
    parser.add_argument(
        "--task-mode",
        default="open",
        choices=["open", "user_input", "auto_input"],
        help="Default input mode. The Flutter UI can override it per request "
             "by including a 'task_mode' field in the JSON envelope.",
    )

    # Modes
    parser.add_argument(
        "--interactive",
        action="store_true",
        help="Interactive mode (JSON-per-line protocol).",
    )
    parser.add_argument(
        "--install-deps",
        action="store_true",
        help="Install required Python packages and exit.",
    )

    # Path and security
    parser.add_argument(
        "--base-path", default=".", help="Base path that tools are allowed to touch."
    )
    parser.add_argument(
        "--sandbox",
        action="store_true",
        help="Enable sandbox mode: write/delete/run_command are disabled.",
    )
    parser.add_argument(
        "--disable-tools",
        action="store_true",
        help="Disable all tools (plain chat mode).",
    )

    # Optional config files
    parser.add_argument(
        "--filters-config",
        default="",
        metavar="PATH",
        help="Path to JSON file with filesystem filters.",
    )
    parser.add_argument(
        "--db-connections-config",
        default="",
        metavar="PATH",
        help="Path to JSON file with database connections.",
    )

    # Debug mode: backend reads the last USER turn from a chat file and
    # appends the AGENT response, bypassing the Flutter prompt.
    parser.add_argument(
        "--is_debug",
        action="store_true",
        help="Enable debug mode: read the user prompt from --file_name and append the response there.",
    )
    parser.add_argument(
        "--file_name",
        default="",
        metavar="RELATIVE_PATH",
        help="Relative path (from --base-path) of the chat file used in debug mode. Example: /chats/modifiche.txt",
    )

    return parser


def main():
    args = _build_arg_parser().parse_args()

    if args.install_deps:
        _install_dependencies()
        sys.exit(0)

    # Ensure configs/prompts_config.xml exists with all hardcoded prompts.
    try:
        sync_prompts_config()
    except Exception as exc:
        print(f"[orch_multi] Warning: could not sync prompts config: {exc}", file=sys.stderr)

    print("[orch_multi] Starting...", file=sys.stderr, flush=True)

    # Load optional filters and DB connections (handed to the tool registry).
    path_filter = None
    db_connections = None
    try:
        path_filter = _load_path_filter(args.filters_config, args.base_path)
        if path_filter is not None:
            active = path_filter.summary_for_prompt(top=3) or "(none)"
            print(f"[orch_multi] Filesystem filter active:\n{active}", file=sys.stderr, flush=True)
    except Exception as ex:
        print(f"[orch_multi] Failed to load path filter: {ex}", file=sys.stderr, flush=True)

    try:
        db_connections = _load_db_connections(args.db_connections_config)
        if db_connections:
            print(
                f"[orch_multi] Database connections loaded: {sorted(db_connections.keys())}",
                file=sys.stderr, flush=True,
            )
    except Exception as ex:
        print(f"[orch_multi] Failed to load DB connections: {ex}", file=sys.stderr, flush=True)

    if args.interactive:
        _run_interactive_loop(args, path_filter, db_connections)
    else:
        _run_oneshot(args, path_filter, db_connections)


if __name__ == "__main__":
    # noinspection PyBroadException
    try:
        main()
    except Exception:
        import traceback

        traceback.print_exc(file=sys.stderr)
        sys.stderr.flush()
        sys.exit(1)