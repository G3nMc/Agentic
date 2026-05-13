"""Build a TeamSession from orchestrator-style args.

Lives here (not in ``orchestrator.py``) so the team package owns the
construction details and ``orchestrator.py`` stays a thin shim.
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import List, Optional

from ..backends import build_backend
from ..core.agent_config import (
    SecretsResolver,
    build_backend_for_role,
    load_role_configs,
)
from .leader import LeaderAgent
from .paths import TeamPaths
from .session import TeamSession


def _build_leader_backend(args, *, fallback_role_cfgs):
    """Build the backend the leader will talk to.

    Priority:
      1. The ``leader`` role in agents.json (preferred — lets the user
         pick a different model than the reasoner).
      2. The ``reasoner`` role's backend (sane default: leader is light
         work, sharing the reasoner's model is fine).
      3. The CLI ``--backend`` / ``--model`` (last resort, single-agent fallback).
    """
    secrets = SecretsResolver(args)
    cache = {}

    if "leader" in fallback_role_cfgs:
        cfg = fallback_role_cfgs["leader"]
        backend = build_backend_for_role(cfg, secrets, cache)
        return backend, cfg.model
    if "reasoner" in fallback_role_cfgs:
        cfg = fallback_role_cfgs["reasoner"]
        backend = build_backend_for_role(cfg, secrets, cache)
        return backend, cfg.model

    # Last resort
    kwargs = secrets.kwargs_for(args.backend, args.model or "")
    backend = build_backend(args.backend, **kwargs)
    return backend, args.model or args.backend


def build_team_session_from_args(args, *,
                                 session_id: str | None = None) -> TeamSession:
    """Construct a fully wired ``TeamSession`` ready to ``run(user_task)``.

    Reuses the worker forwarding contract: the host's argv is repackaged
    into a small set of flags the worker subprocess accepts. API keys
    flow through env vars (already in ``os.environ`` at this point).

    ``session_id`` is the conversation id from the Flutter chat — used
    to isolate this session's board/artifacts/logs from sibling chats.
    When omitted, falls back to the legacy shared ``_default`` folder.
    """
    if not args.agent_config:
        raise RuntimeError(
            "Team Mode requires --agent-config (the same JSON the multi-agent "
            "workflow uses)."
        )
    role_cfgs = load_role_configs(args.agent_config)

    leader_backend, leader_model_id = _build_leader_backend(
        args, fallback_role_cfgs=role_cfgs,
    )

    paths = TeamPaths.for_session(args.base_path, session_id) \
        if session_id else TeamPaths.from_base(args.base_path)
    paths.ensure_dirs()
    leader = LeaderAgent(backend=leader_backend, paths=paths)

    # Forward enough of the host's argv that the worker subprocess can
    # rebuild the same Workflow. The Flutter manager passes provider API
    # keys to THIS process via argv (not env), so we must forward them
    # explicitly — otherwise the worker's SecretsResolver can't
    # authenticate any backend and `build_workflow_from_args` raises
    # before the worker can even write an artifact.
    worker_extra_args: List[str] = [
        "--multi-agent",
        "--agent-config", str(args.agent_config),
        "--base-path", str(args.base_path),
    ]
    if getattr(args, "backend", None):
        worker_extra_args += ["--backend", args.backend]
    if getattr(args, "filters_config", None):
        worker_extra_args += ["--filters-config", args.filters_config]
    if getattr(args, "db_connections_config", None):
        worker_extra_args += [
            "--db-connections-config", args.db_connections_config,
        ]
    if getattr(args, "sandbox", False):
        worker_extra_args += ["--sandbox"]
    if getattr(args, "audit_log", None):
        worker_extra_args += ["--audit-log", args.audit_log]

    # Provider auth + provider-specific flags. Iterate so adding a new
    # backend later is a one-line change.
    auth_flag_map = (
        ("--hf-token",            "hf_token"),
        ("--gemini-api-key",      "gemini_api_key"),
        ("--groq-api-key",        "groq_api_key"),
        ("--openrouter-api-key",  "openrouter_api_key"),
        ("--github-api-key",      "github_api_key"),
        ("--ollama-api-key",      "ollama_api_key"),
        ("--ollama-base-url",     "ollama_base_url"),
        ("--model",               "model"),
    )
    for flag, attr in auth_flag_map:
        val = getattr(args, attr, None)
        if val:
            worker_extra_args += [flag, str(val)]
    if getattr(args, "ollama_num_ctx", None):
        worker_extra_args += ["--ollama-num-ctx", str(args.ollama_num_ctx)]

    return TeamSession(
        paths=paths,
        leader=leader,
        base_path=args.base_path,
        leader_model_id=leader_model_id,
        worker_entry="agent.team.worker_entry",
        worker_extra_args=worker_extra_args,
        timeout_s=15 * 60,
    )
