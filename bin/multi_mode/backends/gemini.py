"""Google Gemini backend (multi_mode) with native function calling.

See :mod:`agent.backends.gemini` for the single-agent-mode
counterpart. The two are kept separate because they target
different SDKs (``google.generativeai`` here vs ``google-genai``
there) and different base classes (:class:`LLMBackend` here vs
:class:`common.backends.backend_base.ModelBackend` there).
Merging requires first unifying the two backend base classes.
"""

from typing import List, Dict, Any, Optional
import json

from multi_mode.backends.base import LLMBackend, CompletionResponse
from multi_mode.config.models import ModelConfig


class GeminiBackend(LLMBackend):
    """Google Gemini API backend with native function calling support."""
    
    def __init__(self, config: ModelConfig):
        super().__init__(config)
        try:
            import google.generativeai as genai
            genai.configure(api_key=config.api_key)
            self.model = genai.GenerativeModel(config.model)
            self._model = config.model
        except ImportError:
            raise RuntimeError("google-generativeai package not installed. Run: pip install google-generativeai")
    
    def complete(
        self,
        messages: List[Dict[str, Any]],
        tools: Optional[List[Dict[str, Any]]] = None,
        **kwargs
    ) -> CompletionResponse:
        """Complete using Gemini API with native function calling."""
        # Convert messages to Gemini format
        gemini_messages = []
        system_instruction = None
        
        for msg in messages:
            role = msg.get("role")
            content = msg.get("content", "")
            
            if role == "system":
                system_instruction = content
            elif role == "tool":
                # Tool result
                tool_call_id = msg.get("tool_call_id")
                is_error = msg.get("metadata", {}).get("error", False)
                gemini_messages.append({
                    "role": "user",
                    "parts": [
                        {
                            "function_response": {
                                "name": msg.get("metadata", {}).get("tool_name", "unknown"),
                                "response": {
                                    "content": content,
                                    "error": is_error,
                                },
                                "id": tool_call_id,
                            }
                        }
                    ],
                })
            elif role == "assistant" and msg.get("tool_calls"):
                # Assistant with function calls
                function_calls = []
                for tc in msg["tool_calls"]:
                    function_calls.append({
                        "name": tc.get("name", ""),
                        "args": tc.get("arguments", {}),
                        "id": tc.get("id", ""),
                    })
                gemini_messages.append({
                    "role": "model",
                    "parts": [{"function_call": fc} for fc in function_calls],
                })
            else:
                # Regular message
                gemini_role = "user" if role == "user" else "model"
                gemini_messages.append({
                    "role": gemini_role,
                    "parts": [content],
                })
        
        # Prepare generation config
        generation_config = {
            "temperature": kwargs.get("temperature", self.config.temperature),
            "max_output_tokens": kwargs.get("max_tokens", self.config.max_tokens),
        }
        
        # Prepare tools
        gemini_tools = None
        if tools:
            gemini_tools = []
            for tool in tools:
                fn = tool.get("function", {})
                gemini_tools.append({
                    "function_declarations": [{
                        "name": fn.get("name"),
                        "description": fn.get("description", ""),
                        "parameters": fn.get("parameters", {}),
                    }]
                })
        
        # Generate content
        if system_instruction:
            response = self.model.generate_content(
                gemini_messages,
                generation_config=generation_config,
                tools=gemini_tools,
                system_instruction=system_instruction,
            )
        else:
            response = self.model.generate_content(
                gemini_messages,
                generation_config=generation_config,
                tools=gemini_tools,
            )
        
        content = None
        tool_calls = []
        
        if response.candidates:
            candidate = response.candidates[0]
            if candidate.content and candidate.content.parts:
                for part in candidate.content.parts:
                    if hasattr(part, 'text') and part.text:
                        content = part.text
                    elif hasattr(part, 'function_call') and part.function_call:
                        fc = part.function_call
                        tool_calls.append({
                            "id": getattr(fc, 'id', ''),
                            "name": fc.name,
                            "arguments": dict(fc.args) if fc.args else {},
                        })
        
        # Get usage metadata
        usage = {}
        if hasattr(response, 'usage_metadata') and response.usage_metadata:
            usage = {
                "prompt_tokens": response.usage_metadata.prompt_token_count,
                "completion_tokens": response.usage_metadata.candidates_token_count,
                "total_tokens": response.usage_metadata.total_token_count,
            }
        
        finish_reason = "stop"
        if response.candidates and response.candidates[0].finish_reason:
            finish_reason = str(response.candidates[0].finish_reason)
        
        return CompletionResponse(
            content=content,
            tool_calls=tool_calls,
            finish_reason=finish_reason,
            usage=usage,
        )
    
    def count_tokens(self, text: str) -> int:
        """Count tokens using Gemini's token counter."""
        try:
            return self.model.count_tokens(text).total_tokens
        except Exception:
            return len(text) // 4
    
    def supports_native_tools(self) -> bool:
        return True
    
    def get_tool_format(self) -> str:
        return "gemini"
