"""OpenAI API backend with native function calling."""

from typing import List, Dict, Any, Optional
import json

from multi_mode.backends.base import LLMBackend, CompletionResponse
from multi_mode.config.models import ModelConfig


class OpenAIBackend(LLMBackend):
    """OpenAI API backend with native function calling support."""
    
    def __init__(self, config: ModelConfig):
        super().__init__(config)
        try:
            from openai import OpenAI
            self.client = OpenAI(
                api_key=config.api_key,
                base_url=config.base_url,
            )
            self._model = config.model
        except ImportError:
            raise RuntimeError("openai package not installed. Run: pip install openai")
        except Exception as e:
            # Catch OpenAIError (missing credentials) and other init failures
            raise RuntimeError(
                f"Failed to initialize OpenAI backend: {e}. "
                "Ensure you have set the API key via --reasoner-api-key or the OPENAI_API_KEY environment variable."
            ) from e
    
    def complete(
        self,
        messages: List[Dict[str, Any]],
        tools: Optional[List[Dict[str, Any]]] = None,
        **kwargs
    ) -> CompletionResponse:
        """Complete using OpenAI Chat Completions API with native tools."""
        completion_kwargs = {
            "model": self._model,
            "messages": messages,
            "temperature": kwargs.get("temperature", self.config.temperature),
            "max_tokens": kwargs.get("max_tokens", self.config.max_tokens),
        }
        
        if tools:
            completion_kwargs["tools"] = tools
            completion_kwargs["tool_choice"] = kwargs.get("tool_choice", "auto")
        
        response = self.client.chat.completions.create(**completion_kwargs)
        
        choice = response.choices[0]
        message = choice.message
        
        tool_calls = []
        if message.tool_calls:
            for tc in message.tool_calls:
                try:
                    args = json.loads(tc.function.arguments)
                except json.JSONDecodeError:
                    args = {}
                tool_calls.append({
                    "id": tc.id,
                    "name": tc.function.name,
                    "arguments": args,
                })
        
        return CompletionResponse(
            content=message.content,
            tool_calls=tool_calls,
            finish_reason=choice.finish_reason,
            usage={
                "prompt_tokens": response.usage.prompt_tokens if response.usage else 0,
                "completion_tokens": response.usage.completion_tokens if response.usage else 0,
                "total_tokens": response.usage.total_tokens if response.usage else 0,
            } if response.usage else {},
        )
    
    def count_tokens(self, text: str) -> int:
        """Count tokens using tiktoken."""
        try:
            import tiktoken
            encoding = tiktoken.encoding_for_model(self._model)
            return len(encoding.encode(text))
        except Exception:
            # Fallback estimation
            return len(text) // 4
    
    def supports_native_tools(self) -> bool:
        return True
    
    def get_tool_format(self) -> str:
        return "openai"
