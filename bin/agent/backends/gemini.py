"""Google Gemini backend (single-agent mode) via the official google-genai SDK.

NOTE on coexistence with :mod:`multi_mode.backends.gemini`:
The two ``gemini.py`` files implement distinct APIs that cannot be
merged without breaking one of the orchestrators:

  - This file targets the new ``google-genai`` SDK and the
    :class:`common.backends.backend_base.ModelBackend` interface
    (``complete()`` returns a tuple); used by ``orchestrator.py``.
  - :mod:`multi_mode.backends.gemini` targets the older
    ``google.generativeai`` library and the
    :class:`multi_mode.backends.base.LLMBackend` interface
    (``complete()`` returns a ``CompletionResponse``); used by
    ``orchestrator_multi.py``.

Unifying them requires first unifying the two base classes — out
of scope for this consolidation pass.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

from bin.common.backends.backend_base import ModelBackend
from bin.common.utils.text import sanitize_for_agent


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


class GeminiBackend(ModelBackend):
    """
    Google Gemini backend via the official google-genai SDK.

    Tool calls are requested natively from Gemini, then converted back to the
    orchestrator's existing <tool>...</tool> text protocol so the main loop can
    stay unchanged.
    """

    DEFAULT_MODEL = "gemini-2.5-flash"

    def __init__(self, api_key: str, model_id: str):
        api_key = (
            api_key
            or os.environ.get("GOOGLE_API_KEY", "")
            or os.environ.get("GEMINI_API_KEY", "")
        ).strip()
        if not api_key:
            raise RuntimeError("Gemini backend requires --gemini-api-key.")
        if not model_id:
            raise RuntimeError("Gemini backend requires --model.")

        from google import genai  # noqa: PLC0415
        from google.genai import types  # noqa: PLC0415

        self.model_id = model_id
        self._client = genai.Client(api_key=api_key)
        self._types = types

        _log(f"[Gemini:init] model={model_id} client created")

    @staticmethod
    def _normalize_finish_reason(reason: Any) -> str:
        if not reason:
            return ""
        text = str(reason).strip()
        low = text.lower()
        if "max_tokens" in low or "max token" in low:
            return "length"
        return low

    @staticmethod
    def _extract_retry_delay(exc: Exception) -> float:
        """Extract retryDelay (seconds) from a Google API error response.

        Parses the ``retryDelay`` field inside the ``RetryInfo`` detail,
        e.g. ``"retryDelay": "7s"``. Falls back to exponential back-off
        (2^attempt) when the field is missing or unparseable.
        """
        try:
            body = getattr(exc, "response_json", None)
            if body is None:
                resp = getattr(exc, "response", None)
                body = getattr(resp, "json", None)
                if callable(body):
                    body = body()
            if isinstance(body, dict):
                details = (
                    body.get("details") or body.get("error", {}).get("details") or []
                )
                for d in details:
                    if isinstance(d, dict) and d.get("@type", "").endswith("RetryInfo"):
                        raw = d.get("retryDelay", "")
                        if isinstance(raw, str):
                            m = re.match(r"(\d+(?:\.\d+)?)\s*s", raw.strip())
                            if m:
                                return float(m.group(1))
        except Exception:
            pass
        return 2.0  # conservative default

    def _to_contents(self, messages: List[Dict[str, Any]]) -> Tuple[str, List[Any]]:
        system_parts: List[str] = []
        contents: List[Any] = []
        for msg in messages:
            role = str(msg.get("role") or "").strip().lower()
            content = str(msg.get("content") or "")
            if not content.strip():
                continue
            if role == "system":
                system_parts.append(content.strip())
                continue
            gem_role = "user" if role == "user" else "model"
            contents.append(
                self._types.Content(
                    role=gem_role,
                    parts=[self._types.Part.from_text(text=content)],
                )
            )
        return "\n\n".join(system_parts).strip(), contents

    @staticmethod
    def _to_tool_definitions(tools: Optional[List[Dict[str, Any]]], types_mod):
        if not tools:
            return []
        declarations = []
        for tool in tools:
            function = tool.get("function", {}) if isinstance(tool, dict) else {}
            name = function.get("name")
            if not name:
                continue
            declarations.append(
                types_mod.FunctionDeclaration(
                    name=name,
                    description=function.get("description", ""),
                    parameters_json_schema=function.get(
                        "parameters",
                        {"type": "object", "properties": {}, "required": []},
                    ),
                )
            )
        if not declarations:
            return []
        return [types_mod.Tool(function_declarations=declarations)]

    def chat(self, messages, max_tokens, temperature, tools=None):
        messages = sanitize_for_agent(messages)
        tools = sanitize_for_agent(tools)

        system_instruction, contents = self._to_contents(messages)
        tool_defs = self._to_tool_definitions(tools, self._types)

        _log(
            f"[Gemini:chat] model={self.model_id} "
            f"msgs={len(contents)} system={bool(system_instruction)} "
            f"tools={len(tool_defs)} max_tokens={max_tokens} temperature={temperature}"
        )

        config_kwargs: Dict[str, Any] = {
            "temperature": temperature,
            "max_output_tokens": max_tokens,
        }
        if system_instruction:
            config_kwargs["system_instruction"] = sanitize_for_agent(system_instruction)
        if tool_defs:
            config_kwargs["tools"] = tool_defs
            config_kwargs["automatic_function_calling"] = (
                self._types.AutomaticFunctionCallingConfig(disable=True)
            )

        _log(f"[Gemini:request] sending generate_content to model={self.model_id}")

        # Retry loop for transient errors (429 rate-limit, 5xx server errors).
        # Extracts retryDelay from Google's error response when available,
        # otherwise falls back to exponential back-off.
        _MAX_RETRIES = 3
        last_exc: Optional[Exception] = None
        for attempt in range(_MAX_RETRIES):
            try:
                response = self._client.models.generate_content(
                    model=self.model_id,
                    contents=contents if contents else "",
                    config=self._types.GenerateContentConfig(**config_kwargs),
                )
                break  # success — exit retry loop
            except Exception as e:
                last_exc = e
                status_code = getattr(e, "status_code", None) or getattr(
                    getattr(e, "response", None), "status_code", None
                )
                # Only retry on transient errors (429, 5xx). Anything else
                # (4xx auth errors, bad requests) fails immediately.
                if status_code not in (429, 500, 502, 503, 504):
                    _log(
                        f"[Gemini:error] model={self.model_id} {type(e).__name__}: {e}"
                    )
                    raise RuntimeError(f"Gemini error: {e}") from e
                if attempt >= _MAX_RETRIES - 1:
                    _log(
                        f"[Gemini:error] model={self.model_id} "
                        f"retries exhausted ({_MAX_RETRIES}) — "
                        f"{type(e).__name__}: {e}"
                    )
                    raise RuntimeError(
                        f"Gemini error after {_MAX_RETRIES} retries: {e}"
                    ) from e
                # Extract retryDelay from the error body (Google returns it
                # in the RetryInfo detail). Fall back to exponential back-off.
                delay = self._extract_retry_delay(e)
                _log(
                    f"[Gemini:retry] model={self.model_id} "
                    f"attempt={attempt + 1}/{_MAX_RETRIES} "
                    f"status={status_code} delay={delay:.1f}s"
                )
                time.sleep(delay)

        candidates = getattr(response, "candidates", []) or []
        finish_reason = ""
        if candidates:
            finish_reason = self._normalize_finish_reason(
                getattr(candidates[0], "finish_reason", "")
            )

        _log(
            f"[Gemini:response] model={self.model_id} "
            f"candidates={len(candidates)} finish_reason={finish_reason!r}"
        )

        function_calls = list(getattr(response, "function_calls", []) or [])
        if not function_calls and candidates:
            candidate_content = getattr(candidates[0], "content", None)
            parts = getattr(candidate_content, "parts", []) or []
            for part in parts:
                function_call = getattr(part, "function_call", None)
                if function_call is not None:
                    function_calls.append(function_call)

        if function_calls:
            _log(
                f"[Gemini:tool_calls] {len(function_calls)} function call(s) in response"
            )
            if len(function_calls) > 1:
                _log(
                    f"[Gemini:tool_calls_multi] {len(function_calls)} calls — using first only"
                )

            fc = function_calls[0]
            call = getattr(fc, "function_call", fc)
            name = getattr(fc, "name", None) or getattr(call, "name", None)
            args = getattr(fc, "args", None)
            if args is None:
                args = (
                    getattr(call, "args", None)
                    or getattr(call, "arguments", None)
                    or {}
                )

            args = sanitize_for_agent(args)
            if not isinstance(args, dict):
                try:
                    args = dict(args)
                except Exception:
                    _log(
                        f"[Gemini:tool_call_args_error] cannot convert args to dict: {args!r}"
                    )
                    args = {}

            if not name:
                _log(f"[Gemini:tool_call_no_name] function call missing name — raising")
                raise RuntimeError("Gemini returned function call without name.")

            _log(
                f"[Gemini:tool_call] {name}({json.dumps(args, ensure_ascii=False)[:200]})"
            )
            return (
                f"<tool>{json.dumps({'tool': name, 'parameters': args}, ensure_ascii=False)}</tool>",
                finish_reason,
            )

        text = getattr(response, "text", "") or ""
        result = text.strip()
        _log(
            f"[Gemini:done] returning content ({len(result)} chars) finish_reason={finish_reason!r}"
        )
        return result, finish_reason
