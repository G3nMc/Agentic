"""Anthropic API backend with native tool calling."""

from typing import List, Dict, Any, Optional

from multi_mode.backends.base import LLMBackend, CompletionResponse
from multi_mode.config.models import ModelConfig


class AnthropicBackend(LLMBackend):
    """Anthropic API backend with native tool calling support."""
    
    def __init__(self, config: ModelConfig):
        super().__init__(config)
        try:
            from anthropic import Anthropic
            self.client = Anthropic(
                api_key=config.api_key,
                base_url=config.base_url,
            )
            self._model = config.model
        except ImportError:
            raise RuntimeError("anthropic package not installed. Run: pip install anthropic")
    
    def complete(
        self,
        messages: List[Dict[str, Any]],
        tools: Optional[List[Dict[str, Any]]] = None,
        **kwargs
    ) -> CompletionResponse:
        """Complete using Anthropic Messages API with native tools."""
        # Convert messages to Anthropic format
        system_prompt = ""
        anthropic_messages = []
        
        for msg in messages:
            role = msg.get("role")
            content = msg.get("content", "")
            
            if role == "system":
                system_prompt = content
            elif role == "tool":
                # Tool result message
                tool_call_id = msg.get("tool_call_id")
                is_error = msg.get("metadata", {}).get("error", False)
                anthropic_messages.append({
                    "role": "user",
                    "content": [
                        {
                            "type": "tool_result",
                            "tool_use_id": tool_call_id,
                            "content": content,
                            "is_error": is_error,
                        }
                    ],
                })
            elif role == "assistant" and msg.get("tool_calls"):
                # Assistant with tool calls
                tool_uses = []
                for tc in msg["tool_calls"]:
                    tool_uses.append({
                        "type": "tool_use",
                        "id": tc.get("id", ""),
                        "name": tc.get("name", ""),
                        "input": tc.get("arguments", {}),
                    })
                anthropic_messages.append({
                    "role": "assistant",
                    "content": tool_uses,
                })
            else:
                # Regular user/assistant message
                anthropic_messages.append({
                    "role": role,
                    "content": content,
                })
        
        completion_kwargs = {
            "model": self._model,
            "messages": anthropic_messages,
            "temperature": kwargs.get("temperature", self.config.temperature),
            "max_tokens": kwargs.get("max_tokens", self.config.max_tokens),
        }
        
        if system_prompt:
            completion_kwargs["system"] = system_prompt
        
        if tools:
            # Convert OpenAI tool format to Anthropic format
            anthropic_tools = []
            for tool in tools:
                fn = tool.get("function", {})
                anthropic_tools.append({
                    "name": fn.get("name"),
                    "description": fn.get("description", ""),
                    "input_schema": fn.get("parameters", {}),
                })
            completion_kwargs["tools"] = anthropic_tools
            completion_kwargs["tool_choice"] = kwargs.get("tool_choice", {"type": "auto"})
        
        response = self.client.messages.create(**completion_kwargs)
        
        content = ""
        tool_calls = []
        
        for block in response.content:
            if block.type == "text":
                content += block.text
            elif block.type == "tool_use":
                tool_calls.append({
                    "id": block.id,
                    "name": block.name,
                    "arguments": block.input,
                })
        
        return CompletionResponse(
            content=content if content else None,
            tool_calls=tool_calls,
            finish_reason=response.stop_reason or "stop",
            usage={
                "prompt_tokens": response.usage.input_tokens if response.usage else 0,
                "completion_tokens": response.usage.output_tokens if response.usage else 0,
                "total_tokens": (response.usage.input_tokens + response.usage.output_tokens) if response.usage else 0,
            } if response.usage else {},
        )
    
    def count_tokens(self, text: str) -> int:
        """Count tokens using Anthropic's token counter."""
        try:
            return self.client.messages.count_tokens(text=text).input_tokens
        except Exception:
            return len(text) // 4
    
    def supports_native_tools(self) -> bool:
        return True
    
    def get_tool_format(self) -> str:
        return "anthropic"
