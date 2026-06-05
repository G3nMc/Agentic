"""Agent configuration."""

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Any
import os

from agent_core.config.models import ModelConfig, ModelRole, DEFAULT_REASONER, DEFAULT_SUMMARIZER


@dataclass
class AgentConfig:
    """Main configuration for the agent workflow."""
    models: Dict[ModelRole, ModelConfig] = field(default_factory=dict)
    max_iterations: int = 50
    token_budget: int = 100000
    summarization_threshold: float = 0.7
    tool_timeout: int = 30
    parallel_tools: bool = True
    project_root: str = "."
    excluded_paths: List[str] = field(default_factory=lambda: [
        ".git", "__pycache__", "*.pyc", ".venv", "venv", 
        "node_modules", ".dart_tool", "build", "dist"
    ])
    system_prompt: str = ""
    enable_summarization: bool = True
    # enable_shaper: REMOVED - deterministic context building only

    def __post_init__(self):
        # Set default models if not provided
        if ModelRole.REASONER not in self.models:
            self.models[ModelRole.REASONER] = DEFAULT_REASONER
        if ModelRole.SUMMARIZER not in self.models and self.enable_summarization:
            self.models[ModelRole.SUMMARIZER] = DEFAULT_SUMMARIZER


def load_config_from_env() -> AgentConfig:
    """Load configuration from environment variables."""
    config = AgentConfig()
    
    # Reasoner model (required)
    reasoner_provider = os.getenv("REASONER_PROVIDER", "openai")
    reasoner_model = os.getenv("REASONER_MODEL", "gpt-4o")
    reasoner_api_key = os.getenv("REASONER_API_KEY")
    reasoner_base_url = os.getenv("REASONER_BASE_URL")
    reasoner_temp = float(os.getenv("REASONER_TEMPERATURE", "0.1"))
    reasoner_max_tokens = int(os.getenv("REASONER_MAX_TOKENS", "4096"))
    reasoner_context = int(os.getenv("REASONER_CONTEXT_WINDOW", "128000"))
    
    config.models[ModelRole.REASONER] = ModelConfig(
        role=ModelRole.REASONER,
        provider=reasoner_provider,
        model=reasoner_model,
        api_key=reasoner_api_key,
        base_url=reasoner_base_url,
        temperature=reasoner_temp,
        max_tokens=reasoner_max_tokens,
        context_window=reasoner_context,
    )
    
    # Summarizer model
    if config.enable_summarization:
        summarizer_provider = os.getenv("SUMMARIZER_PROVIDER", "openai")
        summarizer_model = os.getenv("SUMMARIZER_MODEL", "gpt-4o-mini")
        summarizer_api_key = os.getenv("SUMMARIZER_API_KEY")
        summarizer_base_url = os.getenv("SUMMARIZER_BASE_URL")
        summarizer_temp = float(os.getenv("SUMMARIZER_TEMPERATURE", "0.1"))
        summarizer_max_tokens = int(os.getenv("SUMMARIZER_MAX_TOKENS", "2048"))
        summarizer_context = int(os.getenv("SUMMARIZER_CONTEXT_WINDOW", "128000"))
        
        config.models[ModelRole.SUMMARIZER] = ModelConfig(
            role=ModelRole.SUMMARIZER,
            provider=summarizer_provider,
            model=summarizer_model,
            api_key=summarizer_api_key,
            base_url=summarizer_base_url,
            temperature=summarizer_temp,
            max_tokens=summarizer_max_tokens,
            context_window=summarizer_context,
        )
    
    # Other settings
    config.max_iterations = int(os.getenv("MAX_ITERATIONS", "50"))
    config.token_budget = int(os.getenv("TOKEN_BUDGET", "100000"))
    config.summarization_threshold = float(os.getenv("SUMMARIZATION_THRESHOLD", "0.7"))
    config.tool_timeout = int(os.getenv("TOOL_TIMEOUT", "30"))
    config.parallel_tools = os.getenv("PARALLEL_TOOLS", "true").lower() == "true"
    config.project_root = os.getenv("PROJECT_ROOT", ".")
    config.system_prompt = os.getenv("SYSTEM_PROMPT", "")
    config.enable_summarization = os.getenv("ENABLE_SUMMARIZATION", "true").lower() == "true"
    
    return config
