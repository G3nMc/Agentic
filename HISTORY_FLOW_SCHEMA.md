# History / Message Flow Schema

## Overview

There are **two independent paths** for how conversation history reaches the LLM backend.

```
User Input
    |
    +---> Single-Agent Orchestrator (run_loop.py)
    |         |
    |         v
    |     conversation_history[]  <-- flat, mutable list
    |         |
    |         v
    |     backend.chat(messages=conversation_history)
    |
    +---> Multi-Agent Workflow (workflow.py)
              |
              v
          state.history[]  <-- shared mutable list
              |
              +---> RouterAgent.run(state)
              |         |
              |         v
              |     _build_messages(system_prompt, history, user_input)
              |         |
              |         v
              |     backend.chat(messages=[system, ...history, user])
              |
              +---> ReasonerAgent.run(state)
              |         |
              |         v
              |     _compose_user_block(state)
              |         |
              |         v
              |     _build_messages(system_prompt, history, user_block)
              |         |
              |         v
              |     backend.chat(messages=[system, ...history, user_block])
              |
              +---> ExecutorAgent.run(state)
                        |
                        v
                    backend.chat(messages=[system, ...history, tool_results])
```

---

## 1. Single-Agent Mode (`Orchestrator.run`)

### Data structure
```python
self.conversation_history: List[Dict[str, str]] = [
    {"role": "system",    "content": "<system prompt>"},
    {"role": "user",      "content": "<original request>"},
    {"role": "assistant", "content": '<tool>{"tool":"read_file",...}</tool>'},
    {"role": "user",      "content": "Tool `read_file` returned:\n...\n[INTERNAL: ...]"},
    {"role": "assistant", "content": '<tool>{"tool":"patch_file",...}</tool>'},
    {"role": "user",      "content": "Tool `patch_file` returned:\n...\n[INTERNAL: ...]"},
    # ... grows unbounded until trimmed
]
```

### How it reaches the backend
```python
# run_loop.py ~line 323 (chat mode) and ~line 551 (tool loop)
text, _ = self.backend.chat(
    messages=self.conversation_history,   # <-- ENTIRE list passed raw
    max_tokens=self.max_tokens,
    temperature=self.temperature,
    tools=None,  # or tool_definitions
)
```

### Key characteristics
| Aspect | Behaviour |
|--------|-----------|
| **System prompt** | Injected once at turn 0, never rebuilt |
| **History growth** | Appends 2 messages per iteration (assistant tool call + user result) |
| **Trimming** | `trim_history_by_tokens()` when > `_history_token_budget` |
| **Tool results** | Inlined directly as user messages with `[INTERNAL: ...]` directives |
| **State** | All state lives in `self.conversation_history` |

---

## 2. Multi-Agent Mode (`Workflow.run`)

### Data structure
```python
state.history: List[Dict[str, str]] = [
    {"role": "user",      "content": "<original request>"},
    {"role": "assistant", "content": "<router decision: reasoning>"},
    {"role": "user",      "content": "<shaped prompt>"},
    {"role": "assistant", "content": "<reasoner plan / tool calls>"},
    {"role": "user",      "content": "<tool results summary>"},
    {"role": "assistant", "content": "<reasoner final answer>"},
]

state.tool_results: List[Dict[str, Any]] = [
    {"tool": "read_file", "parameters": {...}, "result": "..."},
    {"tool": "patch_file", "parameters": {...}, "result": "..."},
]
```

### How it reaches the backend (Reasoner example)
```python
# reasoner.py ~line 87
user_block = self._compose_user_block(state)   # shaped_prompt + tool_results
messages = self._build_messages(user_block, history=state.history)
# messages = [
#     {"role": "system", "content": "<reasoner system prompt>"},
#     {"role": "user", "content": "<original request>"},
#     {"role": "assistant", "content": "<router decision>"},
#     ...
#     {"role": "user", "content": "<composed user block>"},
# ]
text, _ = self._chat(messages, tools=self.tool_definitions)
```

### Key characteristics
| Aspect | Behaviour |
|--------|-----------|
| **System prompt** | Rebuilt by *every* agent with its own role-specific prompt |
| **History growth** | Appends 1-2 messages per agent call; tool results live in `state.tool_results` |
| **Trimming** | `compact_if_needed()` + `_trim_history()` before each reasoner pass |
| **Tool results** | Composed into a single user block by `_compose_user_block()` |
| **State** | Split across `state.history`, `state.tool_results`, `state.shaped_prompt`, etc. |

---

## 3. Agent Base (`Agent._build_messages`)

```python
def _build_messages(self, user_content: str,
                    history: Optional[List[Dict]] = None) -> List[Dict]:
    messages = [
        {"role": "system", "content": self.system_prompt}   # <-- AGENT-SPECIFIC
    ]
    if history:
        for m in history:
            role = m.get("role")
            if role in ("user", "assistant", "system"):
                messages.append({"role": role, "content": m.get("content", "")})
    messages.append({"role": "user", "content": user_content})
    return messages
```

**Critical difference from single-agent:**
- The system prompt is **re-prepended on every agent call**
- History is a **parameter**, not the entire message list
- Each agent sees only what `state.history` contains at that moment

---

## 4. Backend Interface (`backend.chat`)

All paths converge here:

```python
# backend_base.py
def chat(self, messages, max_tokens, temperature, tools=None):
    # 1. Rate-limit check (token bucket)
    # 2. Trim if over TPM limit
    # 3. Call inner backend
    content, finish_reason = self.inner.chat(messages, max_tokens, temperature, tools)
    # 4. Record usage
    return content, finish_reason
```

The backend **does not know** whether it came from single-agent or multi-agent.
It just receives `messages: List[Dict[str, str]]`.

---

## 5. Visual Comparison: One Turn

### Single-Agent (after 2 tool calls)
```
[SYS]  You are an autonomous coding agent...
[USR]  Fix the token estimation bug
[AST]  <tool>{"tool":"read_file",...}</tool>
[USR]  Tool `read_file` returned: {...} [INTERNAL: Continue...]
[AST]  <tool>{"tool":"patch_file",...}</tool>
[USR]  Tool `patch_file` returned: {...} [INTERNAL: Continue...]
[AST]  <tool>{"tool":"python_check",...}</tool>
[USR]  Tool `python_check` returned: {...} [INTERNAL: Continue...]
        ^
        |
    backend.chat(messages=ALL_OF_THE_ABOVE)
```

### Multi-Agent (after 2 tool calls)
```
state.history:
  [USR] Fix the token estimation bug
  [AST] <router> reasoning route
  [USR] <shaped prompt>
  [AST] <reasoner> plan: read_file, patch_file, python_check
  [USR] <executor results summary>

state.tool_results:
  [{read_file result}, {patch_file result}, {python_check result}]

ReasonerAgent.run(state):
  user_block = _compose_user_block(state)
  # = "[Spec]\n<shaped prompt>\n\n[Tool calls + results]\n1. read_file(...) -> {...}\n..."

  messages = _build_messages(user_block, history=state.history)
  # = [
  #     [SYS] You are a reasoning agent...     <-- REASONER prompt
  #     [USR] Fix the token estimation bug
  #     [AST] <router> reasoning route
  #     [USR] <shaped prompt>
  #     [AST] <reasoner> plan: read_file...
  #     [USR] <executor results summary>
  #     [USR] <composed user_block>            <-- CURRENT TURN
  #   ]

  backend.chat(messages=messages)
```

---

## 6. Where Context Gets Lost / Truncated

| Location | Single-Agent | Multi-Agent |
|----------|-------------|-------------|
| **Token budget exceeded** | `trim_history_by_tokens()` drops oldest non-system messages | `compact_if_needed()` elides tool results; `_trim_history()` drops old messages |
| **Tool result too big** | Head+tail truncation at `_max_tool_result_chars` | `_compose_user_block()` keeps only last `_KEEP_FULL_RESULTS` with full bodies |
| **Iteration limit** | `max_iterations` cap (now `while` loop) | `max_iterations` cap + `no_progress_count` circuit breaker |
| **System prompt** | Always first message, never re-added | Re-prepended by every agent call |

---

## 7. Summary Table

| Property | Single-Agent | Multi-Agent |
|----------|-------------|-------------|
| **Entry point** | `Orchestrator.run()` | `Workflow.run()` |
| **History store** | `self.conversation_history` | `state.history` |
| **System prompt** | Once, at index 0 | Rebuilt per agent call |
| **Tool results** | Inline as user messages | In `state.tool_results`, composed per agent |
| **Message builder** | None (pass list directly) | `Agent._build_messages()` |
| **Context trimming** | `trim_history_by_tokens()` | `compact_if_needed()` + `_trim_history()` |
| **Agents** | 1 (monolithic) | 4+ (router, shaper, reasoner, executor, summarizer) |
| **Backend calls** | `self.backend.chat()` | `self._chat()` (wrapper that logs to stderr) |
