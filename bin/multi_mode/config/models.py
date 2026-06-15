"""Model configuration types."""

from dataclasses import dataclass, field
from typing import Optional, Dict, Any
from enum import Enum


class ModelRole(Enum):
    """Roles that models can play in the workflow."""
    REASONER = "reasoner"      # Strong model: planning, tool calling, final answer
    SUMMARIZER = "summarizer"  # Cheap model: context compression
    # EXECUTOR = no LLM (deterministic tool execution)
    # SHAPER = REMOVED (deterministic context building only)


# Reasoning effort levels supported across providers.
# Maps to OpenAI `reasoning_effort`, Anthropic `thinking.budget_tokens`,
# Gemini `thinkingConfig.thinkingBudget`, and OpenRouter passthrough.
# Ollama has no native reasoning parameter — the field is silently ignored.
class ReasoningLevel(str, Enum):
    MINIMAL = "minimal"
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    MAX = "max"


@dataclass
class ModelConfig:
    """Configuration for a single model."""
    role: ModelRole
    provider: str
    model: str
    api_key: Optional[str] = None
    base_url: Optional[str] = None
    temperature: float = 0.1
    max_tokens: int = 4096
    context_window: int = 128000
    reasoning_level: ReasoningLevel = ReasoningLevel.MAX
    # Provider-specific options
    extra: Dict[str, Any] = field(default_factory=dict)

    def __post_init__(self):
        # Set default context windows per provider/model if not specified
        if self.context_window == 128000:  # default value
            self.context_window = self._default_context_window()
    
    def _default_context_window(self) -> int:
        """Get default context window for known models."""
        model_lower = self.model.lower()
        provider_lower = self.provider.lower()
        
        # OpenAI models
        if provider_lower == "openai":
            if "gpt-4o" in model_lower:
                return 128000
            if "gpt-4-turbo" in model_lower:
                return 128000
            if "gpt-4" in model_lower:
                return 8192
            if "gpt-3.5" in model_lower:
                return 16384
        
        # Anthropic models
        if provider_lower == "anthropic":
            if "claude-3-5-sonnet" in model_lower:
                return 200000
            if "claude-3-opus" in model_lower:
                return 200000
            if "claude-3-sonnet" in model_lower:
                return 200000
            if "claude-3-haiku" in model_lower:
                return 200000
        
        # Gemini models
        if provider_lower == "gemini":
            if "1.5-pro" in model_lower:
                return 2000000
            if "1.5-flash" in model_lower:
                return 1000000
        
        # Ollama models (varies, use conservative default)
        if provider_lower == "ollama":
            return 32768
        
        # OpenRouter (depends on model)
        if provider_lower == "openrouter":
            return 128000
        
        return 128000  # Conservative default


# Default model configurations (can be overridden by env)
DEFAULT_REASONER = ModelConfig(
    role=ModelRole.REASONER,
    provider="openai",
    model="gpt-4o",
    temperature=0.1,
    max_tokens=4096,
    reasoning_level=ReasoningLevel.MAX,
)

DEFAULT_SUMMARIZER = ModelConfig(
    role=ModelRole.SUMMARIZER,
    provider="openai",
    model="gpt-4o-mini",
    temperature=0.1,
    max_tokens=2048,
    reasoning_level=ReasoningLevel.MAX,
)
