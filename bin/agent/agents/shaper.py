"""Shaper — rewrites the user's raw prompt into an actionable agentic spec.

Runs at most once per workflow. After the first turn the Reasoner already
holds the shaped context, so re-shaping every follow-up just burns tokens.
Use a cheap-but-not-tiny model (Groq llama-3.1-8b, Gemini Flash) — too small
and the rewrite degrades the prompt instead of improving it.
"""

from __future__ import annotations

import sys
from typing import Optional

from ..core.state import WorkflowState
from .base import Agent


_SHAPER_SYSTEM_PROMPT = (
    "You are a prompt-shaping assistant. Your job is to take a user's raw "
    "request and rewrite it as a precise, actionable specification a "
    "reasoning agent can act on. Do NOT answer the request. Do NOT add new "
    "tasks. Preserve the user's intent exactly.\n"
    "\n"
    "If the user's latest message is a short confirmation or follow-up "
    '("ok", "ok proceed", "yes do it", "go ahead", "continue", '
    '"fix it", "now do X"), use the prior conversation in the message '
    "history to infer what concretely needs to be done next, and produce a "
    "spec for THAT — not for the literal short reply.\n"
    "\n"
    "Output format — exactly these sections, in this order:\n"
    "  Goal: <one sentence describing what the user wants>\n"
    "  Constraints: <any limits the user mentioned, or 'none'>\n"
    "  Success criteria: <how we know we're done>\n"
    "\n"
    "Keep the whole response under 120 words. Plain text — no markdown "
    "headers, no bullets, no preamble."
)


class ShaperAgent(Agent):
    name = "shaper"

    def __init__(
        self,
        backend,
        *,
        system_prompt: Optional[str] = None,
        temperature: float = 0.2,
        max_tokens: int = 256,
    ):
        super().__init__(
            backend,
            system_prompt or _SHAPER_SYSTEM_PROMPT,
            temperature=temperature,
            max_tokens=max_tokens,
        )

    # ------------------------------------------------------------------
    def run(self, state: WorkflowState) -> WorkflowState:
        try:
            # Pass conversation history so the shaper can resolve short
            # follow-ups ("Ok proceed", "yes do it") against the prior turn.
            messages = self._build_messages(
                state.user_input,
                history=state.history,
            )
            text, _ = self._chat(messages)
        except Exception as e:  # noqa: BLE001
            print(f"[shaper] failed ({e}); falling back to raw input.", file=sys.stderr)
            state.shaped_prompt = state.user_input
            state.add_trace(self.name, output="(failed, raw input kept)", detail=str(e))
            return state

        shaped = (text or "").strip() or state.user_input
        state.shaped_prompt = shaped
        # Output line is the Goal: portion (first non-empty line) for compact
        # display. The full shaped text goes in `detail` so the UI can expand.
        first_line = next((l for l in shaped.splitlines() if l.strip()), shaped)
        state.add_trace(self.name, output=first_line[:160], detail=shaped)
        return state
