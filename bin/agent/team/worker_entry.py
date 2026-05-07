"""Worker subprocess entry point.

Boot contract (env vars set by the host's :mod:`runner`):
    TEAM_BOARD_PATH      — absolute path to ``team_board.md``
    TEAM_ARTIFACT_DIR    — absolute path to the ``artifacts/`` dir
    TEAM_GROUP           — this worker's group name
    TEAM_OWNER_MODEL     — display label only (model selection is via --agent-config)
    TEAM_DEPS            — comma-separated upstream group names
    TEAM_BASE_PATH       — project root (sandbox boundary for tools)

CLI:
    --group GROUP       — required (the group this subprocess owns).
    All flags accepted by ``orchestrator.py`` for backend/agent-config
    are accepted here too — the host forwards its own argv so the
    worker builds a Workflow with the same configuration.

Behavior:
  1. Read the board, slice this group's section, mark RUNNING.
  2. Read each dep's artifact JSON.
  3. Build the boot prompt (system context + plan + dep summaries).
  4. Build a Workflow and call ``run(boot_prompt)``.
  5. Write the handoff artifact, stamp DONE_CLEAN / DONE_WITH_WARNINGS,
     or FAILED on caught exception.

Exit code:
    0 on DONE_*, 1 on FAILED, anything else means crash → host stamps
    INTERRUPTED.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import traceback
from pathlib import Path
from typing import Any, Dict, List, Optional

sys.dont_write_bytecode = True

# Make the ``agent`` package importable regardless of how we're launched.
_THIS = Path(__file__).resolve()
_BIN_DIR = _THIS.parents[2]   # bin/
if str(_BIN_DIR) not in sys.path:
    sys.path.insert(0, str(_BIN_DIR))

from agent.team.artifact import Artifact, read_artifact, write_artifact   # noqa: E402
from agent.team.board import (                                             # noqa: E402
    BoardSection,
    PlanStep,
    read_board,
    slice_section,
    slice_status_table,
    write_board,
)
from agent.team.paths import TeamPaths                                     # noqa: E402
from agent.team.soft_breaker import maybe_compact_section                  # noqa: E402
from agent.team.status import Status                                       # noqa: E402
# Imported at module level so tests can monkey-patch the symbol on
# this module (rather than reaching into agent.core.workflow).
from agent.core.workflow import build_workflow_from_args                   # noqa: E402
from agent.path_filter import PathFilter                                   # noqa: E402
from agent.policy import SecurityConfig                                    # noqa: E402

logger = logging.getLogger("team.worker")


# ----------------------------------------------------------------------
# CLI — accepts (and ignores) the orchestrator flags so argv forwarding
# works without a per-flag passthrough table.
# ----------------------------------------------------------------------
def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Team Mode worker subprocess")
    p.add_argument("--group", required=True)
    # Same flags as orchestrator.py (kept loose; we only NEED the
    # multi-agent + agent-config flags, but the host may forward more).
    p.add_argument("--backend",
                   choices=["huggingface", "ollama", "groq",
                            "gemini", "openrouter", "github"],
                   default="gemini")
    p.add_argument("--hf-token", default="")
    p.add_argument("--model", default="")
    p.add_argument("--ollama-base-url", default="http://localhost:11434")
    p.add_argument("--ollama-api-key", default="")
    p.add_argument("--ollama-num-ctx", type=int, default=8192)
    p.add_argument("--temperature", type=float, default=0.2)
    p.add_argument("--max-tokens", type=int, default=8192)
    p.add_argument("--tpm-limit", type=int, default=0)
    p.add_argument("--groq-api-key", default="")
    p.add_argument("--gemini-api-key", default="")
    p.add_argument("--openrouter-api-key", default="")
    p.add_argument("--github-api-key", default="")
    p.add_argument("--base-path", default=".")
    p.add_argument("--sandbox", action="store_true")
    p.add_argument("--audit-log", default="")
    p.add_argument("--disable-tools", action="store_true")
    p.add_argument("--max-file-size-mb", type=float, default=10.0)
    p.add_argument("--multi-agent", action="store_true", default=True)
    p.add_argument("--agent-config", default="")
    p.add_argument("--filters-config", default="")
    return p


# ----------------------------------------------------------------------
# Boot prompt builder
# ----------------------------------------------------------------------
def _format_dep_summary(dep_group: str, artifact: Artifact) -> str:
    lines: List[str] = [f"### Upstream artifact: {dep_group}"]
    lines.append(f"status: {artifact.status.value}")
    if artifact.summary:
        lines.append(f"summary: {artifact.summary}")
    if artifact.interfaces_exposed:
        lines.append("interfaces:")
        for it in artifact.interfaces_exposed[:10]:
            name = it.get("name", "?")
            t = it.get("type", "?")
            note = it.get("notes")
            extra = f" — {note}" if note else ""
            lines.append(f"  - {name}: {t}{extra}")
    if artifact.files_touched:
        lines.append("files_touched:")
        for f in artifact.files_touched[:15]:
            lines.append(f"  - {f.get('action', '?')} {f.get('path', '?')}")
    if artifact.warnings:
        lines.append("warnings:")
        for w in artifact.warnings[:5]:
            lines.append(f"  - {w}")
    return "\n".join(lines)


def _build_boot_prompt(
    *, group: str,
    section_text: str,
    status_table: str,
    dep_artifacts: Dict[str, Artifact],
) -> str:
    deps_block = ""
    if dep_artifacts:
        deps_block = "\n\n".join(
            _format_dep_summary(name, a) for name, a in dep_artifacts.items()
        )
    else:
        deps_block = "(no upstream dependencies)"

    return (
        "You are running as a worker in TEAM MODE. Your scope is "
        f"strictly limited to group `{group}`. Do not work on other groups.\n\n"
        "## Status table (whole team — for context only)\n"
        f"{status_table or '(missing)'}\n"
        "## Your section (your assigned plan)\n"
        f"{section_text or '(missing)'}\n\n"
        "## Upstream dependency artifacts\n"
        f"{deps_block}\n\n"
        "## Instructions\n"
        f"Execute every step of your plan for group `{group}` USING TOOLS. "
        "Reading files, editing files, searching, and running validators "
        "all require tool calls — do NOT just describe what you would do. "
        "Prose answers without tool usage are treated as a hallucinated "
        "result and reported back to the user as a warning.\n\n"
        "If a plan step is conceptual (e.g. 'verify' or 'document'), "
        "interpret it concretely: replace 'verify' with `flutter_analyze` "
        "or `search_in_files` to confirm the change; replace 'document' "
        "with appending notes to the relevant file via `append_file`. If "
        "no concrete interpretation is possible for a step, skip it "
        "rather than fabricating progress.\n\n"
        "When all steps are done, produce a final answer that succinctly "
        "summarizes what you did, the files you touched, and any warnings. "
        "Do not start work on other groups."
    )


# ----------------------------------------------------------------------
# Section update helpers
# ----------------------------------------------------------------------
def _stamp_running(paths: TeamPaths, group: str) -> None:
    bf = read_board(paths.board)
    bf.set_status(group, Status.RUNNING, last_step="0/?")
    section = bf.sections.get(group)
    if section is not None:
        section.log.append("worker started")
    write_board(paths.board, bf)


def _stamp_terminal(paths: TeamPaths, group: str,
                    status: Status, last_step: str,
                    log_line: str) -> None:
    bf = read_board(paths.board)
    bf.set_status(group, status, last_step=last_step)
    section = bf.sections.get(group)
    if section is not None:
        section.log.append(log_line)
    write_board(paths.board, bf)


def _load_dep_artifacts(paths: TeamPaths, deps: List[str]) -> Dict[str, Artifact]:
    out: Dict[str, Artifact] = {}
    for d in deps:
        if not d:
            continue
        p = paths.artifact_path(d)
        if not p.exists():
            logger.warning("Dep artifact missing: %s", p)
            continue
        try:
            out[d] = read_artifact(p)
        except Exception as e:
            logger.warning("Dep artifact unreadable %s: %s", p, e)
    return out


# ----------------------------------------------------------------------
# Result extraction from Workflow output
# ----------------------------------------------------------------------
# State-changing tools — a worker that called none of these did not
# actually do any code-modification work.
_STATE_CHANGING_TOOLS = frozenset({
    "write_file", "append_file", "patch_file",
    "delete_file", "move_file", "create_directory",
})

# Display-friendly action label per write tool.
_TOOL_ACTION = {
    "write_file": "wrote",
    "append_file": "appended",
    "patch_file": "patched",
    "delete_file": "deleted",
    "move_file": "moved",
    "create_directory": "mkdir",
}


def _classify_response(response: str, tool_calls: List[Dict[str, Any]]) -> Status:
    """Decide DONE_CLEAN / DONE_WITH_WARNINGS / FAILED for the worker.

    Rules:
      - Empty response → FAILED.
      - Response starts with 'ERROR:' (or has 'error: ' early) → FAILED.
      - Response is non-error AND the worker called ZERO tools → the
        worker produced pure prose without engaging with the codebase.
        Almost always means the 'work' was hallucinated. → DONE_WITH_WARNINGS.
      - Otherwise → DONE_CLEAN.

    Note: groups whose plan is explicitly read-only (audit, design) can
    still hit DONE_CLEAN as long as they called at least one tool —
    e.g. read_file / search_in_files. The warning is only for workers
    that called nothing at all.
    """
    if not response:
        return Status.FAILED
    lower = response.lower()
    if lower.startswith("error:") or "error: " in lower[:80]:
        return Status.FAILED
    if not tool_calls:
        return Status.DONE_WITH_WARNINGS
    return Status.DONE_CLEAN


def _files_touched_from_tool_calls(
    tool_calls: List[Dict[str, Any]],
) -> List[Dict[str, Any]]:
    """Reduce the workflow's tool history to the actual file mutations.

    Filters to successful state-changing calls. Each entry shape matches
    the artifact's ``files_touched`` schema: ``{"path", "action"}``.
    """
    out: List[Dict[str, Any]] = []
    for c in tool_calls or []:
        tool = c.get("tool")
        if tool not in _STATE_CHANGING_TOOLS:
            continue
        if c.get("status") != "success":
            continue
        path = c.get("path") or "?"
        out.append({"path": path, "action": _TOOL_ACTION.get(tool, tool)})
    return out


def _summarize_tool_usage(tool_calls: List[Dict[str, Any]]) -> Dict[str, int]:
    """Compact ``{tool_name: success_count}`` for quick reporting."""
    counts: Dict[str, int] = {}
    for c in tool_calls or []:
        if c.get("status") != "success":
            continue
        name = c.get("tool", "?")
        counts[name] = counts.get(name, 0) + 1
    return counts


def _write_failed_artifact(
    paths: TeamPaths, group: str, owner_model: str, reason: str,
) -> None:
    """Write a minimal FAILED artifact so the host/leader can see WHY
    a worker died, even when it dies before reaching the normal
    artifact-write path. Best effort — never raises.
    """
    summary = (reason or "unknown error").strip()
    if len(summary) > 1500:
        summary = summary[:1497] + "..."
    artifact = Artifact(
        group=group, producer_model=owner_model,
        status=Status.FAILED,
        summary=f"ERROR: {summary}" if not summary.lower().startswith("error")
        else summary,
    )
    try:
        write_artifact(paths.artifact_path(group), artifact)
    except Exception as e:
        # Last-ditch — log to stderr so the worker_entry stderr file
        # at least carries the original error.
        print(f"[worker:{group}] failed to write FAILED artifact: {e}",
              file=sys.stderr, flush=True)


def _build_artifact_from_response(
    *, group: str, owner_model: str,
    response: str, status: Status,
    section: Optional[BoardSection],
    tool_calls: Optional[List[Dict[str, Any]]] = None,
) -> Artifact:
    summary = (response or "").strip()
    if len(summary) > 1500:
        summary = summary[:1497] + "..."
    # Authoritative source for files_touched: the workflow's tool_calls
    # list. The earlier section-log heuristic missed everything because
    # nothing populates the section log mid-workflow.
    files_touched = _files_touched_from_tool_calls(tool_calls or [])
    warnings: List[str] = []
    if status == Status.DONE_WITH_WARNINGS and not files_touched and not (tool_calls or []):
        warnings.append(
            "Worker produced prose only — no tools were called. "
            "The reported result is unreliable; verify nothing was "
            "actually changed."
        )
    if section is not None:
        for entry in section.log:
            if "warning" in entry.lower():
                warnings.append(entry)
    return Artifact(
        group=group, producer_model=owner_model,
        status=status, summary=summary,
        files_touched=files_touched, warnings=warnings,
    )


# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
def main() -> int:
    parser = _build_parser()
    args = parser.parse_args()

    group = args.group
    board_path = Path(os.environ["TEAM_BOARD_PATH"])
    artifact_dir = Path(os.environ["TEAM_ARTIFACT_DIR"])
    owner_model = os.environ.get("TEAM_OWNER_MODEL", args.model or "?")
    deps_raw = os.environ.get("TEAM_DEPS", "")
    deps = [d for d in (s.strip() for s in deps_raw.split(",")) if d]
    base_path = os.environ.get("TEAM_BASE_PATH", args.base_path)
    session_id = os.environ.get("TEAM_SESSION_ID")

    paths = TeamPaths.for_session(base_path, session_id) if session_id \
        else TeamPaths.from_base(base_path)
    paths.ensure_dirs()

    print(f"[worker:{group}] starting (owner_model={owner_model}, deps={deps})",
          file=sys.stderr, flush=True)

    # Mark RUNNING — even if we crash before producing an artifact, the
    # board reflects that we tried.
    try:
        _stamp_running(paths, group)
    except Exception as e:
        print(f"[worker:{group}] failed to stamp RUNNING: {e}",
              file=sys.stderr, flush=True)
        return 2  # host will stamp INTERRUPTED

    # Read inputs
    try:
        board_text = board_path.read_text(encoding="utf-8")
        section_text = slice_section(board_text, group) or ""
        status_table = slice_status_table(board_text)
        dep_artifacts = _load_dep_artifacts(paths, deps)
    except Exception as e:
        print(f"[worker:{group}] read inputs failed: {e}",
              file=sys.stderr, flush=True)
        _stamp_terminal(paths, group, Status.FAILED, "0/?",
                        f"read inputs failed: {e}")
        _write_failed_artifact(paths, group, owner_model,
                               f"read inputs failed: {e}")
        return 1

    boot_prompt = _build_boot_prompt(
        group=group, section_text=section_text,
        status_table=status_table, dep_artifacts=dep_artifacts,
    )

    # Build the Workflow — the worker is essentially a one-shot run of
    # the existing multi-agent pipeline.
    try:
        path_filter = None
        if args.filters_config:
            try:
                cfg = json.loads(Path(args.filters_config).read_text(encoding="utf-8"))
                path_filter = PathFilter.from_config(args.base_path, cfg)
            except Exception:
                path_filter = None
        security_config = SecurityConfig(
            sandbox_mode=args.sandbox,
            max_file_size_bytes=int(args.max_file_size_mb * 1024 * 1024),
            enable_audit_log=bool(args.audit_log),
            audit_log_path=args.audit_log or "orchestrator_audit.log",
        )
        if not args.agent_config:
            raise RuntimeError("--agent-config is required for team workers")
        workflow = build_workflow_from_args(
            args,
            security_config=security_config,
            base_path=args.base_path,
            path_filter=path_filter,
        )
    except Exception as e:
        tb = traceback.format_exc(limit=3)
        print(f"[worker:{group}] workflow build failed: {e}\n{tb}",
              file=sys.stderr, flush=True)
        _stamp_terminal(paths, group, Status.FAILED, "0/?",
                        f"workflow build failed: {e}")
        _write_failed_artifact(paths, group, owner_model,
                               f"workflow build failed: {e}")
        return 1

    # Run
    try:
        result = workflow.run(boot_prompt)
        response = str(result.get("response") or "")
        tool_calls = list(result.get("tool_calls") or [])
    except Exception as e:
        tb = traceback.format_exc(limit=4)
        print(f"[worker:{group}] workflow.run crashed: {e}\n{tb}",
              file=sys.stderr, flush=True)
        _stamp_terminal(paths, group, Status.FAILED, "0/?",
                        f"workflow.run crashed: {e}")
        _write_failed_artifact(paths, group, owner_model,
                               f"workflow.run crashed: {e}")
        return 1

    # Determine status from response + actual tool usage. A non-error
    # response with zero tool calls is a giveaway: the worker hallucinated
    # progress without touching the codebase. Classify as DONE_WITH_WARNINGS
    # so the chat summary tells the truth.
    status = _classify_response(response, tool_calls)
    tool_summary = _summarize_tool_usage(tool_calls)
    print(f"[worker:{group}] workflow finished | status={status.value} "
          f"| response_chars={len(response)} | tools={tool_summary}",
          file=sys.stderr, flush=True)

    # Read final section to attach files-touched hints
    bf = read_board(paths.board)
    section = bf.sections.get(group)
    plan_total = len(section.plan) if section and section.plan else 0
    plan_done = sum(1 for s in (section.plan if section else []) if s.done)
    last_step = f"{plan_done}/{plan_total}" if plan_total else "—"

    artifact = _build_artifact_from_response(
        group=group, owner_model=owner_model,
        response=response, status=status, section=section,
        tool_calls=tool_calls,
    )
    if artifact.warnings and status == Status.DONE_CLEAN:
        status = Status.DONE_WITH_WARNINGS
        artifact.status = status

    # Soft size cap on artifact
    trim_applied = artifact.trim_to_budget()
    if trim_applied:
        print(f"[worker:{group}] artifact trimmed: {','.join(trim_applied)}",
              file=sys.stderr, flush=True)

    # Soft breaker: roll older log entries before terminal stamp
    try:
        compacted, rolled = maybe_compact_section(paths, group)
        if compacted:
            print(f"[worker:{group}] section log compacted "
                  f"(rolled {rolled} entries)",
                  file=sys.stderr, flush=True)
    except Exception as e:
        print(f"[worker:{group}] section compaction failed (non-fatal): {e}",
              file=sys.stderr, flush=True)

    try:
        write_artifact(paths.artifact_path(group), artifact)
    except Exception as e:
        print(f"[worker:{group}] artifact write failed: {e}",
              file=sys.stderr, flush=True)
        _stamp_terminal(paths, group, Status.FAILED, last_step,
                        f"artifact write failed: {e}")
        return 1

    _stamp_terminal(paths, group, status, last_step,
                    f"completed: {status.value}")
    return 0 if status in (Status.DONE_CLEAN, Status.DONE_WITH_WARNINGS) else 1


if __name__ == "__main__":
    raise SystemExit(main())
