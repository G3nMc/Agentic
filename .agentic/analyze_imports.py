import os
import re
import ast

agent_dir = 'bin/agent'
multi_dir = 'bin/multi_mode'

# Identical files from previous run
identical = [
    'agents/executor.py',
    'agents/reasoner.py',
    'agents/summarizer.py',
    'backends/backend_base.py',
    'backends/gemini.py',
    'backends/github_models.py',
    'backends/groq.py',
    'backends/hf.py',
    'backends/ollama.py',
    'backends/openai_compat.py',
    'backends/openrouter.py',
    'loop/history.py',
    'loop/run_loop.py',
    'loop/tool_detector.py',
    'loop/tool_dispatch.py',
    'path_filter.py',
    'policy.py',
    'tools/database.py',
    'tools/flutter.py',
    'tools/fs_read.py',
    'tools/fs_write.py',
    'tools/git.py',
    'tools/python_tools.py',
    'tools/registry.py',
    'tools/shell.py',
    'tools/web.py',
    'utils/audit.py',
    'utils/bootstrap.py',
    'utils/circuit_breaker.py',
    'utils/io_protocol.py',
    'utils/rate_limit.py',
    'utils/text.py',
    'utils/token_estimator.py',
]

# Non-identical modules (files that exist in one but not both, or are different)
# We'll consider any import that targets a module not in 'identical' as problematic
# if that module is not a standard library.

def get_imports(filepath):
    """Extract imported module names from a Python file."""
    with open(filepath, 'r', encoding='utf-8') as f:
        try:
            tree = ast.parse(f.read())
        except SyntaxError:
            return []
    imports = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imports.append(alias.name)
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                imports.append(node.module)
    return imports

def is_relative_to_package(module_name):
    """Check if a module name is relative (starts with .)"""
    return module_name.startswith('.')

def resolve_relative_import(module_name, file_rel):
    """Resolve a relative import to an absolute path within the project."""
    # file_rel is like 'agents/executor.py'
    # module_name is like '..core.state'
    parts = file_rel.replace('\\', '/').split('/')
    # Remove filename
    parts.pop()  # remove filename
    # Count dots
    dots = 0
    for c in module_name:
        if c == '.':
            dots += 1
        else:
            break
    rest = module_name[dots:]
    # Go up 'dots' levels
    for _ in range(dots - 1):
        if parts:
            parts.pop()
    # Append the rest
    if rest:
        parts.extend(rest.split('.'))
    return '/'.join(parts) + '.py'

# Build set of identical module paths for quick lookup
identical_set = set(identical)

print("Files with imports from non-identical modules:")
for rel in identical:
    filepath = os.path.join(agent_dir, rel)
    imports = get_imports(filepath)
    problematic = []
    for imp in imports:
        if is_relative_to_package(imp):
            resolved = resolve_relative_import(imp, rel)
            if resolved not in identical_set:
                problematic.append((imp, resolved))
    if problematic:
        print(f"\n{rel}:")
        for imp, res in problematic:
            print(f"  {imp} -> {res}")
