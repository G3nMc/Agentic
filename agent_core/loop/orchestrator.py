"""High-level orchestrator for running agent tasks."""

from typing import Optional

from agent_core.core.config import AgentConfig
from agent_core.core.state import WorkflowState
from agent_core.loop.agent_loop import AgentLoop
from agent_core.config import load_config_from_env


class Orchestrator:
    """High-level orchestrator for running agent tasks."""
    
    def __init__(self, config: Optional[AgentConfig] = None):
        self.config = config or load_config_from_env()
        self.loop = AgentLoop(self.config)
    
    def run(self, task: str, project_context: str = "") -> WorkflowState:
        """Run a task through the agent loop."""
        return self.loop.run(task, project_context)
    
    def run_streaming(self, task: str, project_context: str = ""):
        """Run a task with streaming updates (not yet implemented)."""
        # TODO: Implement streaming
        return self.run(task, project_context)
