"""Structured output parsing for Reasoner responses.

Handles native function calling and fallback JSON extraction with validation."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

from .state import ToolCall
from .llm_client import LLMResponse


@dataclass
class ParsedOutput:
    """Parsed output from the Reasoner."""
    tool_calls: Optional[List[ToolCall]] = None
    final_answer: Optional[str] = None
    plan: Optional[Dict[str, Any]] = None
    raw_content: str = ""
    parse_errors: List[str] = None

    def __post_init__(self):
        if self.parse_errors is None:
            self.parse_errors = []

    @property
    def has_tool_calls(self) -> bool:
        return bool(self.tool_calls)

    @property
    def has_final_answer(self) -> bool:
        return bool(self.final_answer)

    @property
    def has_plan(self) -> bool:
        return bool(self.plan)

    @property
    def is_actionable(self) -> bool:
        return self.has_tool_calls or self.has_final_answer or self.has_plan


class OutputParser:
    """Parses LLM responses into structured output.

    Priority:
    1. Native function calling (OpenAI, Anthropic, Gemini, Ollama with tools)
    2. Structured JSON in content (for models without native function calling)
    3. Regex extraction as last resort
    """

    def __init__(self, max_retries: int = 2):
        self.max_retries = max_retries

    def parse(self, response: LLMResponse, tools_available: List[Dict[str, Any]] = None) -> ParsedOutput:
        """Parse an LLM response into structured output.

        Args:
            response: The raw LLM response.
            tools_available: List of tool definitions for validation.

        Returns:
            ParsedOutput with tool_calls, final_answer, or plan.
        """
        # 1. Native function calling - already parsed by LLM client
        if response.tool_calls:
            return ParsedOutput(
                tool_calls=response.tool_calls,
                raw_content=response.content,
            )

        # 2. Try to parse structured JSON from content
        content = response.content.strip()
        if not content:
            return ParsedOutput(
                raw_content=content,
                parse_errors=["Empty response content"],
            )

        # Try to extract JSON from the response
        parsed = self._try_parse_json(content, tools_available)
        if parsed:
            return parsed

        # 3. Fallback: treat as final answer
        return ParsedOutput(
            final_answer=content,
            raw_content=content,
        )

    def _try_parse_json(self, content: str, tools_available: List[Dict[str, Any]] = None) -> Optional[ParsedOutput]:
        """Try to parse JSON from content."""
        # Strategy 1: Direct JSON parse
        try:
            data = json.loads(content)
            return self._interpret_parsed_json(data, tools_available)
        except json.JSONDecodeError:
            pass

        # Strategy 2: Extract JSON from markdown code blocks
        json_blocks = re.findall(r'', content, re.DOTALL)
        for block in json_blocks:
            try:
                data = json.loads(block)
                parsed = self._interpret_parsed_json(data, tools_available)
                if parsed:
                    return parsed
            except json.JSONDecodeError:
                continue

        # Strategy 3: Find JSON-like structure in text
        # Look for { ... } with tool_calls or final_answer keys
        json_matches = re.findall(r'\{.*?"(?:tool_calls|final_answer|plan)".*?\}', content, re.DOTALL)
        for match in json_matches:
            try:
                data = json.loads(match)
                parsed = self._interpret_parsed_json(data, tools_available)
                if parsed:
                    return parsed
            except json.JSONDecodeError:
                continue

        return None

    def _interpret_parsed_json(self, data: Dict[str, Any], tools_available: List[Dict[str, Any]] = None) -> Optional[ParsedOutput]:
        """Interpret parsed JSON as structured output."""
        errors = []

        # Check for tool_calls
        if "tool_calls" in data and isinstance(data["tool_calls"], list):
            tool_calls = []
            for i, tc in enumerate(data["tool_calls"]):
                if not isinstance(tc, dict):
                    errors.append(f"tool_calls[{i}]: not an object")
                    continue
                if "name" not in tc:
                    errors.append(f"tool_calls[{i}]: missing 'name'")
                    continue
                tool_calls.append(ToolCall(
                    id=tc.get("id", f"call_{i}"),
                    name=tc["name"],
                    arguments=tc.get("arguments", {}),
                ))
            if tool_calls and not errors:
                # Validate against available tools
                if tools_available:
                    valid_names = {t["function"]["name"] for t in tools_available if "function" in t}
                    for tc in tool_calls:
                        if tc.name not in valid_names:
                            errors.append(f"Unknown tool: {tc.name}")
                if not errors:
                    return ParsedOutput(tool_calls=tool_calls, raw_content=json.dumps(data))

        # Check for final_answer
        if "final_answer" in data and isinstance(data["final_answer"], str):
            return ParsedOutput(final_answer=data["final_answer"], raw_content=json.dumps(data))

        # Check for plan
        if "plan" in data and isinstance(data["plan"], dict):
            return ParsedOutput(plan=data["plan"], raw_content=json.dumps(data))

        return None

    def create_correction_prompt(self, errors: List[str], original_content: str) -> str:
        """Create a correction prompt for retry."""
        return f"""Your previous response had parsing errors:
{chr(10).join(f'- {e}' for e in errors)}

Original response:
{original_content}

Please respond with valid JSON only. Use one of these formats:

1. For tool calls:
{{
  "tool_calls": [
    {{"id": "call_1", "name": "tool_name", "arguments": {{...}}}}
  ]
}}

2. For final answer:
{{
  "final_answer": "Your answer here"
}}

3. For plan:
{{
  "plan": {{"steps": [...], "current_step": 0}}
}}
"""