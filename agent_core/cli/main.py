"""CLI entry point for Agent Core."""

import sys
import argparse
import os

from agent_core.config import AgentConfig, load_config_from_env
from agent_core.loop.orchestrator import Orchestrator
from agent_core.core.state import TaskStatus


def main():
    parser = argparse.ArgumentParser(description="Agent Core - Multi-Agent Workflow")
    parser.add_argument("--task", "-t", required=True, help="Task to execute")
    parser.add_argument("--config", "-c", help="Path to config file (not yet implemented)")
    parser.add_argument("--model-reasoner", help="Reasoner model (e.g., gpt-4o)")
    parser.add_argument("--model-summarizer", help="Summarizer model (e.g., gpt-4o-mini)")
    parser.add_argument("--provider-reasoner", help="Reasoner provider (openai, anthropic, gemini, ollama, openrouter)")
    parser.add_argument("--provider-summarizer", help="Summarizer provider")
    parser.add_argument("--project-root", default=".", help="Project root directory")
    parser.add_argument("--max-iterations", type=int, default=50, help="Max iterations")
    parser.add_argument("--token-budget", type=int, default=100000, help="Token budget")
    parser.add_argument("--no-summarization", action="store_true", help="Disable summarization")
    parser.add_argument("--system-prompt", help="Custom system prompt")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    
    args = parser.parse_args()
    
    # Load base config from env
    config = load_config_from_env()
    
    # Override with CLI args
    if args.model_reasoner:
        config.models["reasoner"].model = args.model_reasoner
    if args.model_summarizer and "summarizer" in config.models:
        config.models["summarizer"].model = args.model_summarizer
    if args.provider_reasoner:
        config.models["reasoner"].provider = args.provider_reasoner
    if args.provider_summarizer and "summarizer" in config.models:
        config.models["summarizer"].provider = args.provider_summarizer
    config.project_root = args.project_root
    config.max_iterations = args.max_iterations
    config.token_budget = args.token_budget
    config.enable_summarization = not args.no_summarization
    if args.system_prompt:
        config.system_prompt = args.system_prompt
    
    # Change to project root
    os.chdir(args.project_root)
    
    # Create orchestrator and run
    orchestrator = Orchestrator(config)
    
    print(f"Starting task: {args.task}", file=sys.stderr)
    print(f"Project root: {args.project_root}", file=sys.stderr)
    print(f"Reasoner: {config.models['reasoner'].provider}/{config.models['reasoner'].model}", file=sys.stderr)
    if config.enable_summarization and "summarizer" in config.models:
        print(f"Summarizer: {config.models['summarizer'].provider}/{config.models['summarizer'].model}", file=sys.stderr)
    print("---", file=sys.stderr)
    
    state = orchestrator.run(args.task)
    
    print("---", file=sys.stderr)
    print(f"Status: {state.status.value}", file=sys.stderr)
    print(f"Iterations: {state.iteration}", file=sys.stderr)
    
    if state.status == TaskStatus.COMPLETED:
        # Find the final answer
        for msg in reversed(state.messages):
            if msg.role.value == "assistant" and msg.content and not msg.tool_calls:
                print(msg.content)
                break
        return 0
    else:
        error = state.metadata.get("error", "Unknown error")
        print(f"Error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
