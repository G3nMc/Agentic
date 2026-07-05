#!/usr/bin/env python3
"""
Client-Side Local Orchestrator — entry point.
=============================================

A modular, tool-registry-based orchestrator that lets a remote model
execute tools (read/write/list files, run commands) on the local machine.

The implementation lives in the :mod:`agent` package next to this file
(``bin/agent/``). This script is a thin shim: arg parsing, dependency
checks, backend construction, and the interactive stdin/stdout loop.

Architecture:
  User Input -> Orchestrator -> Model Backend -> Tool Request
  ^                                                    |
  |_______ Execute Tool Locally _______________________|

Protocol (when run with --interactive, used by the Flutter UI):
  - The client writes exactly one JSON object per line to stdin:
      {"prompt": "...", "new_session": true|false}
  - The orchestrator answers with the full text response on stdout, followed
    by a single line containing exactly `__RESPONSE_END__`.
  - Diagnostics go to stderr so they don't corrupt the response stream.

Other modes:
  --install-deps   Install required Python dependencies and exit.
  (no flag)        Read one prompt from stdin (raw text), answer once, exit.

Usage:
  python orchestrator.py --install-deps
  python orchestrator.py --hf-token YOUR_TOKEN --interactive
  python orchestrator.py --hf-token YOUR_TOKEN --model MODEL_ID
"""

from __future__ import annotations

import sys

from agent.backends.ollama import OllamaBackend
from agent.loop.run_loop import Orchestrator
from agent.loop.task_protocol import TaskMode

# Disable .pyc generation EVERYWHERE in this process (including the agent
# package we're about to import). Has to happen before the first import
# from the agent package or Python will write __pycache__ for module
# bodies it parses on the way in.
sys.dont_write_bytecode = True

# Ensure ``import agent`` works whether the script is launched as
# ``python bin/orchestrator.py`` or ``python -m bin.orchestrator``.
# Also expose the project root (parent of bin/) so transitive imports
# of the form ``bin.common.*`` resolve — these are used by sibling
# packages and are kept for backwards compatibility.
import os

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_PROJECT_ROOT = os.path.dirname(_THIS_DIR)
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)
if _PROJECT_ROOT not in sys.path:
    sys.path.insert(0, _PROJECT_ROOT)

import argparse
import json

from agent.backends import RateLimitedBackend, build_backend
from agent.backends.gemini import GeminiBackend

from agent.core.policy import SecurityConfig
from agent.utils.bootstrap import (
    BACKEND_REQUIRED_MODULES,
    check_dependencies,
    import_hf_runtime,
    install_dependencies,
)
from agent.utils.io_protocol import (
    RESPONSE_SENTINEL,
    configure_stdio_utf8,
    read_interactive_request,
)
# Shared helpers between the two CLI orchestrators. The default log
# prefix in orchestrator_base is "orch", which matches the existing
# stderr output of this script — no wrapping needed.
from orchestrator_base import (
    _normalise_external_history,
    _load_path_filter,
    _load_db_connections,
    _resolve_debug_chat_path,
    _read_last_user_turn,
    _append_debug_response,
)

configure_stdio_utf8()


def main():
    parser = argparse.ArgumentParser(
        description="Client-Side Local Orchestrator (HF router, Gemini, Groq or Ollama)",
    )
    parser.add_argument(
        "--backend",
        choices=["huggingface", "ollama", "groq", "gemini", "openrouter", "github"],
        default="huggingface",
        help=(
            "Which model backend to use. `huggingface` (default) talks to "
            "the HF Inference router; `ollama` talks to a local/cloud Ollama "
            "daemon; `groq` talks to Groq Cloud (needs --groq-api-key); "
            "`gemini` talks to Google AI Studio / Gemini Cloud (needs "
            "--gemini-api-key); `openrouter` routes through OpenRouter to "
            "any supported provider (needs --openrouter-api-key); "
            "`github` talks to GitHub Models (needs --github-api-key, a PAT "
            "with `models:read` scope). All backends use the same tool protocol."
        ),
    )
    parser.add_argument(
        "--hf-token",
        help="Hugging Face API token (required when --backend=huggingface)",
    )
    parser.add_argument(
        "--model",
        default="",
        help="Model ID. For HF: e.g. 'meta-llama/Llama-3.1-70B-Instruct'. "
             "For Gemini: e.g. 'gemini-2.5-flash' or 'gemini-2.5-pro'. "
             "For Ollama: e.g. 'qwen2.5-coder:7b' or 'llama3:8b'. "
             "Groq and Ollama backends require an explicit model. "
             "Small models (<7B) frequently fail the tool-call protocol.",
    )
    parser.add_argument(
        "--ollama-base-url",
        default="http://localhost:11434",
        help="Ollama daemon or cloud endpoint URL. Local default is "
             "http://localhost:11434. Models tagged ':<size>-cloud' are "
             "auto-routed to https://ollama.com when this flag is left at "
             "the default — pass it explicitly only to override (e.g. a "
             "self-hosted proxy).",
    )
    parser.add_argument(
        "--ollama-api-key",
        default="",
        help="Bearer token for cloud-hosted Ollama endpoints. Leave empty "
             "for a local daemon (no auth needed).",
    )
    parser.add_argument(
        "--ollama-num-ctx",
        type=int,
        default=OllamaBackend.DEFAULT_NUM_CTX,
        help="Context window for Ollama. Defaults to 8192. Do NOT raise "
             "this to match the model's Modelfile default (often 128K) — "
             "it explodes KV-cache RAM use. Drop to 4096 for very small "
             "local models on tight RAM; raise to 16384/32768 for 7B+ "
             "models on >=16 GB or for cloud-hosted backends.",
    )
    parser.add_argument(
        "--temperature",
        type=float,
        default=0.1,
        help="Sampling temperature. Lower = more deterministic tool calls "
             "(0.2 is the sweet spot for small models); raise to ~0.7 for "
             "more natural free-form answers.",
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=8192 * 2,
        help="Hard cap on generated tokens per model call. Covers any tool "
             "call + typical file writes. Raising past ~4096 on a 3B model "
             "(phi3) can push a single iteration over a minute.",
    )
    parser.add_argument(
        "--tpm-limit",
        type=int,
        default=0,
        help="Tokens-per-minute cap for the selected backend. 0 = unlimited "
             "(default). When >0, the orchestrator wraps the backend in a "
             "sliding-window rate limiter that sleeps before oversize calls "
             "and auto-trims self when a single request exceeds the "
             "budget. Use the free-tier TPM from your provider dashboard "
             "(Groq free: 6000-8000 depending on model).",
    )
    parser.add_argument(
        "--groq-api-key",
        default="",
        help="Groq Cloud API key (required when --backend=groq). "
             "Get one free at https://console.groq.com/keys.",
    )
    parser.add_argument(
        "--gemini-api-key",
        default="",
        help="Google AI Studio API key (required when --backend=gemini). "
             "Get one free at https://aistudio.google.com/app/apikey.",
    )
    parser.add_argument(
        "--openrouter-api-key",
        default="",
        help="OpenRouter API key (required when --backend=openrouter). "
             "Get one free at https://openrouter.ai/keys.",
    )
    parser.add_argument(
        "--github-api-key",
        default="",
        help="GitHub fine-grained PAT with `models:read` scope (required when "
             "--backend=github). Create one at "
             "https://github.com/settings/personal-access-tokens/new.",
    )
    parser.add_argument(
        "--interactive",
        action="store_true",
        help="Interactive mode (JSON-per-line protocol)",
    )
    parser.add_argument(
        "--install-deps",
        action="store_true",
        help="Install required Python packages and exit",
    )
    parser.add_argument(
        "--base-path", default=".", help="Base path that tools are allowed to touch"
    )
    parser.add_argument(
        "--sandbox",
        action="store_true",
        help=(
            "Enable sandbox mode: run_command, write_file, append_file, and "
            "delete_file are all disabled. The model can only read and search "
            "files. Useful for safe code-review sessions."
        ),
    )
    parser.add_argument(
        "--audit-log",
        default="logs/orchestrator_audit.log",
        metavar="PATH",
        help=(
            "Path to the audit log file. Every tool call is appended with a "
            "timestamp, tool name, sanitized parameters, and result status. "
            "Default: orchestrator_audit.log. Pass an empty string to disable."
        ),
    )
    parser.add_argument(
        "--disable-tools",
        action="store_true",
        help=(
            "Bypass the tool-decision heuristic and the tool loop entirely — "
            "every user message is sent to the model as a plain chat call "
            "(no `tools=[...]` payload, no <tool> parsing). Use this for "
            "reasoning-only models that don't support tool calling."
        ),
    )
    parser.add_argument(
        "--task-mode",
        default="task_compliance_auto",
        choices=["open", "task_compliance", "task_compliance_auto"],
        help=(
            "Default task-flow mode. 'open' (free-form), 'task_compliance' "
            "(structured plan + manual proceed between tasks), or "
            "'task_compliance_auto' (structured plan + auto proceed). The "
            "Flutter UI can override this per request by including a "
            "'task_mode' field in the JSON envelope sent to stdin."
        ),
    )
    parser.add_argument(
        "--auto-num-ctx",
        action="store_true",
        default=False,
        help=(
            "Auto-calibrate the self budget from the model's first "
            "API response. When ON, the orchestrator reads the actual "
            "prompt_eval_count the model reports and clamps the internal "
            "self token budget to that real value. This prevents "
            "sending more tokens than the cloud model can actually "
            "process, which causes silent truncation and garbled "
            "replies. When OFF (default), the budget stays at 85%% of "
            "the configured --ollama-num-ctx value."
        ),
    )
    parser.add_argument(
        "--max-file-size-mb",
        type=float,
        default=10.0,
        metavar="MB",
        help=(
            "Maximum file size (in MB) that write_file / append_file will "
            "accept. Requests exceeding this limit are rejected. Default: 10."
        ),
    )
    parser.add_argument(
        "--filters-config",
        default="",
        metavar="PATH",
        help=(
            "Optional path to a JSON file with user-configured filesystem "
            "filters: exclude_dirs, include_dirs, exclude_files, "
            "include_files (each a list of strings). When set, the discovery "
            "tools (list_files, search_in_files, find_files, "
            "list_files_recursive) hide entries matching the exclude rules "
            "and re-show entries matching the include rules. Inclusion wins "
            "over exclusion. read_file / write_file are NOT filtered."
        ),
    )
    parser.add_argument(
        "--db-connections-config",
        default="",
        metavar="PATH",
        help=(
            "Optional path to a JSON file listing user-configured database "
            "connections — written by the Flutter Settings UI (Developer → "
            "Database Connections). Each entry is "
            '{"key": ..., "value": ..., "type": "sqlite"|"mariadb"}. '
            "Loaded once at startup and passed to the db_query tool so the "
            "model can address connections by key without touching the "
            "filesystem."
        ),
    )
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

    args = parser.parse_args()

    if args.install_deps:
        ok = install_dependencies(verbose=True)
        sys.exit(0 if ok else 1)

    audit_log_path = (args.audit_log or "").strip()
    security_config = SecurityConfig(
        sandbox_mode=args.sandbox,
        max_file_size_bytes=int(args.max_file_size_mb * 1024 * 1024),
        enable_audit_log=bool(audit_log_path),
        audit_log_path=audit_log_path or "logs/orchestrator_audit.log",
    )
    if args.sandbox:
        print(
            "[orch] SANDBOX MODE: write/delete/run_command are disabled.",
            file=sys.stderr,
        )
    if security_config.enable_audit_log:
        print(
            f"[orch] Audit logging enabled -> {security_config.audit_log_path}",
            file=sys.stderr,
        )

    # Parse the user-configured filesystem filter (optional). Failures here
    # are non-fatal: a corrupt config means the user gets the inert filter
    # and a clear stderr line, instead of a refusing-to-start orchestrator.
    path_filter = _load_path_filter(args.filters_config, args.base_path)
    if path_filter is not None:
        active = path_filter.summary_for_prompt(top=3) or "(none)"
        print(f"[orch] Filesystem filter active:\n{active}", file=sys.stderr)

    # User-configured database connections written by the Flutter Settings UI.
    # Same non-fatal policy as filters: a missing or malformed file just means
    # the db_query tool reports "no connections available" until the user
    # reconfigures, instead of preventing the orchestrator from starting.
    db_connections = _load_db_connections(args.db_connections_config)
    if db_connections:
        print(
            f"[orch] Database connections loaded: {sorted(db_connections.keys())}",
            file=sys.stderr,
        )

    # Backend-specific dependency checks keep the startup error focused on
    # the backend the user actually selected.
    if args.backend == "huggingface" and not args.model:
        args.model = "meta-llama/Llama-3.1-70B-Instruct"
    if args.backend == "gemini" and not args.model:
        args.model = GeminiBackend.DEFAULT_MODEL

    backend = _build_backend_for_args(args)

    if args.tpm_limit and args.tpm_limit > 0:
        backend = RateLimitedBackend(
            backend, tpm_limit=args.tpm_limit, label=args.backend
        )
        print(
            f"[orch] TPM rate limiter active: {args.tpm_limit} tokens/min "
            f"(effective {int(args.tpm_limit * 0.95)}).",
            file=sys.stderr,
        )

    print(
        f"[orch] Local Orchestrator ready. Backend: {args.backend}, "
        f"Model: {args.model}",
        file=sys.stderr,
    )

    orchestrator = Orchestrator(
        backend=backend,
        base_path=args.base_path,
        temperature=args.temperature,
        max_tokens=args.max_tokens,
        security_config=security_config,
        disable_tools=args.disable_tools,
        path_filter=path_filter,
        db_connections=db_connections,
        task_mode=args.task_mode,
        auto_num_ctx=args.auto_num_ctx,
    )
    if args.disable_tools:
        print("[orch] Tools disabled — running in plain-chat mode.", file=sys.stderr)

    if args.interactive:
        _run_interactive_loop(orchestrator, args)
    else:
        _run_oneshot(orchestrator)


# `_load_path_filter` and `_load_db_connections` now live in
# :mod:`orchestrator_base` and are imported at the top of this file.
# The base versions accept an optional ``log_prefix`` arg defaulting to
# ``"orch"`` — which is exactly the prefix this script used historically.


def _build_backend_for_args(args):
    """Resolve the configured backend, including dep checks and key sourcing."""
    if args.backend == "huggingface":
        missing = check_dependencies(BACKEND_REQUIRED_MODULES["huggingface"])
        if missing:
            print("[orch] Missing dependencies: " + ", ".join(missing), file=sys.stderr)
            print(
                "[orch] Run `python orchestrator.py --install-deps` first.",
                file=sys.stderr,
            )
            sys.exit(2)
        import_hf_runtime()

        if not args.hf_token:
            print(
                "[orch] --hf-token is required for --backend=huggingface.",
                file=sys.stderr,
            )
            sys.exit(2)
        return build_backend("huggingface", hf_token=args.hf_token, model_id=args.model)

    if args.backend == "gemini":
        missing = check_dependencies(BACKEND_REQUIRED_MODULES["gemini"])
        if missing:
            print("[orch] Missing dependencies: " + ", ".join(missing), file=sys.stderr)
            print(
                "[orch] Run `python orchestrator.py --install-deps` first.",
                file=sys.stderr,
            )
            sys.exit(2)
        gemini_key = (
                args.gemini_api_key
                or os.environ.get("GOOGLE_API_KEY", "")
                or os.environ.get("GEMINI_API_KEY", "")
        )
        if not gemini_key:
            print(
                "[orch] --gemini-api-key (or GOOGLE_API_KEY / GEMINI_API_KEY "
                "env var) is required for --backend=gemini.",
                file=sys.stderr,
            )
            sys.exit(2)
        backend = build_backend("gemini", api_key=gemini_key, model_id=args.model)
        print(f"[orch] Using Gemini backend, model={args.model}", file=sys.stderr)
        return backend

    if args.backend == "groq":
        missing = check_dependencies(BACKEND_REQUIRED_MODULES["groq"])
        if missing:
            print("[orch] Missing dependency: groq", file=sys.stderr)
            print(
                "[orch] Run `python orchestrator.py --install-deps` first.",
                file=sys.stderr,
            )
            sys.exit(2)
        groq_key = args.groq_api_key or os.environ.get("GROQ_API_KEY", "")
        if not groq_key:
            print(
                "[orch] --groq-api-key (or GROQ_API_KEY env var) is required "
                "for --backend=groq.",
                file=sys.stderr,
            )
            sys.exit(2)
        backend = build_backend("groq", api_key=groq_key, model_id=args.model)
        print(f"[orch] Using Groq backend, model={args.model}", file=sys.stderr)
        return backend

    if args.backend == "openrouter":
        openrouter_key = args.openrouter_api_key or os.environ.get(
            "OPENROUTER_API_KEY", ""
        )
        if not openrouter_key:
            print(
                "[orch] --openrouter-api-key (or OPENROUTER_API_KEY env var) "
                "is required for --backend=openrouter.",
                file=sys.stderr,
            )
            sys.exit(2)
        backend = build_backend(
            "openrouter", api_key=openrouter_key, model_id=args.model
        )
        print(f"[orch] Using OpenRouter backend, model={args.model}", file=sys.stderr)
        return backend

    if args.backend == "github":
        github_key = (
                args.github_api_key
                or os.environ.get("GITHUB_TOKEN", "")
                or os.environ.get("GITHUB_API_KEY", "")
        )
        if not github_key:
            print(
                "[orch] --github-api-key (or GITHUB_TOKEN env var) "
                "is required for --backend=github.",
                file=sys.stderr,
            )
            sys.exit(2)
        backend = build_backend("github", api_key=github_key, model_id=args.model)
        print(
            f"[orch] Using GitHub Models backend, model={args.model}", file=sys.stderr
        )
        return backend

    # ollama (default fall-through)
    missing = check_dependencies(BACKEND_REQUIRED_MODULES["ollama"])
    if missing:
        print("[orch] Missing dependency: ollama", file=sys.stderr)
        print(
            "[orch] Run `python orchestrator.py --install-deps` first.", file=sys.stderr
        )
        sys.exit(2)
    backend = build_backend(
        "ollama",
        model_id=args.model,
        base_url=args.ollama_base_url,
        num_ctx=args.ollama_num_ctx,
        api_key=args.ollama_api_key,
    )
    try:
        backend.health_check()
    except Exception as e:  # noqa: BLE001
        print(f"[orch] Ollama not ready: {e}", file=sys.stderr)
        sys.exit(3)
    print(
        f"[orch] Using Ollama backend at {backend.base_url} "
        f"(num_ctx={args.ollama_num_ctx})",
        file=sys.stderr,
    )
    return backend


def _run_interactive_loop(orchestrator: Orchestrator, args=None) -> None:
    debug_mode = bool(args is not None and getattr(args, "is_debug", False))
    debug_chat_path = _resolve_debug_chat_path(args.base_path, args.file_name) if debug_mode else ""
    if debug_mode:
        print(
            f"[orch] DEBUG MODE active. Chat file: {debug_chat_path}",
            file=sys.stderr, flush=True,
        )
    # Signal readiness so the client knows the process is up.
    print("__READY__")
    sys.stdout.flush()
    try:
        while True:
            req = read_interactive_request(sys.stdin)
            if req is None:
                break  # EOF
            history = _normalise_external_history(req.get("history"))
            if req.get("new_session"):
                orchestrator.reset()
                if history:
                    orchestrator.import_history(history)
            elif history:
                # User wants us to use this history. 
                # To avoid duplicating turns that the orchestrator already has,
                # we reset and import the external history as the authoritative state.
                orchestrator.reset()
                orchestrator.import_history(history)
            # Per-request task-mode override: the Flutter dropdown can
            # change between OPEN / TASK COMPLIANCE / TASK COMPLIANCE
            # AUTO at any time without restarting the subprocess. The
            # request envelope optionally carries a ``task_mode`` field.
            requested_mode = req.get("task_mode")
            if isinstance(requested_mode, str) and requested_mode.strip(): 
                new_mode = TaskMode.parse(requested_mode)
                if new_mode is not orchestrator.task_mode:
                    orchestrator.task_mode = new_mode
                    # System prompt must be re-derived on the next turn
                    # because the TASK FLOW section visibility changed.
                    orchestrator.reset()
                    if history:
                        orchestrator.import_history(history)
                    print(
                        f"[orch] task_mode switched to {new_mode.value}",
                        file=sys.stderr,
                    )
            # Per-request thinking/effort override: the Flutter UI controls
            # take effect immediately without restarting the subprocess.
            thinking_val = req.get("thinking")
            if isinstance(thinking_val, bool):
                orchestrator.thinking = thinking_val
            effort_val = req.get("effort")
            if isinstance(effort_val, str) and effort_val.strip():
                orchestrator.effort = effort_val.strip().lower()
            prompt = (req.get("prompt") or "").strip()

            # Debug mode: override prompt from the chat file.
            if debug_mode:
                file_prompt, file_history = _read_last_user_turn(debug_chat_path)
                if file_prompt:
                    prompt = file_prompt
                    history = file_history
                    orchestrator.reset()
                    orchestrator.import_history(history)
                    print(
                        f"[orch] Debug: loaded prompt ({len(prompt)} chars) "
                        f"with {len(history)} self turns from {debug_chat_path}",
                        file=sys.stderr, flush=True,
                    )

            if not prompt:
                # Respect the protocol even for empty prompts.
                print(RESPONSE_SENTINEL)
                sys.stdout.flush()
                continue
            try:
                response = orchestrator.run(prompt)
            except Exception as e:
                response = f"Error: {e}"
            # Serialize as a single JSON string so embedded newlines survive.
            print(json.dumps({"response": response}))
            print(RESPONSE_SENTINEL)
            sys.stdout.flush()

            if debug_mode:
                _append_debug_response(debug_chat_path, response)
    except KeyboardInterrupt:
        print("[orch] Shutdown requested.", file=sys.stderr)


def _run_oneshot(orchestrator: Orchestrator) -> None:
    prompt = sys.stdin.read().strip()
    if prompt:
        response = orchestrator.run(prompt)
        print(response)
        print(RESPONSE_SENTINEL)


if __name__ == "__main__":
    main()
