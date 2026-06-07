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

# Disable .pyc generation EVERYWHERE in this process (including the agent
# package we're about to import). Has to happen before the first import
# from the agent package or Python will write __pycache__ for module
# bodies it parses on the way in.
sys.dont_write_bytecode = True

# Ensure ``import agent`` works whether the script is launched as
# ``python bin/orchestrator.py`` or ``python -m bin.orchestrator``.
import os

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)

import argparse
import json
from typing import Any, Dict, List

from agent.backends import RateLimitedBackend, build_backend
from agent.backends.gemini import GeminiBackend
from agent.backends.ollama import OllamaBackend
from agent.loop import Orchestrator
from agent.path_filter import PathFilter
from agent.policy import SecurityConfig
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

configure_stdio_utf8()


def _normalise_external_history(raw: Any) -> List[Dict[str, str]]:
    """Return caller-supplied visible chat turns in a safe role/content shape."""
    if not isinstance(raw, list):
        return []
    history: List[Dict[str, str]] = []
    for msg in raw:
        if not isinstance(msg, dict):
            continue
        role = str(msg.get("role") or "").strip().lower()
        content = str(msg.get("content") or "")
        if role not in ("user", "assistant", "system") or not content.strip():
            continue
        history.append({"role": role, "content": content})
    return history


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
        default=0.2,
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
        "and auto-trims history when a single request exceeds the "
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
        default="orchestrator_audit.log",
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

    args = parser.parse_args()

    if args.install_deps:
        ok = install_dependencies(verbose=True)
        sys.exit(0 if ok else 1)

    audit_log_path = (args.audit_log or "").strip()
    security_config = SecurityConfig(
        sandbox_mode=args.sandbox,
        max_file_size_bytes=int(args.max_file_size_mb * 1024 * 1024),
        enable_audit_log=bool(audit_log_path),
        audit_log_path=audit_log_path or "orchestrator_audit.log",
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
    )
    if args.disable_tools:
        print("[orch] Tools disabled — running in plain-chat mode.", file=sys.stderr)

    if args.interactive:
        _run_interactive_loop(orchestrator)
    else:
        _run_oneshot(orchestrator)


def _load_path_filter(filters_config_path: str, base_path: str):
    """Read the optional filters JSON file and build a PathFilter.

    Returns None when the path is empty/missing or unreadable; the
    ToolRegistry treats None as "filter off" (only the hardcoded baseline
    of `.git`, `__pycache__`, etc. applies). Logs failures to stderr so
    the user can spot a typo without the orchestrator refusing to start.
    """
    path = (filters_config_path or "").strip()
    if not path:
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except FileNotFoundError:
        print(f"[orch] --filters-config '{path}' not found; ignoring.", file=sys.stderr)
        return None
    except (json.JSONDecodeError, OSError) as e:
        print(
            f"[orch] --filters-config could not be read ({e}); ignoring.",
            file=sys.stderr,
        )
        return None
    if not isinstance(cfg, dict):
        print(
            f"[orch] --filters-config did not contain an object; ignoring.",
            file=sys.stderr,
        )
        return None
    return PathFilter.from_config(base_path, cfg)


def _load_db_connections(config_path: str):
    """Read the optional db-connections JSON file and return a dict.

    The Flutter Settings UI writes a list of {"key", "value", "type"} entries;
    we convert it into the dict shape the db_query tool expects (keyed by
    connection name). Returns an empty dict for any failure so the
    orchestrator still starts — db_query will just report "no connections
    available" until the user fixes the file.
    """
    path = (config_path or "").strip()
    if not path:
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = json.load(f)
    except FileNotFoundError:
        print(
            f"[orch] --db-connections-config '{path}' not found; ignoring.",
            file=sys.stderr,
        )
        return {}
    except (json.JSONDecodeError, OSError) as e:
        print(
            f"[orch] --db-connections-config could not be read ({e}); ignoring.",
            file=sys.stderr,
        )
        return {}
    if not isinstance(raw, list):
        print(
            "[orch] --db-connections-config did not contain a list; ignoring.",
            file=sys.stderr,
        )
        return {}
    connections = {}
    for item in raw:
        if not isinstance(item, dict):
            continue
        key = item.get("key")
        value = item.get("value", "")
        conn_type = item.get("type", "sqlite")
        if not isinstance(key, str) or not key:
            continue
        connections[key] = {"value": value, "type": conn_type}
    return connections


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


def _run_interactive_loop(orchestrator: Orchestrator) -> None:
    # Signal readiness so the client knows the process is up.
    print("__READY__")
    sys.stdout.flush()
    try:
        while True:
            req = read_interactive_request(sys.stdin)
            if req is None:
                break  # EOF
            history = _normalise_external_history(req.get("history"))
            if req.get("new_session") or history:
                orchestrator.reset()
                if history:
                    orchestrator.import_history(history)
            prompt = (req.get("prompt") or "").strip()
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
