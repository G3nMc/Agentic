"""Agent configuration system."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class AgentConfig:
    """Configuration for the agent workflow.

    Attributes:
        model_reasoner: Model identifier for the Reasoner agent.
        model_summarizer: Model identifier for the Summarizer agent.
        max_iterations: Maximum number of Reasoner-Executor cycles.
        token_budget: Maximum tokens allowed in the context before summarization.
        summarization_threshold: Fraction of token_budget that triggers summarization.
        tool_timeout_seconds: Default timeout for tool execution.
        parallel_tool_execution: Whether to execute independent tool calls in parallel.
        max_retries: Maximum retries for LLM calls on transient errors.
        retry_backoff_base: Base seconds for exponential backoff.
    """

    model_reasoner: str = field(
        default_factory=lambda: os.environ.get(
            "AGENT_MODEL_REASONER", "gpt-4o"
        )
    )
    model_summarizer: str = field(
        default_factory=lambda: os.environ.get(
            "AGENT_MODEL_SUMMARIZER", "gpt-4o-mini"
        )
    )
    max_iterations: int = field(
        default_factory=lambda: int(os.environ.get("AGENT_MAX_ITERATIONS", "50"))
    )
    token_budget: int = field(
        default_factory=lambda: int(os.environ.get("AGENT_TOKEN_BUDGET", "128000"))
    )
    summarization_threshold: float = field(
        default_factory=lambda: float(
            os.environ.get("AGENT_SUMMARIZATION_THRESHOLD", "0.7")
        )
    )
    tool_timeout_seconds: int = field(
        default_factory=lambda: int(
            os.environ.get("AGENT_TOOL_TIMEOUT", "30")
        )
    )
    parallel_tool_execution: bool = field(
        default_factory=lambda: os.environ.get(
            "AGENT_PARALLEL_TOOLS", "true"
        ).lower() == "true"
    )
    max_retries: int = field(
        default_factory=lambda: int(os.environ.get("AGENT_MAX_RETRIES", "3"))
    )
    retry_backoff_base: float = field(
        default_factory=lambda: float(
            os.environ.get("AGENT_RETRY_BACKOFF", "1.0")
        )
    )

    def __post_init__(self) -> None:
        """Validate configuration values."""
        if self.max_iterations < 1:
            raise ValueError("max_iterations must be >= 1")
        if self.token_budget < 1000:
            raise ValueError("token_budget must be >= 1000")
        if not 0 < self.summarization_threshold <= 1:
            raise ValueError("summarization_threshold must be in (0, 1]")
        if self.tool_timeout_seconds < 1:
            raise ValueError("tool_timeout_seconds must be >= 1")
        if self.max_retries < 0:
            raise ValueError("max_retries must be >= 0")
        if self.retry_backoff_base <= 0:
            raise ValueError("retry_backoff_base must be > 0")
