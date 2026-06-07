import os
import ast

COMMON_DIR = 'bin/common'

# All files in common
common_files = []
for root, dirs, files in os.walk(COMMON_DIR):
    for f in files:
        if f.endswith('.py') and f != '__init__.py':
            rel = os.path.relpath(os.path.join(root, f), COMMON_DIR)
            common_files.append(rel)

common_set = set(common_files)

def resolve_relative_import(module_name, file_rel):
    parts = file_rel.replace('\\', '/').split('/')
    parts.pop()
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

print("Checking common files for broken internal imports...")
problematic = []
for rel in common_files:
    filepath = os.path.join(COMMON_DIR, rel)
    imports = get_imports(filepath)
    for imp in imports:
        if imp.startswith('.'):
            resolved = resolve_relative_import(imp, rel)
            if resolved not in common_set:
                problematic.append((rel, imp, resolved))

if problematic:
    print("\nFiles with imports to non-common modules:")
    for rel, imp, res in problematic:
        print(f"  {rel}: {imp} -> {res}")
else:
    print("\nAll internal imports resolve within common. Good!")
