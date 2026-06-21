"""Reasoner agent - the brain of the workflow."""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from ..core.message import ToolCall, Message, MessageRole
from ..config.agent import AgentConfig
from ..config.models import ModelRole, ModelConfig
from ..core.state import WorkflowState, TaskStatus
from ..backends.base import LLMBackend, CompletionResponse
from ..core.context import ContextBuilder
from ..tools.registry import ToolRegistry


@dataclass
class ReasonerOutput:
    """Output from a Reasoner run."""
    tool_calls: List[ToolCall] = field(default_factory=list)
    final_answer: Optional[str] = None
    plan: Optional[Dict[str, Any]] = None
    reasoning: Optional[str] = None
    parse_errors: List[str] = field(default_factory=list)

    @property
    def has_action(self) -> bool:
        return bool(self.tool_calls or self.final_answer or self.plan)


def _determine_mode(state: WorkflowState) -> str:
    """Determine the Reasoner mode based on state."""
    if state.iteration == 0:
        return "planning"
    elif state.status == TaskStatus.COMPLETED:
        return "final"
    else:
        return "execution"


def _get_system_prompt(mode: str) -> str:
    """Get the system prompt for the given mode."""
    base = (
        "You are an expert software engineer and problem solver.\n"
        "You work in a loop: Reason -> Act -> Observe -> Reason.\n"
        "Use the available tools to accomplish the task.\n"
        "When you have enough information, provide a final answer.\n"
    )
    if mode == "planning":
        return base + (
            "\nMODE: PLANNING\n"
            "This is the first turn. Analyze the task and create a structured plan.\n"
            "Break down the task into clear, actionable steps.\n"
            "Output a plan as a JSON object with 'goal' and 'steps' (each step has 'id', 'description', 'status': 'pending').\n"
            "Then immediately start executing the first step by calling the necessary tools.\n"
        )
    elif mode == "execution":
        return base + (
            "\nMODE: EXECUTION\n"
            "Continue executing the plan. Call tools as needed.\n"
            "When all steps are complete, provide the final answer.\n"
        )
    else:
        return base + (
            "\nMODE: FINAL\n"
            "All work is complete. Synthesize a comprehensive final answer.\n"
        )


def _parse_response(response: CompletionResponse) -> ReasonerOutput:
    """Parse the LLM response into ReasonerOutput."""
    # Check for native tool calls
    if response.tool_calls:
        tool_calls = [
            ToolCall(
                id=tc.get("id", str(uuid.uuid4())),
                name=tc["name"],
                arguments=tc.get("arguments", {}),
            )
            for tc in response.tool_calls
        ]
        return ReasonerOutput(tool_calls=tool_calls, reasoning=response.content)

    # Check for final answer
    if response.content:
        # Try to parse as JSON (plan or final answer)
        import json
        content = response.content.strip()
        try:
            data = json.loads(content)
            if isinstance(data, dict):
                # Plan: either wrapped in "plan" key or direct with "goal" and "steps"
                if "plan" in data:
                    return ReasonerOutput(plan=data["plan"], reasoning=content)
                if "goal" in data and "steps" in data:
                    return ReasonerOutput(plan=data, reasoning=content)
                if "final_answer" in data:
                    return ReasonerOutput(final_answer=data["final_answer"], reasoning=content)
                if "tool_calls" in data:
                    tool_calls = [
                        ToolCall(
                            id=tc.get("id", str(uuid.uuid4())),
                            name=tc["name"],
                            arguments=tc.get("arguments", {}),
                        )
                        for tc in data["tool_calls"]
                    ]
                    return ReasonerOutput(tool_calls=tool_calls, reasoning=content)
        except json.JSONDecodeError:
            pass

        # Treat as final answer
        return ReasonerOutput(final_answer=content, reasoning=content)

    # No content and no tool calls - error
    return ReasonerOutput(parse_errors=["Empty response from LLM"])


class Reasoner:
    """The Reasoner agent - handles planning, execution, and synthesis."""

    def __init__(
            self,
            config: AgentConfig,
            backend: LLMBackend,
            context_builder: ContextBuilder,
            tool_registry: ToolRegistry,
    ):
        self.config = config
        self.backend = backend
        self.context_builder = context_builder
        self.tool_registry = tool_registry
        self._tools_schema: List[Dict[str, Any]] = []
        self._build_tools_schema()

    def _build_tools_schema(self) -> None:
        """Build the tools schema in the format expected by the backend."""
        format_type = self.backend.get_tool_format() if hasattr(self.backend, 'get_tool_format') else "openai"
        self._tools_schema = self.tool_registry.get_tool_schemas_for_llm(format_type)

    def run(self, state: WorkflowState, project_context: str = "") -> ReasonerOutput:
        """Run the Reasoner for one iteration."""
        mode = _determine_mode(state)
        system_prompt = _get_system_prompt(mode)

        # Build context
        context = self.context_builder.build(state, project_context)
        if system_prompt:
            # Prepend system prompt if not already present
            if not context.messages or context.messages[0].role != MessageRole.SYSTEM:
                context.messages.insert(0, Message(role=MessageRole.SYSTEM, content=system_prompt))

        # Convert messages to dicts for the backend
        messages_dicts = [msg.to_dict() for msg in context.messages]

        # Call LLM with retry
        response = self._call_llm_with_retry(messages_dicts)

        # Parse response
        return _parse_response(response)

    def _call_llm_with_retry(self, messages: List[Dict[str, Any]]) -> CompletionResponse:
        """Call LLM with retry logic."""
        last_error = None
        reasoner_cfg = self.config.models.get(ModelRole.REASONER)
        reasoning_level = getattr(reasoner_cfg, 'reasoning_level', None) if reasoner_cfg else None
        thinking = getattr(reasoner_cfg, 'thinking', True) if reasoner_cfg else True
        effort = getattr(reasoner_cfg, 'effort', None) if reasoner_cfg else None
        for attempt in range(self.config.max_retries + 1):
            try:
                kwargs: Dict[str, Any] = {
                    "temperature": 0.2,
                    "max_tokens": self.config.models.get(ModelRole.REASONER,
                                                      ModelConfig(role=ModelRole.REASONER, provider="openai", model="gpt-4o")).max_tokens,
                }
                # Only pass reasoning params when thinking is ON (master switch).
                if thinking and reasoning_level is not None:
                    kwargs["reasoning_level"] = reasoning_level
                if thinking and effort is not None:
                    kwargs["effort"] = effort
                kwargs["thinking"] = thinking
                return self.backend.complete(
                    messages,
                    tools=self._tools_schema,
                    **kwargs,
                )
            except Exception as e:
                last_error = e
                if attempt < self.config.max_retries:
                    import time
                    time.sleep(self.config.retry_backoff_base * (2 ** attempt))
        raise last_error
