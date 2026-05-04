"""Common base for every workflow agent."""
from __future__ import annotations

import os
import sys
from abc import ABC, abstractmethod
from typing import Any, Dict, List, Optional

from ..backends.backend_base import ModelBackend
from ..core.state import WorkflowState

# Cap on how much of each prompt/response is mirrored to stderr. Agents can
# emit several KB; the orchestrator log panel becomes useless if we dump it
# all. Override with HF_CHAT_AGENT_LOG_CHARS=N to widen.
_AGENT_LOG_CHARS = int(os.environ.get("HF_CHAT_AGENT_LOG_CHARS", "800"))


def _truncate(text: str) -> str:
    """Single-line, length-capped preview suitable for stderr logging."""
    cleaned = text.replace("\n", " ⏎ ").strip()
    if len(cleaned) <= _AGENT_LOG_CHARS:
        return cleaned
    return cleaned[:_AGENT_LOG_CHARS] + f"… (+{len(cleaned) - _AGENT_LOG_CHARS} chars)"


class Agent(ABC):
    """A single role in the multi-agent workflow.

    All concrete agents share the same shape:
      * one backend (already wrapped in :class:`RateLimitedBackend` if a TPM
        limit is configured for that role);
      * one system prompt that pins the role contract;
      * one ``run(state) -> state`` method that mutates the shared state.
    """

    name: str = "agent"

    def __init__(self, backend: ModelBackend, system_prompt: str,
                 *, temperature: float = 0.2, max_tokens: int = 1024):
        self.backend = backend
        self.system_prompt = system_prompt
        self.temperature = temperature
        self.max_tokens = max_tokens
        # Surfaces as `(name=…, model=…)` in trace entries. Both backends carry
        # `model_id` (RateLimitedBackend forwards it) so this never crashes.
        self.model_id = getattr(backend, "model_id", "(unknown)")

    @abstractmethod
    def run(self, state: WorkflowState) -> WorkflowState:
        """Mutate-and-return the workflow state."""
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Helpers shared by concrete agents
    # ------------------------------------------------------------------
    def _chat(self, messages: List[Dict[str, Any]],
              tools: Optional[List[Dict[str, Any]]] = None,
              max_tokens: Optional[int] = None,
              temperature: Optional[float] = None) -> tuple[str, str]:
        """Call the backend with this agent's defaults, allowing per-call overrides."""
        # Mirror what the user (or shaper/executor output) is sending into
        # this layer to stderr so the orchestrator log panel can show the
        # conversation between agents. Only the *last* user message is
        # logged here — the system prompt is static and the prior assistant
        # messages were already logged on their producing turn.
        last_user = ""
        for m in reversed(messages):
            if m.get("role") == "user":
                last_user = str(m.get("content") or "")
                break
        print(
            f"[agent:{self.name}→{self.model_id}] {_truncate(last_user)}",
            file=sys.stderr, flush=True,
        )

        text, finish_reason = self.backend.chat(
            messages=messages,
            max_tokens=max_tokens if max_tokens is not None else self.max_tokens,
            temperature=temperature if temperature is not None else self.temperature,
            tools=tools,
        )

        print(
            f"[agent:{self.name}←{self.model_id}] {_truncate(text or '')}",
            file=sys.stderr, flush=True,
        )
        return text, finish_reason

    def _build_messages(self, user_content: str,
                        history: Optional[List[Dict[str, Any]]] = None
                        ) -> List[Dict[str, Any]]:
        """Compose ``[system, …history, user]`` for a one-shot agent call."""
        messages: List[Dict[str, Any]] = [
            {"role": "system", "content": self.system_prompt}
        ]
        if history:
            for m in history:
                role = m.get("role")
                # Pass through "system" too — Workflow.finalize injects synthetic
                # system messages summarizing the prior turn's tool calls and
                # results so the next turn doesn't waste calls re-discovering
                # state the previous turn already established.
                if role in ("user", "assistant", "system"):
                    messages.append({"role": role, "content": m.get("content", "")})
        messages.append({"role": "user", "content": user_content})
        return messages
