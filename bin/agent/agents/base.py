"""Common base for every workflow agent."""
from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any, Dict, List, Optional

from ..backends.backend_base import ModelBackend
from ..core.state import WorkflowState


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
        return self.backend.chat(
            messages=messages,
            max_tokens=max_tokens if max_tokens is not None else self.max_tokens,
            temperature=temperature if temperature is not None else self.temperature,
            tools=tools,
        )

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
                if role in ("user", "assistant"):
                    messages.append({"role": role, "content": m.get("content", "")})
        messages.append({"role": "user", "content": user_content})
        return messages
