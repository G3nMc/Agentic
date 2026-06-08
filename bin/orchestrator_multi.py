#!/usr/bin/env python3
"""
Multi-agent Orchestrator — entry point for the new multi_mode workflow.
==============================================================

Uses the multi_mode package (single-loop Reasoner + Summarizer)
instead of the old multi-agent pipeline.

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
  python orchestrator_multi.py --reasoner-provider openai --reasoner-model gpt-4o --interactive
  python orchestrator_multi.py --reasoner-provider ollama --reasoner-model llama3:8b
"""

from __future__ import annotations

import sys

# Disable .pyc generation
sys.dont_write_bytecode = True

# Ensure ``import multi_mode`` works
import os

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_PROJECT_ROOT = os.path.dirname(_THIS_DIR)
# Add both bin/ (for old agent package) and project root (for multi_mode)
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)
if _PROJECT_ROOT not in sys.path:
    sys.path.insert(0, _PROJECT_ROOT)

import argparse
import json
import subprocess


# Reuse the shared I/O protocol utilities (the agent.utils.io_protocol
# shim re-exports the same symbols for backwards compatibility).
from common.utils.io_protocol import (
    RESPONSE_SENTINEL,
    configure_stdio_utf8,
    read_interactive_request,
)
# Shared helpers between the two CLI orchestrators. We import the base
# functions and re-bind them through thin wrappers below to preserve the
# historical "[orch_multi]" log prefix without changing call sites.
from orchestrator_base import (
    _normalise_external_history,
    _prompt_with_visible_history,
    _load_path_filter as _base_load_path_filter,
    _load_db_connections as _base_load_db_connections,
)


def _load_path_filter(filters_config_path: str, base_path: str):
    """Multi-mode wrapper preserving the historical ``[orch_multi]`` log prefix."""
    return _base_load_path_filter(filters_config_path, base_path, log_prefix="orch_multi")


def _load_db_connections(config_path: str):
    """Multi-mode wrapper preserving the historical ``[orch_multi]`` log prefix."""
    return _base_load_db_connections(config_path, log_prefix="orch_multi")


configure_stdio_utf8()

# multi_mode imports are deferred to avoid crashing before --install-deps can run.
# They are imported inside _create_orchestrator().


def _install_dependencies() -> None:
    """Install required Python packages for multi_mode backends."""
    packages = [
        "openai",
        "anthropic",
        "google-genai",
        "groq",
        "requests",
        "tiktoken",
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


# `_normalise_external_history`, `_prompt_with_visible_history`,
# `_load_path_filter` and `_load_db_connections` are imported from
# :mod:`orchestrator_base` at the top of this file. The two ``_load_*``
# names are bound to multi-mode-specific wrappers that pass
# ``log_prefix="orch_multi"``; call sites below stay unchanged.


def build_config_from_args(args):
    """Build AgentConfig from CLI arguments."""
    from multi_mode.config.agent import AgentConfig
    from multi_mode.config.models import ModelConfig, ModelRole

    config = AgentConfig(enable_summarization=False)

    # Reasoner (required)
    reasoner_provider = args.reasoner_provider
    reasoner_model = args.reasoner_model
    reasoner_api_key = args.reasoner_api_key or None
    reasoner_base_url = args.reasoner_base_url or None
    reasoner_temp = args.temperature
    reasoner_max_tokens = args.max_tokens
    reasoner_context = args.reasoner_context_window

    config.models[ModelRole.REASONER] = ModelConfig(
        role=ModelRole.REASONER,
        provider=reasoner_provider,
        model=reasoner_model,
        api_key=reasoner_api_key,
        base_url=reasoner_base_url,
        temperature=reasoner_temp,
        max_tokens=reasoner_max_tokens,
        context_window=reasoner_context,
    )

    # Summarizer (optional)
    if args.summarizer_provider and args.summarizer_model:
        summarizer_provider = args.summarizer_provider
        summarizer_model = args.summarizer_model
        summarizer_api_key = args.summarizer_api_key or None
        summarizer_base_url = args.summarizer_base_url or None
        summarizer_temp = args.temperature
        summarizer_max_tokens = args.max_tokens
        summarizer_context = args.summarizer_context_window

        config.models[ModelRole.SUMMARIZER] = ModelConfig(
            role=ModelRole.SUMMARIZER,
            provider=summarizer_provider,
            model=summarizer_model,
            api_key=summarizer_api_key,
            base_url=summarizer_base_url,
            temperature=summarizer_temp,
            max_tokens=summarizer_max_tokens,
            context_window=summarizer_context,
        )
    else:
        config.enable_summarization = False

    # General settings
    config.max_iterations = args.max_iterations
    config.tool_timeout = args.tool_timeout
    config.parallel_tools = not args.no_parallel_tools
    config.project_root = args.base_path

    return config


def _create_orchestrator(args):
    """Create an Orchestrator instance from CLI args."""
    # Lazy imports to avoid crashing before --install-deps can run.
    from multi_mode.loop.orchestrator import Orchestrator
    from multi_mode.tools.registry import ToolRegistry

    config = build_config_from_args(args)

    # Create orchestrator (it will build backends and tools internally)
    orchestrator = Orchestrator(config)

    # Apply sandbox mode: remove dangerous tools
    if args.sandbox:
        dangerous = {"write_file", "append_file", "delete_file", "run_command", "patch_file", "move_file"}
        for name in dangerous:
            orchestrator.tool_registry.unregister(name)
        print("[orch_multi] SANDBOX MODE: write/delete/run_command are disabled.", file=sys.stderr)

    # Disable all tools if requested
    if args.disable_tools:
        orchestrator.tool_registry = ToolRegistry()  # empty registry
        print("[orch_multi] Tools disabled — running in plain-chat mode.", file=sys.stderr)

    return orchestrator


def _run_interactive_loop(args) -> None:
    """Interactive loop using the new multi_mode Orchestrator."""
    # Ensure stdout is line-buffered so the Flutter side sees __READY__ immediately.
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(line_buffering=True)
    print("__READY__", flush=True)
    print("[orch_multi] Ready for requests.", file=sys.stderr, flush=True)

    orchestrator = None
    try:
        while True:
            req = read_interactive_request(sys.stdin)
            if req is None:
                break  # EOF

            history = _normalise_external_history(req.get("history"))
            new_session = req.get("new_session") or bool(history)

            if new_session or orchestrator is None:
                orchestrator = _create_orchestrator(args)

            prompt = (req.get("prompt") or "").strip()
            if not prompt:
                print(RESPONSE_SENTINEL)
                sys.stdout.flush()
                continue

            # Prepend visible history if provided
            full_prompt = _prompt_with_visible_history(prompt, history)

            try:
                result = orchestrator.run(full_prompt)
                if result.success:
                    response = result.final_answer or "Task completed."
                else:
                    response = result.error or "Task failed."
            except Exception as ex:
                response = f"Error: {ex}"

            # Serialize as a single JSON string so embedded newlines survive.
            print(json.dumps({"response": response}))
            print(RESPONSE_SENTINEL)
            sys.stdout.flush()
    except KeyboardInterrupt:
        print("[orch_multi] Shutdown requested.", file=sys.stderr)


def _run_oneshot(args) -> None:
    """One-shot mode: read prompt from stdin, answer once, exit."""
    orchestrator = _create_orchestrator(args)
    prompt = sys.stdin.read().strip()
    if prompt:
        result = orchestrator.run(prompt)
        if result.success:
            print(result.final_answer or "")
        else:
            print(result.error or "Task failed.")
        print(RESPONSE_SENTINEL)


def main():
    parser = argparse.ArgumentParser(
        description="Multi-agent Orchestrator — multi_mode-based workflow",
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
        default=128000,
        help="Context window size for the reasoner model.",
    )

    # Summarizer model (optional)
    parser.add_argument(
        "--summarizer-provider",
        default="",
        help="Provider for the summarizer model (openai, anthropic, gemini, ollama, openrouter, groq, huggingface, github, etc.). If empty, summarization is disabled.",
    )
    parser.add_argument(
        "--summarizer-model",
        default="",
        help="Model ID for the summarizer.",
    )
    parser.add_argument(
        "--summarizer-api-key",
        default="",
        help="API key for the summarizer provider.",
    )
    parser.add_argument(
        "--summarizer-base-url",
        default="",
        help="Base URL for the summarizer provider.",
    )
    parser.add_argument(
        "--summarizer-context-window",
        type=int,
        default=128000,
        help="Context window size for the summarizer model.",
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
        default=4096,
        help="Max tokens per model call.",
    )
    parser.add_argument(
        "--max-iterations",
        type=int,
        default=50,
        help="Maximum number of reasoner-executor iterations.",
    )
    parser.add_argument(
        "--tool-timeout",
        type=int,
        default=30,
        help="Timeout in seconds for each tool call.",
    )
    parser.add_argument(
        "--no-parallel-tools",
        action="store_true",
        help="Disable parallel tool execution.",
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

    args = parser.parse_args()

    if args.install_deps:
        _install_dependencies()
        sys.exit(0)

    print("[orch_multi] Starting...", file=sys.stderr, flush=True)

    # Load optional filters and DB connections (for future use)
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
        _run_interactive_loop(args)
    else:
        _run_oneshot(args)


if __name__ == "__main__":
    # noinspection PyBroadException
    try:
        main()
    except Exception as e:
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.stderr.flush()
        sys.exit(1)
