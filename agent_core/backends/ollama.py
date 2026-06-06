"""Ollama local LLM backend with function calling support."""

from typing import List, Dict, Any, Optional
import json
import requests

from agent_core.backends.base import LLMBackend, CompletionResponse
from agent_core.config.models import ModelConfig


class OllamaBackend(LLMBackend):
    """Ollama local LLM backend."""
    
    def __init__(self, config: ModelConfig):
        super().__init__(config)
        self.base_url = config.base_url or "http://localhost:11434"
        self._model = config.model
    
    def complete(
        self,
        messages: List[Dict[str, Any]],
        tools: Optional[List[Dict[str, Any]]] = None,
        **kwargs
    ) -> CompletionResponse:
        """Complete using Ollama Chat API."""
        payload = {
            "model": self._model,
            "messages": messages,
            "stream": False,
            "options": {
                "temperature": kwargs.get("temperature", self.config.temperature),
                "num_predict": kwargs.get("max_tokens", self.config.max_tokens),
            },
        }
        
        # Ollama supports tools via function calling format
        if tools:
            payload["tools"] = tools
        
        headers = {}
        if self.config.api_key:
            headers["Authorization"] = f"Bearer {self.config.api_key}"
        response = requests.post(
            f"{self.base_url}/api/chat",
            json=payload,
            headers=headers,
            timeout=120,
        )
        response.raise_for_status()
        data = response.json()
        
        message = data.get("message", {})
        content = message.get("content", "")
        
        tool_calls = []
        if "tool_calls" in message:
            for tc in message["tool_calls"]:
                tool_calls.append({
                    "id": tc.get("id", f"call_{len(tool_calls)}"),
                    "name": tc.get("function", {}).get("name", ""),
                    "arguments": tc.get("function", {}).get("arguments", {}),
                })
        
        return CompletionResponse(
            content=content if content else None,
            tool_calls=tool_calls,
            finish_reason=data.get("done_reason", "stop"),
            usage={},
        )
    
    def count_tokens(self, text: str) -> int:
        """Estimate tokens (Ollama doesn't provide token counting API)."""
        # Rough estimation: ~4 chars per token for English
        return len(text) // 4
    
    def supports_native_tools(self) -> bool:
        # Ollama supports tools but depends on model
        return True
    
    def get_tool_format(self) -> str:
        return "openai"  # Ollama uses OpenAI-compatible tool format
