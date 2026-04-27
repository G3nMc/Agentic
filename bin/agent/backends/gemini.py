"""Google Gemini backend via the official google-genai SDK."""
from __future__ import annotations

# import json
import os
# import sys
from typing import Any, Dict, List, Optional, Tuple

from .backend_base import ModelBackend
from ..utils.text import sanitize


class GeminiBackend(ModelBackend):
    """
    Google Gemini backend via the official google-genai SDK.

    Tool calls are requested natively from Gemini, then converted back to the
    orchestrator's existing <tool>...</tool> text protocol so the main loop can
    stay unchanged.
    """

    DEFAULT_MODEL = "gemini-2.5-flash"

    def __init__(self, api_key: str, model_id: str):
        api_key = (api_key or os.environ.get("GOOGLE_API_KEY", "") or
                   os.environ.get("GEMINI_API_KEY", "")).strip()
        if not api_key:
            raise RuntimeError("Gemini backend requires --gemini-api-key.")
        if not model_id:
            raise RuntimeError("Gemini backend requires --model.")

        from google import genai  # noqa: PLC0415
        from google.genai import types  # noqa: PLC0415

        self.model_id = model_id
        self._client = genai.Client(api_key=api_key)
        self._types = types

    @staticmethod
    def _normalize_finish_reason(reason: Any) -> str:
        if not reason:
            return ""
        text = str(reason).strip()
        low = text.lower()
        if "max_tokens" in low or "max token" in low:
            return "length"
        return low

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
        import json
        import sys

        messages = sanitize(messages)
        tools = sanitize(tools)

        system_instruction, contents = self._to_contents(messages)
        tool_defs = self._to_tool_definitions(tools, self._types)

        config_kwargs: Dict[str, Any] = {
            "temperature": temperature,
            "max_output_tokens": max_tokens,
        }

        if system_instruction:
            config_kwargs["system_instruction"] = sanitize(system_instruction)

        if tool_defs:
            config_kwargs["tools"] = tool_defs
            config_kwargs["automatic_function_calling"] = (
                self._types.AutomaticFunctionCallingConfig(disable=True)
            )

        print(
            f"[orch] Gemini request '{self.model_id}' "
            f"({len(contents)} msgs, tools={bool(tool_defs)})...",
            file=sys.stderr,
            flush=True,
        )

        try:
            response = self._client.models.generate_content(
                model=self.model_id,
                contents=sanitize(contents if contents else ""),
                config=self._types.GenerateContentConfig(**config_kwargs),
            )

        except Exception as e:
            raise RuntimeError(f"Gemini error: {e}") from e

        candidates = getattr(response, "candidates", []) or []
        finish_reason = ""

        if candidates:
            finish_reason = self._normalize_finish_reason(
                getattr(candidates[0], "finish_reason", "")
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
            if len(function_calls) > 1:
                print(
                    f"[orch] Gemini returned {len(function_calls)} function calls; using first.",
                    file=sys.stderr,
                    flush=True,
                )

            fc = function_calls[0]
            call = getattr(fc, "function_call", fc)

            name = getattr(fc, "name", None) or getattr(call, "name", None)

            args = getattr(fc, "args", None)
            if args is None:
                args = getattr(call, "args", None) or getattr(call, "arguments", None) or {}

            args = sanitize(args)

            if not isinstance(args, dict):
                try:
                    args = dict(args)
                except Exception:
                    args = {}

            if not name:
                raise RuntimeError("Gemini returned function call without name.")

            print(
                f"[orch] Gemini tool_call -> {name}({args})",
                file=sys.stderr,
                flush=True,
            )

            return (
                f'<tool>{json.dumps({"tool": name, "parameters": args}, ensure_ascii=False)}</tool>',
                finish_reason,
            )

        text = getattr(response, "text", "") or ""

        text = sanitize(text)

        return text.strip(), finish_reason


    # def chat(self, messages, max_tokens, temperature, tools=None):
    #     system_instruction, contents = self._to_contents(messages)
    #     tool_defs = self._to_tool_definitions(tools, self._types)
    #
    #     config_kwargs: Dict[str, Any] = {
    #         "temperature": temperature,
    #         "max_output_tokens": max_tokens,
    #     }
    #     if system_instruction:
    #         config_kwargs["system_instruction"] = system_instruction
    #     if tool_defs:
    #         config_kwargs["tools"] = tool_defs
    #         config_kwargs["automatic_function_calling"] = (
    #             self._types.AutomaticFunctionCallingConfig(disable=True)
    #         )
    #
    #     print(
    #         f"[orch] Gemini request '{self.model_id}' "
    #         f"({len(contents)} msgs, tools={bool(tool_defs)})...",
    #         file=sys.stderr,
    #         flush=True,
    #     )
    #
    #     try:
    #         response = self._client.models.generate_content(
    #             model=self.model_id,
    #             contents=contents if contents else "",
    #             config=self._types.GenerateContentConfig(**config_kwargs),
    #         )
    #     except Exception as e:
    #         raise RuntimeError(f"Gemini error: {e}") from e
    #
    #     candidates = getattr(response, "candidates", []) or []
    #     finish_reason = ""
    #     if candidates:
    #         finish_reason = self._normalize_finish_reason(
    #             getattr(candidates[0], "finish_reason", "")
    #         )
    #
    #     function_calls = list(getattr(response, "function_calls", []) or [])
    #     if not function_calls and candidates:
    #         candidate_content = getattr(candidates[0], "content", None)
    #         parts = getattr(candidate_content, "parts", []) or []
    #         for part in parts:
    #             function_call = getattr(part, "function_call", None)
    #             if function_call is not None:
    #                 function_calls.append(function_call)
    #
    #     if function_calls:
    #         if len(function_calls) > 1:
    #             print(
    #                 f"[orch] Gemini returned {len(function_calls)} function "
    #                 "calls; using the first one.",
    #                 file=sys.stderr,
    #                 flush=True,
    #             )
    #         fc = function_calls[0]
    #         call = getattr(fc, "function_call", fc)
    #         name = getattr(fc, "name", None) or getattr(call, "name", None)
    #         args = getattr(fc, "args", None)
    #         if args is None:
    #             args = getattr(call, "args", None) or getattr(call, "arguments", None) or {}
    #         if not isinstance(args, dict):
    #             try:
    #                 args = dict(args)
    #             except Exception:
    #                 args = {}
    #         if not name:
    #             raise RuntimeError("Gemini returned a function call without a name.")
    #         print(
    #             f"[orch] Gemini tool_call -> {name}({args})",
    #             file=sys.stderr,
    #             flush=True,
    #         )
    #         return (
    #             f'<tool>{json.dumps({"tool": name, "parameters": args})}</tool>',
    #             finish_reason,
    #         )
    #
    #     text = getattr(response, "text", "") or ""
    #     return text.strip(), finish_reason
