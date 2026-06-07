"""Summarizer agent - compresses conversation history."""

from __future__ import annotations

from typing import List, Optional

from multi_mode.config.agent import AgentConfig
from multi_mode.core.message import Message
from multi_mode.backends.base import LLMBackend


class Summarizer:
    """Summarizes conversation history using a cheap model."""

    def __init__(self, config: AgentConfig, backend: LLMBackend):
        self.config = config
        self.backend = backend

    def summarize(self, messages: List[Message], project_context: str = "") -> Optional[str]:
        """Summarize the conversation history.

        Preserves: decisions, tool results, errors, current plan.
        Compresses: verbose explanations, repeated context.
        """
        if not messages:
            return None

        # Build a prompt for summarization
        conversation_text = "\n".join(
            f"[{msg.role.value if hasattr(msg.role, 'value') else msg.role}] {msg.content[:500]}"
            for msg in messages
            if msg.content
        )

        prompt = (
            "Summarize the following conversation between an AI agent and tools.\n"
            "Preserve: key decisions, tool results, errors encountered, and the current plan.\n"
            "Compress: verbose explanations, repeated context, and irrelevant details.\n"
            "Keep the summary concise but complete.\n\n"
            f"{conversation_text}\n\n"
            "Summary:"
        )

        try:
            response = self.backend.complete(
                messages=[{"role": "user", "content": prompt}],
                temperature=0.1,
                max_tokens=1024,
            )
            return response.content.strip() if response.content else None
        except Exception:
            return None
