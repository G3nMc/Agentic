"""Reasoner Agent - The brain of the workflow.

Handles planning, tool calling, and final answer synthesis.
Uses deterministic context building and structured output parsing."""

from __future__ import annotations

import time
import uuid
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

from .config import AgentConfig
from .state import Message, ToolCall, ToolResult, WorkflowState, TaskStatus
from .llm_client import LLMClient, LLMResponse, create_client
from .context_builder import ContextBuilder, ContextBuildResult
from .output_parser import OutputParser, ParsedOutput, create_output_parser


@dataclass
class ReasonerOutput:
    """Output from a Reasoner run."""
    tool_calls: Optional[List[ToolCall]] = None
    final_answer: Optional[str] = None
    plan: Optional[Dict[str, Any]] = None
    raw_response: Optional[LLMResponse] = None
    context_result: Optional[ContextBuildResult] = None
    parse_errors: List[str] = None

    def __post_init__(self):
        if self.parse_errors is None:
            self.parse_errors = []

    @property
    def has_action(self) -> bool:
        return bool(self.tool_calls or self.final_answer or self.plan)


class Reasoner:
    """The Reasoner agent - handles planning, execution, and synthesis."""

    def __init__(
        self,
        config: AgentConfig,
        llm_client: Optional[LLMClient] = None,
        context_builder: Optional[ContextBuilder] = None,
        output_parser: Optional[OutputParser] = None,
    ):
        self.config = config
        self.llm_client = llm_client or create_client(
            self._provider_from_model(config.model_reasoner),
            model=config.model_reasoner,
        )
        self.context_builder = context_builder or ContextBuilder(config, self.llm_client)
        self.output_parser = output_parser or create_output_parser(config.max_retries)
        self._tools_schema: List[Dict[str, Any]] = []

    def _provider_from_model(self, model: str) -> str:
        """Infer provider from model name."""
        model_lower = model.lower()
        if model_lower.startswith(('gpt-', 'o1-', 'o3-')):
            return 'openai'
        elif model_lower.startswith(('claude-', 'claude3')):
            return 'anthropic'
        elif model_lower.startswith('gemini'):
            return 'gemini'
        else:
            return 'ollama'

    def set_tools_schema(self, tools_schema: List[Dict[str, Any]]) -> None:
        """Set the available tools schema for function calling."""
        self._tools_schema = tools_schema

    def run(self, state: WorkflowState, project_context: Optional[str] = None) -> ReasonerOutput:
        """Run the Reasoner for one iteration.

        Args:
            state: Current workflow state.
            project_context: Optional project context.

        Returns:
            ReasonerOutput with tool_calls, final_answer, or plan.
        """
        # Determine mode based on state
        mode = self._determine_mode(state)
        system_prompt = self._get_system_prompt(mode)

        # Build context
        context_result = self.context_builder.build(
            messages=state.messages,
            project_context=project_context,
            system_prompt=system_prompt,
        )

        # Call LLM
        response = self._call_llm_with_retry(context_result.messages, mode)

        # Parse output
        parsed = self.output_parser.parse(response, self._tools_schema)

        # Handle parse errors with retry
        retry_count = 0
        while parsed.parse_errors and retry_count < self.config.max_retries:
            correction_prompt = self.output_parser.create_correction_prompt(
                parsed.parse_errors, parsed.raw_content
            )
            # Add correction as user message and retry
            retry_messages = context_result.messages + [
                Message(role="user", content=correction_prompt)
            ]
            response = self.llm_client.complete(retry_messages, self._tools_schema)
            parsed = self.output_parser.parse(response, self._tools_schema)
            retry_count += 1

        return ReasonerOutput(
            tool_calls=parsed.tool_calls,
            final_answer=parsed.final_answer,
            plan=parsed.plan,
            raw_response=response,
            context_result=context_result,
            parse_errors=parsed.parse_errors,
        )

    def _determine_mode(self, state: WorkflowState) -> str:
        """Determine the Reasoner mode based on state."""
        if state.iteration == 0:
            return "planning"
        elif state.status == TaskStatus.COMPLETED:
            return "final"
        elif state.plan and not self._plan_complete(state.plan):
            return "execution"
        else:
            return "execution"

    def _plan_complete(self, plan: Dict[str, Any]) -> bool:
        """Check if the plan is complete."""
        steps = plan.get("steps", [])
        if not steps:
            return True
        return all(step.get("status") == "completed" for step in steps)

    def _get_system_prompt(self, mode: str) -> str:
        """Get the system prompt for the given mode."""
        base_prompt = """You are an expert software engineer and problem solver.
You work in a loop: Reason -> Act -> Observe -> Reason.

Available tools will be provided. Use them to accomplish the task.

Output format: You MUST respond with valid JSON only. Use one of these formats:

1. For tool calls:
{
  "tool_calls": [
    {"id": "call_1", "name": "tool_name", "arguments": {"arg": "value"}}
  ]
}

2. For final answer:
{
  "final_answer": "Your complete answer here"
}

3. For plan (first turn only):
{
  "plan": {
    "goal": "High-level goal",
    "steps": [
      {"id": "1", "description": "Step description", "status": "pending"}
    ],
    "current_step": 0
  }
}

Do not include any text outside the JSON."""

        if mode == "planning":
            return base_prompt + """

MODE: PLANNING
This is the first turn. Analyze the task and create a structured plan.
Break down the task into clear, actionable steps.
Each step should be specific enough to execute with available tools.
Output ONLY the plan JSON format."""
        elif mode == "execution":
            return base_prompt + """

MODE: EXECUTION
You are in the middle of executing a plan. 
- If the previous tool results show progress, continue to the next step.
- If there are errors, decide whether to retry, use a different approach, or ask for clarification.
- If all plan steps are complete, provide the final answer.
Output tool_calls JSON or final_answer JSON."""
        elif mode == "final":
            return base_prompt + """

MODE: FINAL
All work is complete. Synthesize a comprehensive final answer.
Output ONLY the final_answer JSON format."""
        return base_prompt

    def _call_llm_with_retry(self, messages: List[Message], mode: str) -> LLMResponse:
        """Call LLM with retry logic."""
        last_error = None
        for attempt in range(self.config.max_retries + 1):
            try:
                return self.llm_client.complete(
                    messages=messages,
                    tools=self._tools_schema if self._tools_schema else None,
                    config={"model": self.config.model_reasoner},
                )
            except Exception as e:
                last_error = e
                if attempt < self.config.max_retries:
                    time.sleep(self.config.retry_backoff_base * (2 ** attempt))
                else:
                    break
        raise last_error

    def run_planning(self, task: str, project_context: Optional[str] = None) -> ReasonerOutput:
        """Run initial planning for a new task."""
        # Create initial state with just the user task
        state = WorkflowState()
        state.add_message(Message(role="user", content=task))
        state.status = TaskStatus.IN_PROGRESS
        return self.run(state, project_context)

    def run_execution(self, state: WorkflowState, project_context: Optional[str] = None) -> ReasonerOutput:
        """Run execution mode with existing state."""
        return self.run(state, project_context)

    def run_final(self, state: WorkflowState, project_context: Optional[str] = None) -> ReasonerOutput:
        """Run final synthesis mode."""
        state.status = TaskStatus.COMPLETED
        return self.run(state, project_context)


def create_reasoner(config: AgentConfig, tools_schema: List[Dict[str, Any]] = None) -> Reasoner:
    """Factory function to create a Reasoner."""
    reasoner = Reasoner(config)
    if tools_schema:
        reasoner.set_tools_schema(tools_schema)
    return reasoner