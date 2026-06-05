"""LLM client abstraction with provider-specific implementations."""

from __future__ import annotations

import abc
import json
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from .state import Message, ToolCall


@dataclass
class LLMResponse:
    """Structured response from an LLM.

    Attributes:
        content: Text content of the response.
        tool_calls: Tool calls extracted from the response (if any).
        finish_reason: Why the model stopped (e.g., 'stop', 'tool_calls', 'length').
        usage: Token usage info (prompt_tokens, completion_tokens, total_tokens).
        model: The model that produced this response.
        raw: The raw provider response for debugging.
    """

    content: str = ""
    tool_calls: Optional[List[ToolCall]] = None
    finish_reason: str = "stop"
    usage: Dict[str, int] = field(default_factory=dict)
    model: str = ""
    raw: Any = None


class LLMClient(abc.ABC):
    """Abstract base class for LLM providers.

    All providers must implement `complete()` which takes a list of messages,
    optional tool definitions, and optional configuration overrides, and returns
    a structured `LLMResponse`.
    """

    @abc.abstractmethod
    def complete(
        self,
        messages: List[Message],
        tools: Optional[List[Dict[str, Any]]] = None,
        config: Optional[Dict[str, Any]] = None,
    ) -> LLMResponse:
        """Send a completion request to the LLM.

        Args:
            messages: Conversation history.
            tools: Optional tool definitions in OpenAI function-calling format.
            config: Optional provider-specific overrides (temperature, max_tokens, etc.).

        Returns:
            Structured LLMResponse.
        """
        ...

    @abc.abstractmethod
    def count_tokens(self, messages: List[Message]) -> int:
        """Count the number of tokens in the given messages.

        Args:
            messages: The messages to count tokens for.

        Returns:
            Token count.
        """
        ...

    @staticmethod
    def _messages_to_openai_format(
        messages: List[Message],
    ) -> List[Dict[str, Any]]:
        """Convert internal Message objects to OpenAI-compatible dicts."""
        result = []
        for msg in messages:
            entry: Dict[str, Any] = {"role": msg.role}
            if msg.content:
                entry["content"] = msg.content
            if msg.tool_calls:
                entry["tool_calls"] = [
                    {
                        "id": tc.id,
                        "type": "function",
                        "function": {
                            "name": tc.name,
                            "arguments": json.dumps(tc.arguments),
                        },
                    }
                    for tc in msg.tool_calls
                ]
            if msg.tool_call_id:
                entry["tool_call_id"] = msg.tool_call_id
            result.append(entry)
        return result


class OpenAIClient(LLMClient):
    """OpenAI API client."""

    def __init__(self, api_key: Optional[str] = None, base_url: Optional[str] = None):
        import os

        self.api_key = api_key or os.environ.get("OPENAI_API_KEY", "")
        self.base_url = base_url or os.environ.get("OPENAI_BASE_URL")

    def complete(
        self,
        messages: List[Message],
        tools: Optional[List[Dict[str, Any]]] = None,
        config: Optional[Dict[str, Any]] = None,
    ) -> LLMResponse:
        try:
            from openai import OpenAI
        except ImportError:
            raise ImportError(
                "openai package is required. Install with: pip install openai"
            )

        client_kwargs: Dict[str, Any] = {"api_key": self.api_key}
        if self.base_url:
            client_kwargs["base_url"] = self.base_url
        client = OpenAI(**client_kwargs)

        cfg = config or {}
        model = cfg.get("model", "gpt-4o")

        request_kwargs: Dict[str, Any] = {
            "model": model,
            "messages": self._messages_to_openai_format(messages),
            "temperature": cfg.get("temperature", 0.7),
            "max_tokens": cfg.get("max_tokens", 4096),
        }
        if tools:
            request_kwargs["tools"] = tools
            request_kwargs["tool_choice"] = cfg.get("tool_choice", "auto")

        response = client.chat.completions.create(**request_kwargs)
        choice = response.choices[0]
        message = choice.message

        tool_calls = None
        if message.tool_calls:
            tool_calls = [
                ToolCall(
                    id=tc.id,
                    name=tc.function.name,
                    arguments=json.loads(tc.function.arguments),
                )
                for tc in message.tool_calls
            ]

        return LLMResponse(
            content=message.content or "",
            tool_calls=tool_calls,
            finish_reason=choice.finish_reason or "stop",
            usage={
                "prompt_tokens": response.usage.prompt_tokens if response.usage else 0,
                "completion_tokens": (
                    response.usage.completion_tokens if response.usage else 0
                ),
                "total_tokens": response.usage.total_tokens if response.usage else 0,
            },
            model=response.model,
            raw=response,
        )

    def count_tokens(self, messages: List[Message]) -> int:
        try:
            import tiktoken
        except ImportError:
            # Fallback: rough estimation (4 chars per token)
            total = 0
            for msg in messages:
                total += len(msg.content) // 4
                if msg.tool_calls:
                    for tc in msg.tool_calls:
                        total += len(json.dumps(tc.arguments)) // 4
            return total

        encoding = tiktoken.get_encoding("cl100k_base")
        total = 0
        for msg in messages:
            total += len(encoding.encode(msg.content))
            if msg.tool_calls:
                for tc in msg.tool_calls:
                    total += len(encoding.encode(json.dumps(tc.arguments)))
        return total


class AnthropicClient(LLMClient):
    """Anthropic Claude API client."""

    def __init__(self, api_key: Optional[str] = None):
        import os

        self.api_key = api_key or os.environ.get("ANTHROPIC_API_KEY", "")

    def complete(
        self,
        messages: List[Message],
        tools: Optional[List[Dict[str, Any]]] = None,
        config: Optional[Dict[str, Any]] = None,
    ) -> LLMResponse:
        try:
            import anthropic
        except ImportError:
            raise ImportError(
                "anthropic package is required. Install with: pip install anthropic"
            )

        client = anthropic.Anthropic(api_key=self.api_key)
        cfg = config or {}
        model = cfg.get("model", "claude-3-5-sonnet-20241022")

        # Convert messages to Anthropic format
        system_prompt = ""
        anthropic_messages = []
        for msg in messages:
            if msg.role == "system":
                system_prompt += msg.content + "\n"
            elif msg.role == "user":
                anthropic_messages.append({"role": "user", "content": msg.content})
            elif msg.role == "assistant":
                content: Any = msg.content
                if msg.tool_calls:
                    content = []
                    if msg.content:
                        content.append({"type": "text", "text": msg.content})
                    for tc in msg.tool_calls:
                        content.append(
                            {
                                "type": "tool_use",
                                "id": tc.id,
                                "name": tc.name,
                                "input": tc.arguments,
                            }
                        )
                anthropic_messages.append({"role": "assistant", "content": content})
            elif msg.role == "tool":
                anthropic_messages.append(
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "tool_result",
                                "tool_use_id": msg.tool_call_id,
                                "content": msg.content,
                            }
                        ],
                    }
                )

        request_kwargs: Dict[str, Any] = {
            "model": model,
            "max_tokens": cfg.get("max_tokens", 4096),
            "messages": anthropic_messages,
        }
        if system_prompt.strip():
            request_kwargs["system"] = system_prompt.strip()
        if tools:
            request_kwargs["tools"] = tools

        response = client.messages.create(**request_kwargs)

        content_text = ""
        tool_calls = None
        for block in response.content:
            if block.type == "text":
                content_text += block.text
            elif block.type == "tool_use":
                if tool_calls is None:
                    tool_calls = []
                tool_calls.append(
                    ToolCall(
                        id=block.id,
                        name=block.name,
                        arguments=block.input,
                    )
                )

        return LLMResponse(
            content=content_text,
            tool_calls=tool_calls,
            finish_reason=response.stop_reason or "stop",
            usage={
                "prompt_tokens": response.usage.input_tokens if response.usage else 0,
                "completion_tokens": (
                    response.usage.output_tokens if response.usage else 0
                ),
                "total_tokens": (
                    (response.usage.input_tokens + response.usage.output_tokens)
                    if response.usage
                    else 0
                ),
            },
            model=response.model,
            raw=response,
        )

    def count_tokens(self, messages: List[Message]) -> int:
        try:
            import tiktoken

            encoding = tiktoken.get_encoding("cl100k_base")
        except ImportError:
            total = 0
            for msg in messages:
                total += len(msg.content) // 4
                if msg.tool_calls:
                    for tc in msg.tool_calls:
                        total += len(json.dumps(tc.arguments)) // 4
            return total

        total = 0
        for msg in messages:
            total += len(encoding.encode(msg.content))
            if msg.tool_calls:
                for tc in msg.tool_calls:
                    total += len(encoding.encode(json.dumps(tc.arguments)))
        return total


class OllamaClient(LLMClient):
    """Ollama local API client."""

    def __init__(self, base_url: Optional[str] = None):
        import os

        self.base_url = base_url or os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434")

    def complete(
        self,
        messages: List[Message],
        tools: Optional[List[Dict[str, Any]]] = None,
        config: Optional[Dict[str, Any]] = None,
    ) -> LLMResponse:
        import requests

        cfg = config or {}
        model = cfg.get("model", "llama3.2")

        payload: Dict[str, Any] = {
            "model": model,
            "messages": self._messages_to_openai_format(messages),
            "stream": False,
            "options": {
                "temperature": cfg.get("temperature", 0.7),
                "num_predict": cfg.get("max_tokens", 4096),
            },
        }
        if tools:
            payload["tools"] = tools

        response = requests.post(
            f"{self.base_url}/api/chat",
            json=payload,
            timeout=120,
        )
        response.raise_for_status()
        data = response.json()

        msg = data.get("message", {})
        content = msg.get("content", "")

        tool_calls = None
        if "tool_calls" in msg and msg["tool_calls"]:
            tool_calls = []
            for tc in msg["tool_calls"]:
                tool_calls.append(
                    ToolCall(
                        id=tc.get("id", ""),
                        name=tc.get("function", {}).get("name", ""),
                        arguments=tc.get("function", {}).get("arguments", {}),
                    )
                )

        return LLMResponse(
            content=content,
            tool_calls=tool_calls,
            finish_reason=data.get("done_reason", "stop"),
            usage={
                "prompt_tokens": data.get("prompt_eval_count", 0),
                "completion_tokens": data.get("eval_count", 0),
                "total_tokens": data.get("prompt_eval_count", 0) + data.get("eval_count", 0),
            },
            model=data.get("model", model),
            raw=data,
        )

    def count_tokens(self, messages: List[Message]) -> int:
        # Ollama doesn't provide token counting; use rough estimation
        total = 0
        for msg in messages:
            total += len(msg.content) // 4
            if msg.tool_calls:
                for tc in msg.tool_calls:
                    total += len(json.dumps(tc.arguments)) // 4
        return total


class GeminiClient(LLMClient):
    """Google Gemini API client."""

    def __init__(self, api_key: Optional[str] = None):
        import os

        self.api_key = api_key or os.environ.get("GEMINI_API_KEY", "")

    def complete(
        self,
        messages: List[Message],
        tools: Optional[List[Dict[str, Any]]] = None,
        config: Optional[Dict[str, Any]] = None,
    ) -> LLMResponse:
        try:
            import google.generativeai as genai
        except ImportError:
            raise ImportError(
                "google-generativeai package is required. Install with: pip install google-generativeai"
            )

        genai.configure(api_key=self.api_key)
        cfg = config or {}
        model_name = cfg.get("model", "gemini-2.0-flash")
        model = genai.GenerativeModel(model_name)

        # Convert messages to Gemini format
        contents = []
        system_instruction = None
        for msg in messages:
            if msg.role == "system":
                system_instruction = msg.content
            elif msg.role == "user":
                contents.append({"role": "user", "parts": [{"text": msg.content}]})
            elif msg.role == "assistant":
                parts = []
                if msg.content:
                    parts.append({"text": msg.content})
                if msg.tool_calls:
                    for tc in msg.tool_calls:
                        parts.append(
                            {
                                "functionCall": {
                                    "name": tc.name,
                                    "args": tc.arguments,
                                }
                            }
                        )
                contents.append({"role": "model", "parts": parts})
            elif msg.role == "tool":
                contents.append(
                    {
                        "role": "user",
                        "parts": [
                            {
                                "functionResponse": {
                                    "name": msg.tool_call_id,
                                    "response": {"result": msg.content},
                                }
                            }
                        ],
                    }
                )

        generation_config = {
            "temperature": cfg.get("temperature", 0.7),
            "max_output_tokens": cfg.get("max_tokens", 4096),
        }

        request_kwargs: Dict[str, Any] = {
            "contents": contents,
            "generation_config": generation_config,
        }
        if system_instruction:
            request_kwargs["system_instruction"] = system_instruction
        if tools:
            request_kwargs["tools"] = tools

        response = model.generate_content(**request_kwargs)

        content_text = ""
        tool_calls = None
        if response.candidates:
            candidate = response.candidates[0]
            for part in candidate.content.parts:
                if part.text:
                    content_text += part.text
                elif hasattr(part, "function_call") and part.function_call:
                    if tool_calls is None:
                        tool_calls = []
                    tool_calls.append(
                        ToolCall(
                            id=part.function_call.name,
                            name=part.function_call.name,
                            arguments=dict(part.function_call.args),
                        )
                    )

        return LLMResponse(
            content=content_text,
            tool_calls=tool_calls,
            finish_reason="stop",
            usage={
                "prompt_tokens": response.usage_metadata.prompt_token_count
                if response.usage_metadata
                else 0,
                "completion_tokens": response.usage_metadata.candidates_token_count
                if response.usage_metadata
                else 0,
                "total_tokens": response.usage_metadata.total_token_count
                if response.usage_metadata
                else 0,
            },
            model=model_name,
            raw=response,
        )

    def count_tokens(self, messages: List[Message]) -> int:
        try:
            import google.generativeai as genai

            total = 0
            for msg in messages:
                total += genai.count_tokens(model="models/gemini-2.0-flash", prompt=msg.content).total_tokens
            return total
        except Exception:
            total = 0
            for msg in messages:
                total += len(msg.content) // 4
                if msg.tool_calls:
                    for tc in msg.tool_calls:
                        total += len(json.dumps(tc.arguments)) // 4
            return total


def create_client(provider: str, **kwargs: Any) -> LLMClient:
    """Factory function to create an LLM client.

    Args:
        provider: One of 'openai', 'anthropic', 'ollama', 'gemini'.
        **kwargs: Provider-specific arguments (api_key, base_url, etc.).

    Returns:
        An LLMClient instance.
    """
    providers = {
        "openai": OpenAIClient,
        "anthropic": AnthropicClient,
        "ollama": OllamaClient,
        "gemini": GeminiClient,
    }
    if provider not in providers:
        raise ValueError(
            f"Unknown provider: {provider}. Available: {list(providers.keys())}"
        )
    return providers[provider](**kwargs)
