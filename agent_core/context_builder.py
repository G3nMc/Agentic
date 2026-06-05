"""Deterministic context builder - replaces the Shaper LLM call."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, List, Optional

from .state import Message
from .config import AgentConfig


@dataclass
class ContextBuildResult:
    """Result of context building."""
    messages: List[Message]
    token_count: int
    strategy_used: str  # 'full', 'sliding_window', 'summarized'
    truncated: bool


class ContextBuilder:
    """Builds the prompt context for the Reasoner deterministically.

    No LLM calls - pure Python logic for context management.
    """

    def __init__(self, config: AgentConfig, llm_client=None):
        self.config = config
        self.llm_client = llm_client

    def build(
        self,
        messages: List[Message],
        project_context: Optional[str] = None,
        system_prompt: Optional[str] = None,
    ) -> ContextBuildResult:
        """Build the context for the Reasoner.

        Args:
            messages: Full conversation history.
            project_context: Optional project context (file tree, key files, etc.).
            system_prompt: The system prompt to prepend.

        Returns:
            ContextBuildResult with the messages to send and metadata.
        """
        # Start with system prompt
        built_messages: List[Message] = []
        if system_prompt:
            built_messages.append(Message(role="system", content=system_prompt))

        # Add project context if provided
        if project_context:
            built_messages.append(
                Message(
                    role="system",
                    content=f"Project Context:\n{project_context}",
                    metadata={"type": "project_context"},
                )
            )

        # Calculate token budget for conversation history
        budget = self.config.token_budget
        # Reserve tokens for system prompt, project context, and response
        reserved = 4096  # rough reserve for response + overhead
        history_budget = budget - reserved

        if history_budget <= 0:
            history_budget = 1000  # minimum

        # Get conversation messages (non-system)
        conversation_messages = [m for m in messages if m.role != "system"]

        # Try full history first
        if self.llm_client:
            full_token_count = self.llm_client.count_tokens(built_messages + conversation_messages)
        else:
            full_token_count = self._estimate_tokens(built_messages + conversation_messages)

        if full_token_count <= history_budget:
            # Full history fits
            built_messages.extend(conversation_messages)
            return ContextBuildResult(
                messages=built_messages,
                token_count=full_token_count,
                strategy_used="full",
                truncated=False,
            )

        # Try sliding window: keep recent messages
        window_messages = self._sliding_window(conversation_messages, history_budget, built_messages)
        if window_messages is not None:
            built_messages.extend(window_messages)
            token_count = self._count_tokens(built_messages)
            return ContextBuildResult(
                messages=built_messages,
                token_count=token_count,
                strategy_used="sliding_window",
                truncated=True,
            )

        # Fallback: summarized context (should have been handled by Summarizer)
        # This is a last resort - just keep the last few messages
        minimal_messages = conversation_messages[-3:] if len(conversation_messages) > 3 else conversation_messages
        built_messages.extend(minimal_messages)
        token_count = self._count_tokens(built_messages)
        return ContextBuildResult(
            messages=built_messages,
            token_count=token_count,
            strategy_used="minimal_fallback",
            truncated=True,
        )

    def _sliding_window(
        self,
        conversation_messages: List[Message],
        history_budget: int,
        prefix_messages: List[Message],
    ) -> Optional[List[Message]]:
        """Try to fit a sliding window of recent messages."""
        # Start from the end and work backwards
        for window_size in range(len(conversation_messages), 0, -1):
            window = conversation_messages[-window_size:]
            test_messages = prefix_messages + window
            token_count = self._count_tokens(test_messages)
            if token_count <= history_budget:
                return window
        return None

    def _count_tokens(self, messages: List[Message]) -> int:
        """Count tokens using LLM client or estimation."""
        if self.llm_client:
            return self.llm_client.count_tokens(messages)
        return self._estimate_tokens(messages)

    def _estimate_tokens(self, messages: List[Message]) -> int:
        """Rough token estimation fallback."""
        total = 0
        for msg in messages:
            total += len(msg.content) // 4
            if msg.tool_calls:
                import json
                for tc in msg.tool_calls:
                    total += len(json.dumps(tc.arguments)) // 4
        return total

    def build_with_summary(
        self,
        messages: List[Message],
        summary: str,
        project_context: Optional[str] = None,
        system_prompt: Optional[str] = None,
    ) -> ContextBuildResult:
        """Build context when a summary is available from the Summarizer."""
        built_messages: List[Message] = []
        if system_prompt:
            built_messages.append(Message(role="system", content=system_prompt))

        if project_context:
            built_messages.append(
                Message(
                    role="system",
                    content=f"Project Context:\n{project_context}",
                    metadata={"type": "project_context"},
                )
            )

        # Add the summary as a system message
        built_messages.append(
            Message(
                role="system",
                content=f"Conversation Summary:\n{summary}",
                metadata={"type": "summary"},
            )
        )

        # Add recent messages after the summary point
        # Find the last summary marker or use last N messages
        conversation_messages = [m for m in messages if m.role != "system"]
        # For now, take last 10 messages after summary
        recent = conversation_messages[-10:] if len(conversation_messages) > 10 else conversation_messages
        built_messages.extend(recent)

        token_count = self._count_tokens(built_messages)
        return ContextBuildResult(
            messages=built_messages,
            token_count=token_count,
            strategy_used="summarized",
            truncated=True,
        )
