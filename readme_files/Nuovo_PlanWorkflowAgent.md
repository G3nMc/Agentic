 

# Development Plan: Rebuilt Multi-Agent Workflow

Based on the analysis, here's a complete plan to build a **correct, production-ready workflow** from scratch.

---

## Target Architecture

```
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚                    SINGLE WORKFLOW LOOP                         â”‚
â”œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¤
â”‚  REASONER (strong model)                                        â”‚
â”‚    â€¢ Planning + Tool Calling + Final Answer                     â”‚
â”‚    â€¢ Deterministic context building (no Shaper LLM)             â”‚
â”‚    â€¢ Receives: user task + project context + history            â”‚
â”‚                                                                 â”‚
â”‚  EXECUTOR (deterministic, no LLM)                               â”‚
â”‚    â€¢ Executes tool calls, validates results                     â”‚
â”‚    â€¢ Returns structured results or errors                       â”‚
â”‚                                                                 â”‚
â”‚  SUMMARIZER (cheap model, triggered by context threshold)       â”‚
â”‚    â€¢ Compacts history when token budget exceeded                â”‚
â”‚    â€¢ Runs asynchronously, doesn't block main loop               â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
```

**Models**: 3 total (Reasoner=strong, Summarizer=cheap, Executor=none)

---

## Phase 1: Foundation (Core Infrastructure)

### Step 1.1: Project Structure & Configuration
- Create new package: `multi_mode/` (clean, no legacy code)
- Config system: `AgentConfig` with model assignments, token budgets, tool registry
- Environment-based model selection (no hardcoded model names)

### Step 1.2: Message & State Types
- `Message` (role, content, tool_calls, tool_call_id, metadata)
- `ToolCall` / `ToolResult` (structured, not regex-parsed)
- `WorkflowState` (messages, pending_tools, token_count, iteration, status)
- `TaskStatus` enum: `PENDING` | `IN_PROGRESS` | `COMPLETED` | `FAILED` | `NEEDS_REVISION`

### Step 1.3: LLM Client Abstraction
- `LLMClient` protocol: `complete(messages, tools?, config?) -> Response`
- Implementations: `OpenAIClient`, `AnthropicClient`, `OllamaClient`, `GeminiClient`
- **Native function calling** where supported; fallback to structured parsing only when necessary
- Token counting per provider (accurate, not estimation)

### Step 1.4: Tool Registry & Executor
- `Tool` protocol: `name`, `description`, `parameters` (JSON Schema), `execute(args) -> Result`
- Built-in tools: `read_file`, `write_file`, `patch_file`, `search_in_files`, `list_files`, `run_command`, `flutter_analyze`, `python_check`
- `ToolExecutor`: validates args against schema, executes, returns structured `ToolResult`
- Parallel execution for independent tool calls

---





## Phase 2: Reasoner (The Brain)

### Step 2.1: Deterministic Context Builder (replaces Shaper)
- `ContextBuilder.build(messages, config, project_context) -> prompt_messages`
- Strategies:
  - **Full history** (under token budget)
  - **Sliding window** (recent N messages + system prompt)
  - **Summarized** (when Summarizer has run)
- No LLM call â€” pure Python logic

### Step 2.2: Reasoner Agent
- `Reasoner.run(state, config) -> ReasonerOutput`
- System prompt variants:
  - **Planning mode** (first turn): decompose task, create plan
  - **Execution mode**: use tools, reason about results
  - **Final mode**: synthesize answer when done
- Output: `tool_calls` (list) OR `final_answer` (string) OR `plan` (structured)
- Handles feedback loops internally: sees tool results, decides next action

### Step 2.3: Structured Output Parsing
- If provider supports function calling â†’ use native
- Else â†’ robust JSON extraction with schema validation
- Retry logic for malformed output (max 2 retries with correction prompt)

---

## Phase 3: Summarizer (Context Management)

### Step 3.1: Summarizer Agent
- `Summarizer.summarize(messages, config) -> Summary`
- Cheap model (e.g., `gpt-4o-mini`, `haiku`, `llama3.2:3b`)
- Preserves: decisions, tool results, errors, current plan
- Compresses: verbose explanations, repeated context

### Step 3.2: Trigger Logic
- `ContextManager.should_summarize(token_count, config) -> bool`
- Threshold: 70% of model's context window
- Runs **asynchronously** in background; main loop continues with current context
- When ready, swaps history atomically

---

## Phase 4: Workflow Orchestration

### Step 4.1: Main Loop
```python
def run(task: str, config: AgentConfig) -> Result:
    state = WorkflowState.initial(task, config)
    
    while not state.is_terminal():
        # 1. Build context (deterministic)
        messages = ContextBuilder.build(state.messages, config, project_context)
        
        # 2. Reasoner decides action
        output = Reasoner.run(messages, config)
        
        if output.tool_calls:
            # 3. Execute tools (parallel where possible)
            results = ToolExecutor.execute_batch(output.tool_calls)
            state.add_tool_results(results)
            
        elif output.final_answer:
            return Result.success(output.final_answer)
            
        elif output.plan:
            state.set_plan(output.plan)
            
        # 4. Check context budget
        if ContextManager.should_summarize(state.token_count, config):
            ContextManager.trigger_summarization(state, config)
            
        state.iteration += 1
        if state.iteration > config.max_iterations:
            return Result.partial(state.messages)
    
    return Result.from_state(state)
```

### Step 4.2: Completion Criteria
- Reasoner returns `final_answer` (explicit completion)
- OR all planned subtasks marked `COMPLETED`
- OR max iterations reached (graceful degradation)

### Step 4.3: Error Handling & Recovery
- Tool failures â†’ returned to Reasoner as `ToolResult(error=...)`
- Reasoner decides: retry, alternative tool, or escalate
- LLM failures â†’ retry with backoff, fallback model

---

## Phase 5: Integration & Testing

### Step 5.1: CLI Entry Point
- `bin/agent_new/main.py` (or replace `bin/agent/`)
- Args: `--task`, `--config`, `--model-reasoner`, `--model-summarizer`
- Streaming output for long-running tasks

### Step 5.2: Test Suite
- **Unit tests**: ContextBuilder, ToolExecutor, token counting
- **Integration tests**: Full workflow on sample tasks
- **Golden tests**: Known tasks with expected outputs
- **Stress tests**: Large context, many tools, error recovery

### Step 5.3: Migration & Cleanup
- Verify new workflow completes tasks old workflow couldn't
- Deprecate `bin/agent/` and `agent/` (old workflows)
- Update documentation

---

## Step Dependencies

```
Phase 1 (Foundation)
  1.1 â†’ 1.2 â†’ 1.3 â†’ 1.4
       â†“
Phase 2 (Reasoner)
  2.1 â†’ 2.2 â†’ 2.3
       â†“
Phase 3 (Summarizer)
  3.1 â†’ 3.2
       â†“
Phase 4 (Orchestration)
  4.1 â†’ 4.2 â†’ 4.3
       â†“
Phase 5 (Integration)
  5.1 â†’ 5.2 â†’ 5.3
```

---

## Estimated Effort

| Phase | Steps | Complexity |
|-------|-------|------------|
| 1. Foundation | 4 | Medium (boilerplate but critical) |
| 2. Reasoner | 3 | High (core logic) |
| 3. Summarizer | 2 | Low-Medium |
| 4. Orchestration | 3 | Medium |
| 5. Integration | 3 | Medium |
| **Total** | **15 steps** | **~2-3 weeks** |

---

## Key Principles (Non-Negotiable)

1. **No LLM call for context building** â€” deterministic only
2. **Native function calling** â€” regex parsing is a bug, not a feature
3. **Explicit feedback loops** â€” Reasoner sees every tool result
4. **Structured state** â€” no implicit "role completion" tracking
5. **Async summarization** â€” never blocks the main loop
6. **Test-first** â€” each step validated before next

---

## Ready to Start?

**Step 1.1** creates the package structure and config system. Want me to begin?

---

