import os
import ast

AGENT_DIR = 'bin/agent'

IDENTICAL = [
    'backends/backend_base.py',
    'backends/github_models.py',
    'backends/groq.py',
    'backends/hf.py',
    'backends/openai_compat.py',
    'loop/history.py',
    'loop/run_loop.py',
    'loop/tool_detector.py',
    'policy.py',
    'tools/database.py',
    'tools/flutter.py',
    'tools/fs_read.py',
    'tools/fs_write.py',
    'tools/git.py',
    'tools/python_tools.py',
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

identical_set = set(IDENTICAL)

def resolve_relative_import(module_name, file_rel):
    """Resolve a relative import to a path relative to agent root."""
    parts = file_rel.replace('\\', '/').split('/')
    parts.pop()  # remove filename
    dots = 0
    for c in module_name:
        if c == '.':
            dots += 1
        else:
            break
    rest = module_name[dots:]
    for _ in range(dots - 1):
        if parts:
            parts.pop()
    if rest:
        parts.extend(rest.split('.'))
    return '/'.join(parts) + '.py'

def get_imports(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        try:
            tree = ast.parse(f.read())
        except SyntaxError:
            return []
    imports = []
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            if node.module:
                imports.append(node.module)
    return imports

print("Checking identical files for broken same-directory imports...")
problematic = []
for rel in IDENTICAL:
    filepath = os.path.join(AGENT_DIR, rel)
    imports = get_imports(filepath)
    for imp in imports:
        if imp.startswith('.'):
            resolved = resolve_relative_import(imp, rel)
            if resolved not in identical_set:
                problematic.append((rel, imp, resolved))

if problematic:
    print("\nFiles with imports to non-identical modules:")
    for rel, imp, res in problematic:
        print(f"  {rel}: {imp} -> {res}")
else:
    print("\nAll imports resolve to identical files. Safe to move all.")
