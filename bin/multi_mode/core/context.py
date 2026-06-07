"""Deterministic context building (no LLM calls)."""

from dataclasses import dataclass
from typing import List, Optional

from multi_mode.core.message import Message, MessageRole
from multi_mode.core.state import WorkflowState
from multi_mode.config.agent import AgentConfig
from multi_mode.utils.token_counter import count_tokens


@dataclass
class ContextWindow:
    messages: List[Message]
    token_count: int
    truncated: bool
    summary: Optional[str] = None


class ContextBuilder:
    """Builds context for the reasoner from workflow state.
    
    Pure deterministic logic - no LLM calls.
    """
    
    def __init__(self, config: AgentConfig):
        self.config = config
    
    def build(self, state: WorkflowState, project_context: str = "") -> ContextWindow:
        """Build context window for the reasoner."""
        messages = state.messages.copy()
        
        # Add system prompt if present
        if self.config.system_prompt:
            system_msg = Message(role=MessageRole.SYSTEM, content=self.config.system_prompt)
            messages.insert(0, system_msg)
        
        # Add project context if provided
        if project_context:
            context_msg = Message(role=MessageRole.SYSTEM, content=f"Project Context:\n{project_context}")
            insert_idx = 1 if self.config.system_prompt else 0
            messages.insert(insert_idx, context_msg)
        
        # Add summary if available (from previous summarization)
        if state.metadata.get("summary"):
            summary_msg = Message(role=MessageRole.SYSTEM, content=f"Conversation Summary:\n{state.metadata['summary']}")
            insert_idx = 1 if self.config.system_prompt else 0
            if project_context:
                insert_idx += 1
            messages.insert(insert_idx, summary_msg)
        
        # Calculate token count
        token_count = self._count_tokens(messages)
        
        # Truncate if needed
        truncated = False
        if token_count > self.config.token_budget:
            messages, token_count = self._truncate(messages)
            truncated = True
        
        return ContextWindow(
            messages=messages,
            token_count=token_count,
            truncated=truncated,
        )
    
    def _count_tokens(self, messages: List[Message]) -> int:
        """Count tokens for messages using the token counter utility."""
        total = 0
        for msg in messages:
            total += count_tokens(msg.content)
            for tc in msg.tool_calls:
                total += count_tokens(str(tc.arguments))
        return total
    
    def _truncate(self, messages: List[Message]) -> tuple[List[Message], int]:
        """Truncate messages to fit token budget using sliding window."""
        # Keep system messages and recent messages
        system_msgs = [m for m in messages if m.role == MessageRole.SYSTEM]
        other_msgs = [m for m in messages if m.role != MessageRole.SYSTEM]
        
        # Keep last N messages that fit
        budget = self.config.token_budget
        system_tokens = self._count_tokens(system_msgs)
        remaining = budget - system_tokens
        
        kept = []
        for msg in reversed(other_msgs):
            msg_tokens = self._count_tokens([msg])
            if msg_tokens <= remaining:
                kept.insert(0, msg)
                remaining -= msg_tokens
            else:
                break
        
        result = system_msgs + kept
        return result, self._count_tokens(result)


class SummarizationTrigger:
    """Determines when summarization should be triggered."""
    
    def __init__(self, config: AgentConfig):
        self.config = config
    
    def should_summarize(self, token_count: int) -> bool:
        if not self.config.enable_summarization:
            return False
        threshold = self.config.token_budget * self.config.summarization_threshold
        return token_count > threshold
