"""Reasoner — the brain that produces a plan, optional tool intents, or final answer.

This is the only role that should run on a strong model. It receives the
shaped prompt (or the raw input for trivial routes) plus tool-result
snippets pushed back by the Executor, and emits one of:

  * a final answer (plain text),
  * one or more tool calls in ``<tool>{...}</tool>`` form (handed to the
    Executor by the dispatcher).

The tool-call grammar is identical to the single-agent loop's so the
existing :mod:`agent.loop.tool_dispatch` parser keeps working unchanged.
"""
from __future__ import annotations

import json
import sys
from typing import Any, Dict, List, Optional

from ..core.state import WorkflowState
from ..loop import tool_dispatch as _td
from .base import Agent


_REASONER_SYSTEM_PROMPT_BASE = (
    "You are a reasoning agent in a multi-agent workflow. Another agent has "
    "already shaped the user's request into a Goal/Constraints/Success-criteria "
    "spec. Your job:\n"
    "  1. Read the spec and any tool results already gathered.\n"
    "  2. If you need data from the user's filesystem, emit ONE tool call "
    "     using exactly this format on a single line:\n"
    '       <tool>{"tool":"NAME","parameters":{...}}</tool>\n'
    "     No preamble, no explanation — just the tag. The Executor will run "
    "     it and feed the result back.\n"
    "  3. When you have enough information, write the final answer in plain "
    "     text. No <tool> tags in a final answer.\n"
    "\n"
    "WHEN TO USE TOOLS vs YOUR OWN KNOWLEDGE:\n"
    "  - Use tools when the answer depends on THIS project's contents — "
    "    file paths, code, configs, git state, build output, test results.\n"
    "  - Do NOT use tools for general knowledge questions: explanations of "
    "    public protocols/standards (MCP, OAuth, HTTP, gRPC, JSON-RPC, REST), "
    "    third-party libraries/APIs, programming concepts, definitions, "
    "    tutorials, comparisons, or 'how does X work' questions about "
    "    technology that exists outside the user's filesystem. Answer those "
    "    directly from what you know.\n"
    "  - In particular: do NOT grep the project for terms like 'mcp', "
    "    'oauth', 'http', 'graphql', 'kubernetes', etc. unless the user "
    "    explicitly asked about THIS project's implementation of them. "
    "    Searches against generated artifacts (installers, binaries, asset "
    "    bundles) return junk that pollutes context.\n"
    "  - If a question mixes both ('explain MCP and check if we use it'), "
    "    answer the general part from knowledge first, then make ONE narrow "
    "    tool call (e.g. read pubspec.yaml) — never a broad repo grep.\n"
    "  - Do NOT trigger tools for casual mentions of the word 'tool' or "
    "    discussions about tools. Only invoke tools when there is a clear "
    "    and explicit request to perform an action.\n"
    "\n"
    "Available tools are listed at the end of this prompt. Keep tool-call JSON "
    "valid; prefer single quotes inside shell commands. Paths are relative to "
    "the project root."
)


class ReasonerAgent(Agent):
    name = "reasoner"

    def __init__(self, backend, *,
                 system_prompt: Optional[str] = None,
                 tool_definitions: Optional[List[Dict[str, Any]]] = None,
                 tools_catalog_text: str = "",
                 temperature: float = 0.2,
                 max_tokens: int = 4096):
        prompt = system_prompt or _REASONER_SYSTEM_PROMPT_BASE
        if tools_catalog_text:
            prompt = prompt + "\n\n" + tools_catalog_text
        super().__init__(backend, prompt,
                         temperature=temperature,
                         max_tokens=max_tokens)
        # The Reasoner sends the tool catalog to the model as `tools=` so
        # backends with native tool calling (Gemini, Groq) can use it.
        # Backends that ignore the kwarg fall back to the prompt-embedded
        # catalog above.
        self.tool_definitions = list(tool_definitions or [])

    # ------------------------------------------------------------------
    def run(self, state: WorkflowState) -> WorkflowState:
        user_block = self._compose_user_block(state)
        messages = self._build_messages(user_block, history=state.history)

        try:
            text, finish_reason = self._chat(
                messages,
                tools=self.tool_definitions or None,
            )
        except Exception as e:  # noqa: BLE001
            print(f"[reasoner] backend error: {e}", file=sys.stderr)
            state.final_answer = f"Reasoner error: {e}"
            state.add_trace(self.name, output="(error)", detail=str(e))
            return state

        text_clean = _td.clean_history_text(text or "")

        # Tool intents → hand off to the Executor.
        tag_calls = _td.parse_all_tag_tool_calls(
            text_clean, self.tool_definitions
        )
        if tag_calls:
            state.tool_calls = [
                {"tool": name, "parameters": params}
                for name, params in tag_calls
            ]
            preview = ", ".join(c["tool"] for c in state.tool_calls)
            state.add_trace(self.name,
                            output=f"plan tool: {preview}",
                            detail=text_clean)
            # Tools requested → not a final answer yet.
            state.plan = state.plan or text_clean
            state.final_answer = None
            return state

        # No tools → treat as final answer.
        final = _td.clean_final_answer(text or "")
        state.final_answer = final
        state.plan = state.plan or text_clean
        first_line = next((l for l in final.splitlines() if l.strip()), final)
        state.add_trace(self.name,
                        output=first_line[:160] or "(empty answer)",
                        detail=final)
        return state

    # ------------------------------------------------------------------
    # Number of MOST RECENT tool results to include with full bodies.
    # Older results become one-liners (tool(params) -> status) — keeps
    # the model aware they happened without re-sending the bodies on
    # every iteration. Without this, a long tool loop linearly grows the
    # prompt every iteration and a local model's wall-clock per-iteration
    # cost balloons (~410s by iter 23 in observed runs).
    _KEEP_FULL_RESULTS = 5
    # Hard char cap on the full-bodied section. Even if _KEEP_FULL_RESULTS
    # are the last 5, if their combined body exceeds this we still drop
    # the older ones to one-liners. ~80K chars ≈ 26K tokens at the code
    # multiplier — comfortable headroom inside any 128K window.
    _MAX_FULL_RESULTS_CHARS = 80_000

    def _compose_user_block(self, state: WorkflowState) -> str:
        """Build the user-side message: shaped prompt + any tool results so far.

        Tool results are truncated newest-first: only the last
        ``_KEEP_FULL_RESULTS`` (and at most ``_MAX_FULL_RESULTS_CHARS``)
        are inlined with full bodies. Older results are folded to a
        single ``tool(params) -> status`` line so the per-iteration
        prompt size doesn't grow without bound.
        """
        parts: List[str] = []
        if state.shaped_prompt:
            parts.append(f"[Spec]\n{state.shaped_prompt}")
        else:
            parts.append(state.user_input)

        results = list(state.tool_results or [])
        if results:
            n = len(results)
            # Decide which indices get full bodies (newest-first within
            # the recent window AND a char budget). Older ones get a
            # one-liner.
            keep_full_indices: set[int] = set()
            budget = self._MAX_FULL_RESULTS_CHARS
            for i in range(n - 1, max(-1, n - 1 - self._KEEP_FULL_RESULTS), -1):
                body_len = len(str(results[i].get("result", "")))
                if budget - body_len < 0 and keep_full_indices:
                    break
                keep_full_indices.add(i)
                budget -= body_len

            parts.append("\n[Tool calls + results so far this turn]")
            for i, r in enumerate(results):
                tool = r.get("tool", "?")
                params = r.get("parameters") or {}
                try:
                    params_str = json.dumps(params, ensure_ascii=False)
                except Exception:  # noqa: BLE001
                    params_str = str(params)
                if i in keep_full_indices:
                    result = r.get("result", "")
                    parts.append(f"{i + 1}. {tool}({params_str}) -> {result}")
                else:
                    # Older — extract status only. The full body was
                    # available to the reasoner on the iteration it
                    # arrived; if it needed to be remembered it should
                    # have been used by now.
                    raw = r.get("result", "")
                    status = "?"
                    if isinstance(raw, dict):
                        status = str(raw.get("status", "?"))
                    elif isinstance(raw, str):
                        low = raw.lower()
                        if '"status": "error"' in low or '"status":"error"' in low:
                            status = "error"
                        elif '"status": "success"' in low or '"status":"success"' in low:
                            status = "success"
                    parts.append(
                        f"{i + 1}. {tool}({params_str}) -> {status} "
                        f"[body elided — older than the last "
                        f"{self._KEEP_FULL_RESULTS} calls]"
                    )

            parts.append(
                "[End of tool history]\n"
                "If a previous call failed, READ THE ERROR and either fix the "
                "parameters or pick a different tool — do NOT repeat an "
                "identical failing call. When you have enough information, "
                "give the final answer in plain text without any <tool> tag."
            )
        return "\n".join(parts)
