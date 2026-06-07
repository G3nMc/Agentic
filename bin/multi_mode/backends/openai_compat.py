"""Shared base for all OpenAI-compatible backends.

Every hub that speaks the OpenAI chat/completions wire format
(Groq, OpenRouter, GitHub Models) inherits from ``OpenAICompatBackend``
instead of duplicating the same plumbing in each file.
"""

from __future__ import annotations

import json
import sys
from typing import Any, Dict, List, Optional, Tuple

from .backend_base import ModelBackend
from ..utils.text import sanitize_for_agent


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


class ToolsNotSupportedError(Exception):
    """Raised by _do_request when the provider rejects the tools parameter."""


class RateLimitError(Exception):
    """Raised by _do_request on 429 / quota-exceeded responses."""

    def __init__(self, message: str, retry_after: float = 0.0):
        super().__init__(message)
        self.retry_after = retry_after


class OpenAICompatBackend(ModelBackend):
    """Base class for OpenAI-compatible chat/completions backends."""

    max_retries: int = 4

    def __init__(
        self,
        api_key: str,
        model_id: str,
        base_url: str = "",
        label: str = "",
    ):
        if not api_key:
            raise RuntimeError(f"{self.__class__.__name__} requires an API key.")
        if not model_id:
            raise RuntimeError(f"{self.__class__.__name__} requires a model ID.")
        self.api_key = api_key
        self.model_id = model_id
        self.base_url = base_url.rstrip("/")
        self._label = label or self.__class__.__name__
        self._tools_unsupported: bool = False
        self.last_usage_tokens: int = 0
        _log(
            f"[{self._label}:init] model={model_id}"
            + (f" base_url={self.base_url}" if self.base_url else "")
        )

    # ------------------------------------------------------------------
    # Subclass contract
    # ------------------------------------------------------------------

    def _do_request(
        self,
        payload: Dict[str, Any],
        effective_tools: Optional[List[Dict[str, Any]]],
    ) -> Tuple[str, str, List[Any], int]:
        """Make the actual API call.

        Returns ``(content, finish_reason, native_tool_calls, usage_tokens)``.
        Raises ``ToolsNotSupportedError``, ``RateLimitError``, or ``RuntimeError``.
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Shared chat() implementation
    # ------------------------------------------------------------------

    def chat(
        self,
        messages: List[Dict[str, Any]],
        max_tokens: int,
        temperature: float,
        tools: Optional[List[Dict[str, Any]]] = None,
    ) -> Tuple[str, str]:
        messages = sanitize_for_agent(messages)
        tools = sanitize_for_agent(tools)

        effective_tools = None if self._tools_unsupported else tools
        n_tools = len(effective_tools) if effective_tools else 0

        _log(
            f"[{self._label}:chat] model={self.model_id} "
            f"msgs={len(messages)} tools={n_tools} "
            f"max_tokens={max_tokens} temperature={temperature}"
            + (
                " [tools_unsupported=True — sending without tools]"
                if self._tools_unsupported and tools
                else ""
            )
        )

        payload: Dict[str, Any] = {
            "model": self.model_id,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": temperature,
        }
        if effective_tools:
            payload["tools"] = effective_tools

        attempt = 0
        while True:
            try:
                _log(
                    f"[{self._label}:request] attempt={attempt + 1}/{self.max_retries} sending..."
                )
                content, finish_reason, native_calls, usage = self._do_request(
                    payload, effective_tools
                )
                _log(
                    f"[{self._label}:response] finish_reason={finish_reason!r} "
                    f"content_len={len(content or '')} "
                    f"tool_calls={len(native_calls)} usage_tokens={usage}"
                )
                break

            except ToolsNotSupportedError as exc:
                _log(
                    f"[{self._label}:tools_unsupported] model={self.model_id} "
                    f"error={exc} — disabling native tools, retrying with text protocol"
                )
                if not effective_tools:
                    raise RuntimeError(f"{self._label} tools error: {exc}") from exc
                self._tools_unsupported = True
                payload.pop("tools", None)
                effective_tools = None
                _log(f"[{self._label}:retry_no_tools] sending without tools=...")
                content, finish_reason, native_calls, usage = self._do_request(
                    payload, None
                )
                _log(
                    f"[{self._label}:response_no_tools] finish_reason={finish_reason!r} "
                    f"content_len={len(content or '')} tool_calls={len(native_calls)}"
                )
                break

            except RateLimitError as exc:
                attempt += 1
                if attempt >= self.max_retries:
                    _log(
                        f"[{self._label}:rate_limit_exhausted] "
                        f"all {self.max_retries} retries used — giving up. error={exc}"
                    )
                    raise RuntimeError(f"{self._label} rate limit: {exc}") from exc
                import time

                wait = (
                    exc.retry_after
                    if exc.retry_after > 0
                    else 5.0 * (2 ** (attempt - 1)) + 5.0
                )
                _log(
                    f"[{self._label}:rate_limit] attempt={attempt}/{self.max_retries} "
                    f"retry_after={exc.retry_after:.0f}s computed_wait={wait:.0f}s — sleeping..."
                )
                time.sleep(wait)

        self.last_usage_tokens = usage if isinstance(usage, int) and usage > 0 else 0

        if native_calls:
            _log(
                f"[{self._label}:tool_calls] converting {len(native_calls)} native call(s) to <tool> tags"
            )
            tags = self._tool_calls_to_tags(native_calls, self._label)
            if tags:
                return tags, finish_reason
            _log(
                f"[{self._label}:tool_calls_empty] conversion produced no tags — falling through to content"
            )

        result_len = len((content or "").strip())
        _log(
            f"[{self._label}:done] returning content ({result_len} chars) finish_reason={finish_reason!r}"
        )
        return (content or "").strip(), finish_reason

    # ------------------------------------------------------------------
    # Shared tool-call → <tool> tag converter
    # ------------------------------------------------------------------

    @staticmethod
    def _tool_calls_to_tags(native_calls: List[Any], label: str = "") -> str:
        tag_lines: List[str] = []
        for i, tc in enumerate(native_calls):
            if isinstance(tc, dict):
                fn: Any = tc.get("function") or {}
                name = (
                    fn.get("name")
                    if isinstance(fn, dict)
                    else getattr(fn, "name", None)
                )
                args = (
                    fn.get("arguments")
                    if isinstance(fn, dict)
                    else getattr(fn, "arguments", {})
                )
            else:
                fn = getattr(tc, "function", tc)
                name = getattr(fn, "name", None)
                args = getattr(fn, "arguments", {})

            args = args or {}
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except json.JSONDecodeError as exc:
                    _log(
                        f"[{label}:tool_call_parse_error] call[{i}] args JSON decode failed: {exc} raw={args!r:.120}"
                    )
                    args = {}

            if not name:
                _log(f"[{label}:tool_call_skip] call[{i}] has no name — skipping")
                continue

            tag = f"<tool>{json.dumps({'tool': name, 'parameters': args}, ensure_ascii=False)}</tool>"
            tag_lines.append(tag)
            _log(
                f"[{label}:tool_call] [{i}] {name}({json.dumps(args, ensure_ascii=False)[:200]})"
            )

        return "\n".join(tag_lines)
