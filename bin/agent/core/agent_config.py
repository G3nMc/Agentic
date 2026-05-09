"""Load per-role agent configuration from a JSON file written by the Flutter UI.

The on-disk schema (one object per role):

    {
      "router":   {"backend": "ollama",   "model": "llama3.2:1b",
                   "tpm_limit": 0, "temperature": 0.0, "max_tokens": 8},
      "shaper":   {"backend": "groq",     "model": "llama-3.1-8b-instant",
                   "tpm_limit": 6000, "temperature": 0.2, "max_tokens": 256},
      "reasoner": {"backend": "gemini",   "model": "gemini-2.5-flash",
                   "tpm_limit": 0, "temperature": 0.2, "max_tokens": 4096},
      "executor": {"backend": "gemini",   "model": "gemini-2.5-flash",
                   "tpm_limit": 0, "temperature": 0.4, "max_tokens": 1024}
    }

API keys are NOT in this file — they come from the existing CLI flags / env
vars (the same plumbing the single-agent mode uses). This avoids duplicating
secrets storage between Flutter and Python.
"""
from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional

from ..backends import RateLimitedBackend, build_backend
from ..backends.backend_base import ModelBackend


# Roles in the order the dispatcher evaluates them.
# "leader" is optional and only used when --team-mode is on.
AGENT_ROLES = ("router", "shaper", "reasoner", "executor", "leader", "summarizer")

# Defaults applied when the JSON omits a role or a field. Chosen for
# "works out of the box if you only configured Gemini" — every role falls
# back to the Reasoner's backend.
_FIELD_DEFAULTS: Dict[str, Any] = {
    "tpm_limit": 0,
    "temperature": 0.2,
    "max_tokens": 1024,
}


@dataclass
class RoleConfig:
    role: str
    backend: str
    model: str
    tpm_limit: int = 0
    temperature: float = 0.2
    max_tokens: int = 1024
    # Optional Ollama-specific overrides; ignored for other backends.
    ollama_base_url: Optional[str] = None
    ollama_num_ctx: Optional[int] = None


# ----------------------------------------------------------------------
# Secrets resolver
# ----------------------------------------------------------------------
class SecretsResolver:
    """Maps a backend name to the kwargs its constructor expects.

    The resolver is fed by ``orchestrator.py`` from the parsed CLI args —
    the same fallback chain the single-agent mode uses. Adding a new
    backend means: register its kwargs builder here.
    """

    def __init__(self, args):
        self.args = args

    def kwargs_for(self, backend_name: str, model_id: str,
                   *, ollama_base_url: Optional[str] = None,
                   ollama_num_ctx: Optional[int] = None) -> Dict[str, Any]:
        a = self.args
        b = backend_name.lower().strip()
        if b == "huggingface":
            return {"hf_token": a.hf_token or "", "model_id": model_id}
        if b == "ollama":
            return {
                "model_id": model_id,
                "base_url": ollama_base_url or a.ollama_base_url,
                "num_ctx": ollama_num_ctx or a.ollama_num_ctx,
                "api_key": a.ollama_api_key or "",
            }
        if b == "groq":
            key = a.groq_api_key or os.environ.get("GROQ_API_KEY", "")
            return {"api_key": key, "model_id": model_id}
        if b == "gemini":
            key = (a.gemini_api_key
                   or os.environ.get("GOOGLE_API_KEY", "")
                   or os.environ.get("GEMINI_API_KEY", ""))
            return {"api_key": key, "model_id": model_id}
        if b == "openrouter":
            key = a.openrouter_api_key or os.environ.get("OPENROUTER_API_KEY", "")
            return {"api_key": key, "model_id": model_id}
        if b == "github":
            key = (a.github_api_key
                   or os.environ.get("GITHUB_TOKEN", "")
                   or os.environ.get("GITHUB_API_KEY", ""))
            return {"api_key": key, "model_id": model_id}
        raise ValueError(f"Unknown backend in agent config: {backend_name!r}")


# ----------------------------------------------------------------------
# Loader
# ----------------------------------------------------------------------
def load_role_configs(path: str | Path) -> Dict[str, RoleConfig]:
    """Read the agents.json file and return ``{role -> RoleConfig}``.

    Missing roles are dropped; the caller (``build_agents``) decides how to
    fall back. Validation is intentionally lenient — bad fields fall back
    to the per-field default rather than crashing the subprocess at boot.
    """
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"Agent config not found: {p}")
    with open(p, "r", encoding="utf-8") as f:
        raw = json.load(f)
    if not isinstance(raw, dict):
        raise ValueError("agents.json must be a JSON object keyed by role.")

    out: Dict[str, RoleConfig] = {}
    for role in AGENT_ROLES:
        entry = raw.get(role)
        if not isinstance(entry, dict):
            continue
        backend = str(entry.get("backend") or "").strip().lower()
        model = str(entry.get("model") or "").strip()
        if not backend or not model:
            print(f"[agent-config] role={role} missing backend/model; skipping.",
                  file=sys.stderr)
            continue
        out[role] = RoleConfig(
            role=role,
            backend=backend,
            model=model,
            tpm_limit=int(entry.get("tpm_limit") or _FIELD_DEFAULTS["tpm_limit"]),
            temperature=float(entry.get("temperature")
                              if entry.get("temperature") is not None
                              else _FIELD_DEFAULTS["temperature"]),
            max_tokens=int(entry.get("max_tokens") or _FIELD_DEFAULTS["max_tokens"]),
            ollama_base_url=entry.get("ollama_base_url"),
            ollama_num_ctx=(int(entry["ollama_num_ctx"])
                            if entry.get("ollama_num_ctx") not in (None, "")
                            else None),
        )
    if not out:
        raise ValueError("agents.json contained no usable role entries.")
    return out


# ----------------------------------------------------------------------
# Backend factory with caching
# ----------------------------------------------------------------------
def _backend_cache_key(cfg: RoleConfig) -> str:
    return f"{cfg.backend}|{cfg.model}|{cfg.tpm_limit}|{cfg.ollama_base_url}|{cfg.ollama_num_ctx}"


def build_backend_for_role(cfg: RoleConfig, secrets: SecretsResolver,
                           cache: Dict[str, ModelBackend]) -> ModelBackend:
    """Return a (possibly cached) backend for one role.

    Two roles that pick the same backend+model+tpm share a single
    ``RateLimitedBackend`` instance — that's the whole point of putting
    the rate limit *on the backend*: the per-minute budget is shared
    across roles when they hit the same provider. No double-spending.
    """
    key = _backend_cache_key(cfg)
    if key in cache:
        return cache[key]

    kwargs = secrets.kwargs_for(
        cfg.backend, cfg.model,
        ollama_base_url=cfg.ollama_base_url,
        ollama_num_ctx=cfg.ollama_num_ctx,
    )
    inner = build_backend(cfg.backend, **kwargs)
    if cfg.tpm_limit and cfg.tpm_limit > 0:
        inner = RateLimitedBackend(inner, tpm_limit=cfg.tpm_limit,
                                   label=f"{cfg.backend}:{cfg.role}")
    cache[key] = inner
    return inner


# ----------------------------------------------------------------------
# Top-level: load + instantiate every agent
# ----------------------------------------------------------------------
def build_agents(config_path: str | Path,
                 secrets: SecretsResolver,
                 *, tool_definitions: Optional[List[Dict[str, Any]]] = None,
                 tools_catalog_text: str = "") -> Dict[str, "Agent"]:
    """Read ``config_path``, build every agent, return ``{role -> Agent}``.

    Roles missing from the JSON are silently skipped; the dispatcher decides
    how to handle a missing role (e.g. shaper missing → skip shaping).
    """
    # Local import: agents/__init__.py imports from this module via
    # build_backend, so we keep this lazy to avoid an import cycle.
    from ..agents import (ExecutorAgent, ReasonerAgent, RouterAgent,
                          ShaperAgent, SummarizerAgent)

    cfgs = load_role_configs(config_path)
    cache: Dict[str, ModelBackend] = {}
    agents: Dict[str, Any] = {}

    if "router" in cfgs:
        c = cfgs["router"]
        agents["router"] = RouterAgent(
            build_backend_for_role(c, secrets, cache),
            temperature=c.temperature, max_tokens=c.max_tokens,
        )
    if "shaper" in cfgs:
        c = cfgs["shaper"]
        agents["shaper"] = ShaperAgent(
            build_backend_for_role(c, secrets, cache),
            temperature=c.temperature, max_tokens=c.max_tokens,
        )
    if "reasoner" in cfgs:
        c = cfgs["reasoner"]
        agents["reasoner"] = ReasonerAgent(
            build_backend_for_role(c, secrets, cache),
            tool_definitions=tool_definitions or [],
            tools_catalog_text=tools_catalog_text,
            temperature=c.temperature, max_tokens=c.max_tokens,
        )
    if "executor" in cfgs:
        c = cfgs["executor"]
        agents["executor"] = ExecutorAgent(
            build_backend_for_role(c, secrets, cache),
            temperature=c.temperature, max_tokens=c.max_tokens,
            iteration_timeout=getattr(c, 'iteration_timeout', 30.0),
        )
    if "summarizer" in cfgs:
        c = cfgs["summarizer"]
        agents["summarizer"] = SummarizerAgent(
            build_backend_for_role(c, secrets, cache),
            temperature=c.temperature, max_tokens=c.max_tokens,
        )

    if "reasoner" not in agents:
        raise ValueError(
            "agents.json must define at least the 'reasoner' role — it is the "
            "fallback used when other roles are missing."
        )
    return agents
