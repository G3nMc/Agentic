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

from agent.config import AgentConfig, ModelRole
from agent.config.models import ReasoningLevel, ModelConfig
from agent.loop.run_loop import Orchestrator
from agent.tools.registry import ToolRegistry

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
import re
import subprocess

# Reuse the shared I/O protocol utilities (the agent.utils.io_protocol
# shim re-exports the same symbols for backwards compatibility).
from agent.utils.io_protocol import (
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
    _resolve_debug_chat_path,
    _read_last_user_turn,
    _append_debug_response,
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
    """Install the single HTTP dependency every backend needs.

    After the SDK-free refactor (see :mod:`common.backends.http_client`)
    every model backend talks to its provider via plain REST through
    ``requests``. No provider SDK is required anymore.
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


# `_normalise_external_history`, `_prompt_with_visible_history`,
# `_load_path_filter` and `_load_db_connections` are imported from
# :mod:`orchestrator_base` at the top of this file. The two ``_load_*``
# names are bound to multi-mode-specific wrappers that pass
# ``log_prefix="orch_multi"``; call sites below stay unchanged.
# Debug helpers are also imported from :mod:`orchestrator_base`.


def build_config_from_args(args):
    """Build AgentConfig from CLI arguments."""

    config = AgentConfig(enable_summarization=False)

    # Reasoner (required)
    reasoner_provider = args.reasoner_provider
    reasoner_model = args.reasoner_model
    reasoner_api_key = args.reasoner_api_key or None
    reasoner_base_url = args.reasoner_base_url or None
    reasoner_temp = args.temperature
    reasoner_max_tokens = args.max_tokens
    reasoner_context = args.reasoner_context_window

    reasoning_level = ReasoningLevel(args.reasoning_level)

    config.models[ModelRole.REASONER] = ModelConfig(
        role=ModelRole.REASONER,
        provider=reasoner_provider,
        model=reasoner_model,
        api_key=reasoner_api_key,
        base_url=reasoner_base_url,
        temperature=reasoner_temp,
        max_tokens=reasoner_max_tokens,
        context_window=reasoner_context,
        reasoning_level=reasoning_level,
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


# ======================================================================
# Executor stage: REASONER -> (heuristic) -> run_loop using SUMMARIZER model
# ----------------------------------------------------------------------
# The multi_mode Reasoner can only produce TEXT (every multi_mode backend
# has native tool-calling removed), so on its own it never executes tools.
# We bridge that here: when the planner's answer needs real implementation,
# we hand it as a brief to the proven single-agent run_loop Orchestrator,
# driven by the model configured in the SUMMARIZER slot. That loop uses the
# <tool> text protocol to read/edit/validate the actual project.
# ======================================================================

# Action verbs that signal the user wants something implemented (not just
# explained). Mirrors the single-agent loop's intent gate.
_ACTION_VERB_RE = re.compile(
    r"\b(implement|fix|write|create|edit|update|modify|refactor|add|delete|"
    r"remove|rename|build|generate|patch|change|apply|install|setup|"
    r"configure|migrate|port|replace|integrate|scaffold|"
    r"implementing|adding|creating|building|fixing|updating|generating|"
    r"integrating|refactoring|writing|editing|patching|replacing|"
    r"implements|adds|creates|builds|fixes)\b",
    re.IGNORECASE,
)
_CODE_FENCE_RE = re.compile(r"```")
# A file-path-ish token: an extension we care about, or a common source dir.
_FILE_PATH_RE = re.compile(
    r"\b[\w./-]+\.(?:py|dart|yaml|yml|json|js|ts|tsx|html|css|md|sql)\b"
    r"|\bNEW FILE\b|\blib/|\bapp/|\bbin/|\bsrc/",
    re.IGNORECASE,
)


def _needs_implementation(task: str, answer: str) -> bool:
    """Heuristic gate: should the planner's answer be handed to the
    tool-using executor (run_loop) to actually implement it?

    Implementation-biased (the whole point is to make the agent ACT):
    fires when the original request shows action intent, OR the planner's
    answer contains code blocks together with file-path markers.
    """
    task = task or ""
    answer = answer or ""
    if _ACTION_VERB_RE.search(task):
        return True
    if _CODE_FENCE_RE.search(answer) and _FILE_PATH_RE.search(answer):
        return True
    return False


def _build_execution_brief(user_request: str, planner_answer: str) -> str:
    """Wrap the planner's answer as a brief for the executor run_loop."""
    return (
        "[EXECUTION BRIEF] A planner agent produced the plan/solution below "
        "for the user's request. Implement it for real in this project: read "
        "the actual files first, then make the necessary edits / create the "
        "necessary files. Do NOT paste placeholder or mock code -- adapt to "
        "the real codebase and respect the user's constraints. When done, "
        "report what you changed and the validation result.\n\n"
        "=== USER REQUEST ===\n"
        f"{user_request}\n\n"
        "=== PLANNER OUTPUT ===\n"
        f"{planner_answer}"
    )


# Directories never worth showing the planner (build output, VCS, caches).
_TREE_IGNORE_DIRS = frozenset({
    ".git", ".dart_tool", "build", ".idea", ".vscode", "node_modules",
    "__pycache__", ".gradle", ".pub-cache", "Pods", ".venv", "venv",
    "dist", "out", ".next", ".expo", ".cxx", "DerivedData",
})


def _build_project_tree(base_path: str, max_entries: int = 1500, max_depth: int = 10) -> str:
    """Build a bounded, indented listing of the project's files and nested
    folders so the tool-less planner can reference REAL paths instead of
    inventing them. Skips build output / VCS / cache and hidden dirs.
    """
    try:
        base = os.path.abspath(base_path)
    except Exception:  # noqa: BLE001
        return ""
    if not os.path.isdir(base):
        return ""
    lines = []
    count = 0
    truncated = False
    for root, dirs, files in os.walk(base):
        rel = os.path.relpath(root, base)
        depth = 0 if rel == "." else (rel.count(os.sep) + 1)
        if depth >= max_depth:
            dirs[:] = []
        # Prune ignored / hidden dirs in place (sorted for stable output).
        dirs[:] = sorted(
            d for d in dirs
            if d not in _TREE_IGNORE_DIRS and not d.startswith(".")
        )
        indent = "  " * depth
        if rel != ".":
            lines.append(f"{indent}{os.path.basename(root)}/")
        for fname in sorted(files):
            if fname.startswith("."):
                continue
            if count >= max_entries:
                truncated = True
                break
            lines.append(f"{indent}  {fname}")
            count += 1
        if truncated:
            break
    body = "\n".join(lines)
    if not body:
        return ""
    header = f"PROJECT FILE TREE (root: {base}) -- real paths, use these:\n"
    if truncated:
        body += f"\n... (truncated at {max_entries} files)"
    return header + body


def _build_executor_orchestrator(args, summarizer_cfg, path_filter, db_connections):
    """Build a single-agent run_loop Orchestrator to act as the EXECUTOR
    stage, driven by the SUMMARIZER-slot model.

    Returns None when no summarizer model is configured or its provider is
    unsupported / fails to build -- the caller then falls back to returning
    the planner's answer unchanged.
    """
    if summarizer_cfg is None or not getattr(summarizer_cfg, "model", ""):
        print(
            "[orch_multi] No SUMMARIZER model configured -> executor stage "
            "disabled; planner answer goes straight to the UI.",
            file=sys.stderr, flush=True,
        )
        return None

    provider = (getattr(summarizer_cfg, "provider", "") or "").lower().strip()
    try:
        from agent.backends import build_backend
        from agent.loop import Orchestrator as RunLoopOrchestrator
        from agent.core.policy import SecurityConfig
    except Exception as ex:  # noqa: BLE001
        print(f"[orch_multi] Executor imports failed: {ex}", file=sys.stderr, flush=True)
        return None

    # Map the ModelConfig to build_backend kwargs per provider.
    kwargs = {"model_id": summarizer_cfg.model}
    if getattr(summarizer_cfg, "api_key", None):
        kwargs["api_key"] = summarizer_cfg.api_key
    if provider == "ollama":
        if getattr(summarizer_cfg, "base_url", None):
            kwargs["base_url"] = summarizer_cfg.base_url
        kwargs["num_ctx"] = int(getattr(summarizer_cfg, "context_window", 32768) or 32768)
    elif provider == "openrouter":
        if getattr(summarizer_cfg, "base_url", None):
            kwargs["base_url"] = summarizer_cfg.base_url

    try:
        backend = build_backend(provider, **kwargs)
    except Exception as ex:  # noqa: BLE001
        print(
            f"[orch_multi] Could not build executor backend for provider "
            f"'{provider}': {ex}; executor stage disabled.",
            file=sys.stderr, flush=True,
        )
        return None

    try:
        security_config = SecurityConfig(sandbox_mode=bool(getattr(args, "sandbox", False)))
        executor = RunLoopOrchestrator(
            backend=backend,
            base_path=args.base_path,
            temperature=float(getattr(summarizer_cfg, "temperature", 0.2) or 0.2),
            max_tokens=max(int(getattr(summarizer_cfg, "max_tokens", 0) or 0), 8192),
            security_config=security_config,
            disable_tools=bool(getattr(args, "disable_tools", False)),
            path_filter=path_filter,
            db_connections=db_connections,
            task_mode="open",
            auto_num_ctx=False,
        )
    except Exception as ex:  # noqa: BLE001
        print(
            f"[orch_multi] Could not construct executor orchestrator: {ex}",
            file=sys.stderr, flush=True,
        )
        return None

    # Remove batch/multi-file tools that produce huge JSON payloads
    # exceeding max_tokens and causing truncation spirals. The model
    # must use patch_file (singular) one file at a time instead.
    # Note: write_files and patch_files were fully removed from the
    # tool registry in fs_write.py — they no longer exist to unregister.
    _oversized_tools = ("delete_files",)
    for tool_name in _oversized_tools:
        try:
            executor.tool_registry.unregister(tool_name)
        except Exception:  # noqa: BLE001
            pass  # tool may not be registered
    print(
        f"[orch_multi] Removed batch tools {_oversized_tools} from executor "
        f"to prevent truncation.",
        file=sys.stderr, flush=True,
    )

    print(
        f"[orch_multi] Executor stage ready (run_loop) using SUMMARIZER model "
        f"{provider}:{summarizer_cfg.model}.",
        file=sys.stderr, flush=True,
    )
    return executor


def _run_interactive_loop(args, path_filter=None, db_connections=None) -> None:
    """Interactive loop using the new multi_mode Orchestrator."""

    # Ensure stdout is line-buffered so the Flutter side sees __READY__ immediately.
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(line_buffering=True)
    print("__READY__", flush=True)
    print("[orch_multi] Ready for requests.", file=sys.stderr, flush=True)

    debug_mode = bool(getattr(args, "is_debug", False))
    debug_chat_path = _resolve_debug_chat_path(args.base_path, args.file_name) if debug_mode else ""
    if debug_mode:
        print(
            f"[orch_multi] DEBUG MODE active. Chat file: {debug_chat_path}",
            file=sys.stderr, flush=True,
        )

    orchestrator = None
    executor_orch = None  # lazily-built run_loop executor (SUMMARIZER model)
    last_exec_summary = ""  # brief summary of the previous execution
    try:
        while True:
            req = read_interactive_request(sys.stdin)
            if req is None:
                break  # EOF

            history = _normalise_external_history(req.get("history"))
            new_session = req.get("new_session") or bool(history)

            # Debug mode: ignore the incoming prompt and read the latest user
            # turn from the chat file. This lets a developer edit the file and
            # rerun the backend without touching the Flutter UI.
            prompt = (req.get("prompt") or "").strip()
            if debug_mode:
                file_prompt, file_history = _read_last_user_turn(debug_chat_path)
                if file_prompt:
                    prompt = file_prompt
                    history = file_history
                    new_session = False
                    print(
                        f"[orch_multi] Debug: loaded prompt ({len(prompt)} chars) "
                        f"with {len(history)} self turns from {debug_chat_path}",
                        file=sys.stderr, flush=True,
                    )

            if new_session or orchestrator is None:
                orchestrator = _create_orchestrator(args)

            # Per-request thinking/effort override: the Flutter UI controls
            # take effect immediately without restarting the subprocess.
            thinking_val = req.get("thinking")
            if isinstance(thinking_val, bool):
                # Update the reasoner model config's thinking flag.
                reasoner_cfg = orchestrator.config.models.get(ModelRole.REASONER)
                if reasoner_cfg:
                    reasoner_cfg.thinking = thinking_val
            effort_val = req.get("effort")
            if isinstance(effort_val, str) and effort_val.strip():
                effort_str = effort_val.strip().lower()
                reasoner_cfg = orchestrator.config.models.get(ModelRole.REASONER)
                if reasoner_cfg:
                    reasoner_cfg.effort = effort_str
            if not prompt:
                print(RESPONSE_SENTINEL)
                sys.stdout.flush()
                continue

            # Prepend visible self if provided
            full_prompt = _prompt_with_visible_history(prompt, history)

            # Context for the (tool-less) planner, assembled in order:
            #   1. APP CONTEXT from <root>/.agentic/.context.md -- loaded ALWAYS
            #      (the project's own analysis), per "prima di qualsiasi cosa".
            #   2. PROJECT FILE TREE -- only for code/dev requests (skipped for
            #      chit-chat like "hi"), so the planner cites real paths.
            context_parts = []
            try:
                from agent.core.project_context import load_project_context
                app_ctx = load_project_context(args.base_path)
                if app_ctx:
                    context_parts.append(
                        "APP CONTEXT (from .agentic/.context.md):\n" + app_ctx
                    )
            except Exception as ex_ctx:  # noqa: BLE001
                print(
                    f"[orch_multi] App context (.context.md) load skipped: {ex_ctx}",
                    file=sys.stderr, flush=True,
                )
            try:
                from agent.loop.tool_detector import ToolIntentDetector
                if ToolIntentDetector.needs_tools(prompt):
                    tree = _build_project_tree(args.base_path)
                    if tree:
                        context_parts.append(tree)
            except Exception as ex_tree:  # noqa: BLE001
                print(
                    f"[orch_multi] Project tree build skipped: {ex_tree}",
                    file=sys.stderr, flush=True,
                )
            project_context = "\n\n".join(context_parts)

            try:
                result = orchestrator.run(full_prompt, project_context=project_context)
                if result.success:
                    response = result.final_answer or "Task completed."
                else:
                    response = result.error or "Task failed."

                # --- Executor stage: REASONER -> run_loop (SUMMARIZER model) ---
                # When the planner's answer needs real implementation, hand it
                # as a brief to the single-agent run_loop Orchestrator driven by
                # the SUMMARIZER-slot model. That loop reads the real files,
                # edits/creates them, validates, and reports -- which is what
                # actually "uses tools". Falls back to the planner answer when
                # no executor is available or it errors.
                if (
                        result.success
                        and result.final_answer
                        and _needs_implementation(prompt, result.final_answer)
                ):
                    summarizer_cfg = orchestrator.config.models.get(ModelRole.SUMMARIZER)
                    if executor_orch is None:
                        executor_orch = _build_executor_orchestrator(
                            args, summarizer_cfg, path_filter, db_connections
                        )
                    if executor_orch is not None:
                        print(
                            "[orch_multi] Planner answer needs implementation "
                            "-> running executor stage (run_loop).",
                            file=sys.stderr, flush=True,
                        )
                        try:
                            # Preserve a brief summary of the previous
                            # execution so the executor knows what was
                            # already done. This prevents re-doing work
                            # when the user sends a follow-up correction
                            # like "There was a misunderstanding...".
                            executor_orch.reset()
                            if last_exec_summary:
                                executor_orch.conversation_history.set_system_prompt(
                                    "prev_execution",
                                    "[PREVIOUS EXECUTION CONTEXT]\n"
                                    "The following is a summary of changes "
                                    "made in the immediately preceding "
                                    "execution. The user may be asking for "
                                    "a correction or continuation. Do NOT "
                                    "redo work that is already done unless "
                                    "the user explicitly asks.\n\n"
                                    + last_exec_summary,
                                )
                                print(
                                    f"[orch_multi] Injected previous execution "
                                    f"summary ({len(last_exec_summary)} chars).",
                                    file=sys.stderr, flush=True,
                                )
                            brief = _build_execution_brief(prompt, result.final_answer)
                            exec_answer = executor_orch.run(brief)
                            if exec_answer and exec_answer.strip():
                                response = exec_answer
                                # Save a short summary for the next request.
                                last_exec_summary = exec_answer[:2000]
                            else:
                                last_exec_summary = ""
                        except Exception as ex_exec:  # noqa: BLE001
                            print(
                                f"[orch_multi] Executor stage failed: {ex_exec}; "
                                f"returning planner answer.",
                                file=sys.stderr, flush=True,
                            )
                            last_exec_summary = ""
            except Exception as ex:
                response = f"Error: {ex}"

            # Serialize as a single JSON string so embedded newlines survive.
            print(json.dumps({"response": response}))
            print(RESPONSE_SENTINEL)
            sys.stdout.flush()

            if debug_mode:
                _append_debug_response(debug_chat_path, response)
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
    parser.add_argument(
        "--reasoning-level",
        default="max",
        choices=["minimal", "low", "medium", "high", "max"],
        help="Reasoning effort level for the reasoner model. "
             "Maps to OpenAI reasoning_effort, Anthropic thinking.budget_tokens, "
             "Gemini thinkingConfig.thinkingBudget. Default: max.",
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

    args = parser.parse_args()

    if args.install_deps:
        _install_dependencies()
        sys.exit(0)

    print("[orch_multi] Starting...", file=sys.stderr, flush=True)

    # Load optional filters and DB connections (passed to the executor stage).
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
