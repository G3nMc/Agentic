"""Tool schema definitions (JSON Schema based)."""

from dataclasses import dataclass, field
from typing import Dict, Any, List, Optional
import json


@dataclass
class ParameterSchema:
    type: str
    description: str = ""
    enum: List[Any] = field(default_factory=list)
    items: Optional["ParameterSchema"] = None
    properties: Dict[str, "ParameterSchema"] = field(default_factory=dict)
    required: List[str] = field(default_factory=list)
    default: Any = None
    
    def to_json_schema(self) -> Dict[str, Any]:
        schema = {"type": self.type, "description": self.description}
        if self.enum:
            schema["enum"] = self.enum
        if self.items:
            schema["items"] = self.items.to_json_schema()
        if self.properties:
            schema["properties"] = {k: v.to_json_schema() for k, v in self.properties.items()}
        if self.required:
            schema["required"] = self.required
        if self.default is not None:
            schema["default"] = self.default
        return schema


@dataclass
class ToolSchema:
    name: str
    description: str
    parameters: ParameterSchema
    
    def to_json_schema(self) -> Dict[str, Any]:
        return {
            "type": "function",
            "function": {
                "name": self.name,
                "description": self.description,
                "parameters": self.parameters.to_json_schema(),
            },
        }
    
    def to_anthropic_format(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "input_schema": self.parameters.to_json_schema(),
        }
    
    def to_gemini_format(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "parameters": self.parameters.to_json_schema(),
        }
