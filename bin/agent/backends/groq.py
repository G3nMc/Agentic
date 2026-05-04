"""Groq Cloud backend via the official `groq` Python library."""
from __future__ import annotations

# import json
import re
# import sys
from typing import Any, Dict, List

from .backend_base import ModelBackend
from ..utils.text import sanitize_for_agent


class GroqBackend(ModelBackend):
    """
    Groq Cloud backend via the official `groq` Python library.
    Ultra-fast LPU inference. API key from https://console.groq.com/keys.
    Streaming is used so token chunks act as heartbeats.
    Reasoning blocks (<think>…</think>) are stripped from the final answer.
    """

    _THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)

    def __init__(self, api_key: str, model_id: str):
        if not api_key:
            raise RuntimeError("Groq backend requires --groq-api-key.")
        if not model_id:
            raise RuntimeError("Groq backend requires --model.")
        from groq import Groq  # noqa: PLC0415
        self.model_id = model_id
        self._client = Groq(api_key=api_key)

    # Track whether this model has already proven it doesn't support native
    # tool calling so we don't waste a round-trip on the next iteration.
    _tools_unsupported: bool = False

    def chat(self, messages, max_tokens, temperature, tools=None):
        from groq import BadRequestError  # noqa: PLC0415

        import sys
        import json

        messages = sanitize_for_agent(messages)
        tools = sanitize_for_agent(tools)

        effective_tools = None if self._tools_unsupported else tools

        try:
            parts: List[str] = []
            finish_reason = ""
            chunk_count = 0
            native_calls: List[Any] = []

            chat_kwargs: Dict[str, Any] = dict(
                model=self.model_id,
                messages=messages,
                stream=True,
                temperature=temperature,
                max_completion_tokens=max_tokens,
            )

            if effective_tools:
                chat_kwargs["tools"] = effective_tools

            stream = self._client.chat.completions.create(**chat_kwargs)

            for chunk in stream:
                delta = chunk.choices[0].delta if chunk.choices else None

                if delta:
                    content = delta.content or ""
                    if content:
                        parts.append(content)

                    tcs = getattr(delta, "tool_calls", None) or []
                    native_calls.extend(tcs)

                chunk_count += 1

                if chunk_count % 20 == 1:
                    print(
                        f"[orch] Groq streaming '{self.model_id}' "
                        f"({len(''.join(parts))} chars)...",
                        file=sys.stderr,
                        flush=True,
                    )

                if chunk.choices and chunk.choices[0].finish_reason:
                    finish_reason = chunk.choices[0].finish_reason

            # Native tool calls → <tool> format
            if native_calls:
                tag_lines: List[str] = []

                for tc in native_calls:
                    fn = getattr(tc, "function", tc)
                    name = getattr(fn, "name", None)
                    args = getattr(fn, "arguments", {}) or {}

                    if isinstance(args, str):
                        try:
                            args = json.loads(args)
                        except json.JSONDecodeError:
                            args = {}

                    if not name:
                        continue

                    tag_lines.append(
                        f'<tool>{json.dumps({"tool": name, "parameters": args})}</tool>'
                    )

                    print(
                        f"[orch] Groq native tool_call -> {name}({args})",
                        file=sys.stderr,
                        flush=True,
                    )

                if tag_lines:
                    return "\n".join(tag_lines), finish_reason

            return "".join(parts).strip(), finish_reason

        except BadRequestError as e:
            err_str = str(e).lower()

            if (effective_tools
                    and "tool" in err_str
                    and ("not supported" in err_str or "unsupported" in err_str)):
                self._tools_unsupported = True

                print(
                    f"[orch] '{self.model_id}' doesn't support native tool calling — fallback enabled.",
                    file=sys.stderr,
                    flush=True,
                )

                return self.chat(messages, max_tokens, temperature, tools=tools)

            raise RuntimeError(f"Groq bad request: {e}") from e

        except Exception as e:
            raise RuntimeError(f"Groq error: {e}") from e
    # def chat(self, messages, max_tokens, temperature, tools=None):
    #     from groq import BadRequestError  # noqa: PLC0415
    #
    #     # If a previous call already hit the "tool calling not supported"
    #     # 400, skip the tools parameter for all subsequent calls in this
    #     # session so we rely on the text-based <tool>…</tool> protocol.
    #     effective_tools = None if self._tools_unsupported else tools
    #
    #     try:
    #         parts: List[str] = []
    #         finish_reason = ""
    #         chunk_count = 0
    #         native_calls: List[Any] = []
    #
    #         chat_kwargs: Dict[str, Any] = dict(
    #             model=self.model_id,
    #             messages=messages,
    #             stream=True,
    #             temperature=temperature,
    #             max_completion_tokens=max_tokens,
    #         )
    #         if effective_tools:
    #             chat_kwargs["tools"] = effective_tools
    #
    #         stream = self._client.chat.completions.create(**chat_kwargs)
    #         for chunk in stream:
    #             delta = chunk.choices[0].delta if chunk.choices else None
    #             if delta:
    #                 content = delta.content or ""
    #                 if content:
    #                     parts.append(content)
    #                 tcs = getattr(delta, "tool_calls", None) or []
    #                 native_calls.extend(tcs)
    #             chunk_count += 1
    #             if chunk_count % 20 == 1:
    #                 print(
    #                     f"[orch] Groq streaming '{self.model_id}' "
    #                     f"({len(''.join(parts))} chars)...",
    #                     file=sys.stderr, flush=True,
    #                 )
    #             else:
    #                 sys.stderr.write("\n")
    #                 sys.stderr.flush()
    #             if chunk.choices and chunk.choices[0].finish_reason:
    #                 finish_reason = chunk.choices[0].finish_reason
    #
    #         # Native tool calls → <tool> tag format
    #         if native_calls:
    #             tag_lines: List[str] = []
    #             for tc in native_calls:
    #                 fn = getattr(tc, "function", tc)
    #                 name = getattr(fn, "name", None)
    #                 args = getattr(fn, "arguments", {}) or {}
    #                 if isinstance(args, str):
    #                     try:
    #                         args = json.loads(args)
    #                     except json.JSONDecodeError:
    #                         args = {}
    #                 if not name:
    #                     continue
    #                 tag_lines.append(
    #                     f'<tool>{json.dumps({"tool": name, "parameters": args})}</tool>'
    #                 )
    #                 print(f"[orch] Groq native tool_call -> {name}({args})",
    #                       file=sys.stderr, flush=True)
    #             if tag_lines:
    #                 return "\n".join(tag_lines), finish_reason
    #
    #         # Return raw content — <think> blocks are preserved so the
    #         # Flutter UI can render them as a collapsible "Reasoning" section.
    #         # The Orchestrator.run() loop strips them from history entries to
    #         # save context, but the final answer keeps them intact.
    #         return "".join(parts).strip(), finish_reason
    #
    #     except BadRequestError as e:
    #         err_str = str(e).lower()
    #         if (effective_tools
    #                 and "tool" in err_str
    #                 and ("not supported" in err_str or "unsupported" in err_str)):
    #             # Model doesn't support native tool calling (e.g. DeepSeek-R1,
    #             # QwQ, other reasoning models). Mark the flag so all future
    #             # calls in this session skip the tools= parameter, then retry
    #             # this call immediately using the text-based <tool>…</tool>
    #             # protocol that is already in the system prompt.
    #             self._tools_unsupported = True
    #             print(
    #                 f"[orch] '{self.model_id}' doesn't support native tool "
    #                 "calling — falling back to text-based <tool> protocol.",
    #                 file=sys.stderr, flush=True,
    #             )
    #             return self.chat(messages, max_tokens, temperature, tools=tools)
    #         raise RuntimeError(f"Groq bad request: {e}") from e
    #     except Exception as e:
    #         raise RuntimeError(f"Groq error: {e}") from e
