"""Main agent loop - orchestrates reasoner, tools, and summarization."""

from typing import List, Optional
import threading
import queue

from agent_core.core.config import AgentConfig
from agent_core.core.state import WorkflowState, TaskStatus
from agent_core.core.message import Message, MessageRole
from agent_core.core.context import ContextBuilder, SummarizationTrigger
from agent_core.core.loop import ReasonerOutput
from agent_core.agents.reasoner import Reasoner
from agent_core.agents.summarizer import Summarizer
from agent_core.tools.executor import ToolExecutor


class AgentLoop:
    """Main agent loop orchestrating reasoner, tools, and summarization."""
    
    def __init__(self, config: AgentConfig):
        self.config = config
        self.reasoner = Reasoner(config)
        self.tool_executor = ToolExecutor(config)
        self.context_builder = ContextBuilder(config)
        self.summarization_trigger = SummarizationTrigger(config)
        
        if config.enable_summarization and config.models.get("summarizer"):
            self.summarizer = Summarizer(config)
        else:
            self.summarizer = None
        
        # Async summarization queue
        self._summary_queue = queue.Queue()
        self._summary_thread = None
        self._pending_summary = None
        self._summary_lock = threading.Lock()
    
    def run(self, task: str, project_context: str = "") -> WorkflowState:
        """Run the agent loop for a task."""
        state = WorkflowState.initial(task, self.config)
        
        # Start async summarizer thread if enabled
        if self.summarizer:
            self._start_summarizer_thread(state, project_context)
        
        try:
            for iteration in range(self.config.max_iterations):
                state.iteration = iteration
                
                # Build context (deterministic)
                context = self.context_builder.build(state, project_context)
                
                # Check if we have a pending summary to apply
                self._apply_pending_summary(state)
                
                # Check if summarization needed (trigger async)
                if self.summarization_trigger.should_summarize(context.token_count):
                    self._trigger_async_summarization(state, project_context)
                
                # Get reasoner output
                reasoner_output = self.reasoner.run(context.messages, self.config)
                
                # Handle reasoner output
                if reasoner_output.final_answer:
                    state.add_message(Message(role=MessageRole.ASSISTANT, content=reasoner_output.final_answer))
                    state.mark_completed()
                    break
                
                if reasoner_output.plan:
                    state.current_plan = reasoner_output.plan
                    state.add_message(Message(role=MessageRole.ASSISTANT, content=reasoner_output.plan))
                    continue
                
                if reasoner_output.tool_calls:
                    # Execute tools
                    tool_results = self.tool_executor.execute_batch(reasoner_output.tool_calls)
                    
                    # Add tool calls to state
                    from agent_core.core.message import ToolCall
                    for tc in reasoner_output.tool_calls:
                        state.add_tool_call(ToolCall(
                            id=tc.get("id", ""),
                            name=tc.get("name", ""),
                            arguments=tc.get("arguments", {}),
                        ))
                    
                    # Add tool results as messages
                    for result in tool_results:
                        state.add_tool_result(result)
                        msg = Message(
                            role=MessageRole.TOOL,
                            content=result.content,
                            tool_call_id=result.tool_call_id,
                            metadata={"error": result.error, "tool_name": result.name} if result.error else {"tool_name": result.name}
                        )
                        state.add_message(msg)
                    
                    state.clear_pending_tools()
                    continue
                
                # No action from reasoner
                state.add_message(Message(role=MessageRole.ASSISTANT, content=reasoner_output.reasoning or "No action taken"))
            
            if state.status == TaskStatus.IN_PROGRESS:
                state.mark_failed("Max iterations reached")
        
        finally:
            # Stop summarizer thread
            self._stop_summarizer_thread()
        
        return state
    
    def _start_summarizer_thread(self, state: WorkflowState, project_context: str):
        """Start the async summarizer thread."""
        def summarizer_worker():
            while True:
                try:
                    item = self._summary_queue.get(timeout=1.0)
                    if item is None:  # Shutdown signal
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
        
        import sys
        self._summary_thread = threading.Thread(target=summarizer_worker, daemon=True)
        self._summary_thread.start()
    
    def _stop_summarizer_thread(self):
        """Stop the async summarizer thread."""
        if self._summary_thread and self._summary_thread.is_alive():
            self._summary_queue.put(None)
            self._summary_thread.join(timeout=2.0)
    
    def _trigger_async_summarization(self, state: WorkflowState, project_context: str):
        """Trigger async summarization (non-blocking)."""
        if not self.summarizer:
            return
        
        # Don't trigger if already pending
        with self._summary_lock:
            if self._pending_summary is not None:
                return
            
            # Capture current messages for summarization
            messages_to_summarize = state.messages.copy()
            
            def on_summary_complete(summary: Optional[str]):
                with self._summary_lock:
                    self._pending_summary = summary
            
            self._summary_queue.put((messages_to_summarize, project_context, on_summary_complete))
    
    def _apply_pending_summary(self, state: WorkflowState):
        """Apply pending summary if available."""
        with self._summary_lock:
            if self._pending_summary is not None:
                summary = self._pending_summary
                self._pending_summary = None
                
                if summary:
                    # Store summary in state metadata
                    state.metadata["summary"] = summary
                    
                    # Replace messages with summary + recent messages
                    new_messages = []
                    if self.config.system_prompt:
                        new_messages.append(Message(role=MessageRole.SYSTEM, content=self.config.system_prompt))
                    if project_context:
                        new_messages.append(Message(role=MessageRole.SYSTEM, content=f"Project Context:\n{project_context}"))
                    new_messages.append(Message(role=MessageRole.SYSTEM, content=f"Conversation Summary:\n{summary}"))
                    
                    # Keep last few messages for context
                    recent_messages = state.messages[-3:] if len(state.messages) > 3 else state.messages
                    new_messages.extend(recent_messages)
                    
                    state.messages = new_messages
