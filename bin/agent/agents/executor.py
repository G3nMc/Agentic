"""Executor — runs tool calls, can also answer trivial requests directly.

The Executor has TWO modes:

  * ``run(state)`` — execute every tool call queued in ``state.tool_calls``
    via the shared :class:`ToolRegistry`, mirror the results back in
    ``state.tool_results``, then clear ``tool_calls`` so the dispatcher
    knows to bounce back to the Reasoner.
  * ``run_no_tools(state)`` — short-circuit path for the Router's
    ``trivial`` route. Generates a plain-text answer with the cheapest
    backend and skips the Reasoner entirely.
"""

from __future__ import annotations

import concurrent.futures

import json
import sys
from typing import Any, Dict, Optional

from ..core.state import WorkflowState
from .base import Agent, _truncate

_EXECUTOR_SYSTEM_PROMPT = (
    "You are a concise conversational assistant. The user is making small "
    "talk or asking a trivial question. Reply in ONE short sentence. Plain "
    "text, no markdown, no tools."
)


class ExecutorAgent(Agent):
    name = "executor"

    def __init__(
        self,
        backend,
        *,
        system_prompt: Optional[str] = None,
        temperature: float = 0.4,
        max_tokens: int = 512,
        iteration_timeout: float = 30.0,
    ):
        super().__init__(
            backend,
            system_prompt or _EXECUTOR_SYSTEM_PROMPT,
            temperature=temperature,
            max_tokens=max_tokens,
        )
        # Set by the dispatcher right after construction. Kept as an
        # attribute (not a constructor arg) so the agents-only build step
        # can run before the ToolRegistry exists.
        self.tool_registry = None
        self.iteration_timeout = iteration_timeout

    # ------------------------------------------------------------------
    # Tool-execution path
    # ------------------------------------------------------------------
    def run(self, state: WorkflowState) -> WorkflowState:
        if self.tool_registry is None:
            state.add_trace(
                self.name,
                output="(no tool registry)",
                detail="Executor.run() called before tool_registry was attached.",
            )
            return state
        if not state.tool_calls:
            state.add_trace(self.name, output="(no tool calls)")
            return state

        # Log input to stderr
        tool_calls_str = " ".join(
            [f"{c.get('tool')} {c.get('parameters')}" for c in state.tool_calls]
        )
        print(
            f"[agent:{self.name}→{self.model_id}] Tool calls: {_truncate(tool_calls_str)}",
            file=sys.stderr,
            flush=True,
        )

        results: list[dict] = []
        previews: list[str] = []

        def _exec(call):
            tool = call.get("tool", "")
            params = call.get("parameters") or {}
            try:
                # Get tool-specific timeout if configured, otherwise use default
                tool_timeout = getattr(self.tool_registry, "tool_timeouts", {}).get(
                    tool, 30.0
                )
                # Execute tool with timeout
                future = concurrent.futures.ThreadPoolExecutor().submit(
                    self.tool_registry.execute, tool, params
                )
                raw = future.result(timeout=tool_timeout)
            except concurrent.futures.TimeoutError:
                raw = json.dumps(
                    {
                        "status": "error",
                        "message": f"Tool '{tool}' exceeded timeout of {tool_timeout} seconds",
                    }
                )
            except Exception as e:  # noqa: BLE001
                raw = json.dumps({"status": "error", "message": str(e)})
            return {"tool": tool, "parameters": params, "result": raw}

        # Use ThreadPoolExecutor with timeout handling
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            # Submit all tool calls
            futures = [pool.submit(_exec, call) for call in state.tool_calls]

            # Collect results with timeout
            results = []
            try:
                for future in concurrent.futures.as_completed(
                    futures, timeout=self.iteration_timeout
                ):
                    try:
                        results.append(future.result())
                    except concurrent.futures.TimeoutError:
                        results.append(
                            {
                                "tool": "unknown",
                                "parameters": {},
                                "result": json.dumps(
                                    {
                                        "status": "error",
                                        "message": f"Tool execution exceeded iteration timeout of {self.iteration_timeout} seconds",
                                    }
                                ),
                            }
                        )
            except concurrent.futures.TimeoutError:
                # Handle case where overall collection times out
                results.append(
                    {
                        "tool": "executor",
                        "parameters": {},
                        "result": json.dumps(
                            {
                                "status": "error",
                                "message": f"Overall tool execution exceeded iteration timeout of {self.iteration_timeout} seconds",
                            }
                        ),
                    }
                )

        for r in results:
            previews.append(self._preview(r["tool"], r["result"]))

        # Accumulate across iterations so the Reasoner sees the full history
        # of what it tried this turn — critical for weak/non-tool-tuned models
        # that would otherwise re-issue the same broken call indefinitely.
        if state.tool_results:
            state.tool_results = [*state.tool_results, *results]
        else:
            state.tool_results = results
        state.tool_calls = []  # consumed — dispatcher will hand back to Reasoner.
        state.add_trace(
            self.name,
            output=" | ".join(previews)[:200],
            detail=json.dumps(results, indent=2),
        )

        # Log output to stderr
        print(
            f"[agent:{self.name}←{self.model_id}] Tool results: {_truncate(' | '.join(previews))}",
            file=sys.stderr,
            flush=True,
        )

        return state

    # ------------------------------------------------------------------
    # Trivial direct-answer path (parallelized)
    # ------------------------------------------------------------------
    def run_no_tools(self, state: WorkflowState) -> WorkflowState:
        try:
            messages = self._build_messages(state.user_input, history=state.history)
            text, _ = self._chat(messages)
        except Exception as e:  # noqa: BLE001
            print(f"[executor] direct-answer failed: {e}", file=sys.stderr)
            state.final_answer = f"Sorry, I couldn't answer that: {e}"
            state.add_trace(self.name, output="(error)", detail=str(e))
            return state

        answer = (text or "").strip() or "OK."
        state.final_answer = answer
        state.add_trace(self.name, output=answer[:160], detail=answer)
        return state

    # ------------------------------------------------------------------
    @staticmethod
    def _preview(tool: str, raw: str) -> str:
        """Compact one-line summary of a tool result for the trace tile."""
        try:
            obj = json.loads(raw)
        except Exception:  # noqa: BLE001
            return f"{tool}: {raw[:60]}"
        status = obj.get("status", "?")
        return f"{tool}: {status}"
