"""Main orchestrator - the single workflow loop."""

from __future__ import annotations

import threading
import queue
import sys
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from agent_core.config.agent import AgentConfig
from agent_core.config.models import ModelRole
from agent_core.core.message import Message, MessageRole, ToolCall
from agent_core.core.state import WorkflowState, TaskStatus
from agent_core.core.context import ContextBuilder, SummarizationTrigger
from agent_core.backends.base import LLMBackend
from agent_core.backends.factory import get_backend_for_config
from agent_core.agents.reasoner import Reasoner, ReasonerOutput
from agent_core.agents.executor import Executor
from agent_core.agents.summarizer import Summarizer
from agent_core.tools.registry import ToolRegistry
from agent_core.tools.builtin import register_builtin_tools
from agent_core.tools.executor import ToolExecutor


@dataclass
class WorkflowResult:
    """Result of a workflow execution."""
    success: bool
    final_answer: Optional[str] = None
    error: Optional[str] = None
    state: Optional[WorkflowState] = None
    trace: List[Dict[str, Any]] = field(default_factory=list)


class Orchestrator:
    """Main orchestrator for the agent workflow.

    Single loop: Reasoner -> Executor -> (repeat)
    With async Summarizer for context management.
    No Shaper LLM call - uses deterministic ContextBuilder.
    """

    def __init__(self, config: AgentConfig):
        self.config = config

        # Initialize tool registry
        self.tool_registry = ToolRegistry()
        register_builtin_tools(self.tool_registry)

        # Initialize backends
        reasoner_config = config.models.get(ModelRole.REASONER)
        if not reasoner_config:
            raise ValueError("Reasoner model not configured")
        self.reasoner_backend: LLMBackend = get_backend_for_config(reasoner_config)

        summarizer_config = config.models.get(ModelRole.SUMMARIZER)
        self.summarizer_backend: Optional[LLMBackend] = (
            get_backend_for_config(summarizer_config)
            if summarizer_config and config.enable_summarization
            else None
        )

        # Initialize context builder
        self.context_builder = ContextBuilder(config)

        # Initialize agents
        self.reasoner = Reasoner(
            config=config,
            backend=self.reasoner_backend,
            context_builder=self.context_builder,
            tool_registry=self.tool_registry,
        )
        self.executor = Executor(
            tool_executor=ToolExecutor(config, registry=self.tool_registry)
        )
        self.summarizer = (
            Summarizer(config, self.summarizer_backend)
            if self.summarizer_backend and config.enable_summarization
            else None
        )

        # Summarization trigger
        self.summarization_trigger = SummarizationTrigger(config)

        # Async summarization
        self._summary_queue: queue.Queue = queue.Queue()
        self._summary_thread: Optional[threading.Thread] = None
        self._pending_summary: Optional[str] = None
        self._summary_lock = threading.Lock()

    def run(self, task: str, project_context: str = "") -> WorkflowResult:
        """Run the workflow for a task."""
        state = WorkflowState.initial(task, self.config)

        # Start async summarizer thread if enabled
        if self.summarizer:
            self._start_summarizer_thread()

        try:
            for iteration in range(self.config.max_iterations):
                state.iteration = iteration

                # Apply any pending summary
                self._apply_pending_summary(state)

                # Check if summarization needed (trigger async)
                token_count = self._estimate_token_count(state)
                if self.summarization_trigger.should_summarize(token_count):
                    self._trigger_async_summarization(state, project_context)

                # Run reasoner
                reasoner_output = self.reasoner.run(state, project_context)

                # Handle reasoner output
                if reasoner_output.parse_errors:
                    state.add_trace("reasoner", output=f"Parse errors: {reasoner_output.parse_errors}")
                    # Retry with correction prompt
                    correction = self._build_correction_prompt(reasoner_output.parse_errors)
                    state.add_message(Message(role=MessageRole.USER, content=correction))
                    continue

                if reasoner_output.plan:
                    state.current_plan = reasoner_output.plan
                    state.add_trace("reasoner", output="Plan created")
                    # Continue loop to execute plan
                    continue

                if reasoner_output.tool_calls:
                    state.add_trace("reasoner", output=f"Tool calls: {[tc.name for tc in reasoner_output.tool_calls]}")
                    # Execute tools
                    state = self.executor.run(state, reasoner_output.tool_calls)
                    continue

                if reasoner_output.final_answer:
                    state.add_message(Message(role=MessageRole.ASSISTANT, content=reasoner_output.final_answer))
                    state.mark_completed()
                    state.add_trace("reasoner", output="Final answer provided")
                    break

                # No actionable output
                state.add_trace("reasoner", output="No actionable output")
                if reasoner_output.reasoning:
                    state.add_message(Message(role=MessageRole.ASSISTANT, content=reasoner_output.reasoning))
                else:
                    state.mark_failed("Reasoner produced no actionable output")
                    break

            if state.status == TaskStatus.IN_PROGRESS:
                state.mark_failed("Max iterations reached")

        finally:
            self._stop_summarizer_thread()

        return WorkflowResult(
            success=state.status == TaskStatus.COMPLETED,
            final_answer=self._extract_final_answer(state),
            error=state.metadata.get("error") if state.status == TaskStatus.FAILED else None,
            state=state,
            trace=state.get_trace(),
        )

    def _extract_final_answer(self, state: WorkflowState) -> Optional[str]:
        """Extract the final answer from the state."""
        for msg in reversed(state.messages):
            if msg.role == MessageRole.ASSISTANT and msg.content and not msg.tool_calls:
                return msg.content
        return None

    def _estimate_token_count(self, state: WorkflowState) -> int:
        """Estimate token count for the state."""
        from agent_core.utils.token_counter import count_tokens
        total = 0
        for msg in state.messages:
            total += count_tokens(msg.content)
            for tc in msg.tool_calls:
                total += count_tokens(str(tc.arguments))
        return total

    def _build_correction_prompt(self, errors: List[str]) -> str:
        """Build a correction prompt for parse errors."""
        return (
            "Your previous response had parsing errors:\n"
            + "\n".join(f"- {e}" for e in errors)
            + "\n\nPlease provide a valid response with tool calls or a final answer."
        )

    # Async summarization methods

    def _start_summarizer_thread(self) -> None:
        """Start the async summarizer thread."""
        def worker():
            while True:
                try:
                    item = self._summary_queue.get(timeout=1.0)
                    if item is None:
                        break
                    messages, project_ctx, callback = item
                    try:
                        summary = self.summarizer.summarize(messages, project_ctx)
                        callback(summary)
                    except Exception as e:
                        print(f"[summarizer] error: {e}", file=sys.stderr)
                        callback(None)
                except queue.Empty:
                    continue
                except Exception:
                    break

        self._summary_thread = threading.Thread(target=worker, daemon=True)
        self._summary_thread.start()

    def _stop_summarizer_thread(self) -> None:
        """Stop the async summarizer thread."""
        if self._summary_thread and self._summary_thread.is_alive():
            self._summary_queue.put(None)
            self._summary_thread.join(timeout=2.0)

    def _trigger_async_summarization(self, state: WorkflowState, project_context: str) -> None:
        """Trigger async summarization (non-blocking)."""
        if not self.summarizer:
            return

        with self._summary_lock:
            if self._pending_summary is not None:
                return

            messages_to_summarize = state.messages.copy()

            def on_complete(summary: Optional[str]):
                with self._summary_lock:
                    self._pending_summary = summary

            self._summary_queue.put((messages_to_summarize, project_context, on_complete))

    def _apply_pending_summary(self, state: WorkflowState) -> None:
        """Apply pending summary if available."""
        with self._summary_lock:
            if self._pending_summary is not None:
                summary = self._pending_summary
                self._pending_summary = None

                if summary:
                    state.metadata["summary"] = summary
                    # Replace messages with summary + recent messages
                    new_messages = []
                    if self.config.system_prompt:
                        new_messages.append(Message(role=MessageRole.SYSTEM, content=self.config.system_prompt))
                    new_messages.append(Message(role=MessageRole.SYSTEM, content=f"Conversation Summary:\n{summary}"))
                    # Keep last few messages for context
                    recent = state.messages[-3:] if len(state.messages) > 3 else state.messages
                    new_messages.extend(recent)
                    state.messages = new_messages
