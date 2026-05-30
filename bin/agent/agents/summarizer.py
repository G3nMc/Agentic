"""Summarizer — compacts older conversation history when a turn would
overflow the reasoner's context window.

This agent is **not** part of the main router → shaper → reasoner →
executor pipeline. It's only invoked by the workflow compactor when
``state.history`` plus the pending tool results would exceed the
reasoner's ``context_limit``. See ``agent.core.compactor``.

Design notes:
  - Uses a separate cheap model (configured via the optional
    ``summarizer`` role in agents.json) so the strong reasoner doesn't
    burn tokens on bookkeeping.
  - Has no ``run(state)`` use of its own — the compactor calls
    ``_chat`` directly with a one-shot prompt. We still inherit from
    :class:`Agent` so the standard ``_build_messages`` / ``_chat``
    helpers and stderr logging come for free.
"""

from __future__ import annotations

from typing import Optional

from ..core.state import WorkflowState
from .base import Agent


_SUMMARIZER_SYSTEM_PROMPT = (
    "You are a context-compaction agent. Your sole job is to read a "
    "conversation excerpt and produce a dense, faithful summary that "
    "preserves every fact a downstream reasoning agent would need. "
    "Rules:\n"
    "  - Keep file paths, identifiers, and error messages verbatim.\n"
    "  - Keep the user's standing requests and any decisions already made.\n"
    "  - Drop greetings, filler, and large file contents — replace those "
    "with a one-line note like 'read lib/foo.dart (812 lines)'.\n"
    "  - Output plain text only. No markdown headers, no bullet bloat.\n"
    "  - Stay under 1500 characters unless explicitly told otherwise.\n"
    "Never add information that wasn't in the excerpt. Never refuse — "
    "even partial summaries are useful."
)


class SummarizerAgent(Agent):
    """Tiny role used by the compactor; does not participate in routing."""

    name = "summarizer"

    def __init__(
        self,
        backend,
        *,
        system_prompt: Optional[str] = None,
        temperature: float = 0.2,
        max_tokens: int = 1024,
    ):
        super().__init__(
            backend,
            system_prompt or _SUMMARIZER_SYSTEM_PROMPT,
            temperature=temperature,
            max_tokens=max_tokens,
        )

    def run(self, state: WorkflowState) -> WorkflowState:
        # The summarizer is driven by the compactor, not by the
        # workflow dispatcher. If something does call .run() on it,
        # we no-op rather than crash.
        return state
