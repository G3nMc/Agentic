

## How Custom Tools Work

The agent's tool system lives in `bin/agent/tools/`. It uses a **registry pattern** — each tool module defines a `register(registry)` function that adds its tools to a `ToolRegistry` instance.

### Step-by-step: Adding a New Custom Tool

**1. Create a new Python file** in `bin/agent/tools/`, e.g. `bin/agent/tools/my_tools.py`:

```python
"""My custom tools."""
from __future__ import annotations
import json

def register(registry) -> None:

    def my_custom_tool(param1: str, param2: int = 10) -> str:
        """Your tool logic here."""
        try:
            # Do your work — registry.base_path gives you the project root
            result = f"Processed {param1} with {param2}"
            return json.dumps({"status": "success", "result": result})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    # Register the callable under a tool name
    registry.tools["my_custom_tool"] = my_custom_tool

    # Append an OpenAPI-style function definition (this is what the LLM sees)
    registry.definitions.append({
        "type": "function",
        "function": {
            "name": "my_custom_tool",
            "description": "Describe what the tool does — the LLM uses this to decide when to call it.",
            "parameters": {
                "type": "object",
                "properties": {
                    "param1": {"type": "string", "description": "What param1 means"},
                    "param2": {"type": "integer", "description": "What param2 means"},
                },
                "required": ["param1"],
            },
        },
    })
```

**2. Register it in `bin/agent/tools/__init__.py`** by adding two lines to `collect_all_tools()`:

```python
def collect_all_tools(registry) -> None:
    from . import fs_read, fs_write, shell, git, flutter, python_tools
    from . import my_tools          # ← add import
    fs_read.register(registry)
    fs_write.register(registry)
    shell.register(registry)
    git.register(registry)
    flutter.register(registry)
    python_tools.register(registry)
    my_tools.register(registry)     # ← add registration call
```

**3. That's it.** The next time the orchestrator starts, `ToolRegistry.__init__` calls `collect_all_tools(self)`, which will pick up your new tool. The tool's name, description, and parameter schema automatically appear in the system prompt under the "AVAILABLE TOOLS" section, and the LLM can call it via the `` protocol.

---

## Key Details from the Codebase

| Aspect | Detail |
|--------|--------|
| **Tool function signature** | Any callable that accepts keyword arguments matching your `parameters` schema. Must return a JSON string. |
| **Path safety** | `registry.resolve_path(path)` confines file access to the project root. Use it for any path parameters. |
| **Security** | `registry.security_config` exposes `sandbox_mode` and `command_blocklist`. Check these if your tool runs external commands. |
| **Circuit breaker** | Built-in per-tool. If a tool fails 5 times in a row, it's temporarily disabled for 30 seconds. |
| **Audit logging** | Every `execute()` call is automatically audit-logged — you don't need to add logging yourself. |
| **Tool grouping** | The system prompt auto-groups tools by name prefix: `git_*` → Git, `flutter_*` → Flutter, `python_*` → Python, `run_command` → Shell, etc. Custom names that don't match a known prefix appear under "Other". |
| **Definition format** | Must follow the OpenAPI function-calling schema (`type: "function"`, `function.name`, `function.parameters`). This is what the LLM sees to decide when/how to call your tool. |

---

## Existing Tool Modules as Reference

| File | Tools registered |
|------|-----------------|
| `fs_read.py` | `read_file`, `list_files`, `list_files_recursive`, `search_in_files`, `find_files` |
| `fs_write.py` | `write_file`, `append_file`, `delete_file`, `patch_file`, `move_file`, `create_directory` |
| `shell.py` | `run_command` |
| `git.py` | `git_status`, `git_branches`, `git_log`, `git_diff`, `git_checkout`, `git_commit` |
| `flutter.py` | `flutter_analyze` |
| `python_tools.py` | `python_check`, `python_lint`, `python_format`, `python_test` |

Each follows the exact same pattern shown above — define the function, add it to `registry.tools`, append the definition to `registry.definitions`.