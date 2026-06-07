import os
import shutil
import re

AGENT_DIR = 'bin/agent'
MULTI_DIR = 'bin/multi_mode'
COMMON_DIR = 'bin/common'

# Identical files (relative paths) - verified safe to move
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

SUBDIRS = ['backends', 'loop', 'tools', 'utils']


def create_common_structure():
    os.makedirs(COMMON_DIR, exist_ok=True)
    with open(os.path.join(COMMON_DIR, '__init__.py'), 'w') as f:
        f.write('"""Common shared modules for agent and multi_mode."""\n')
    for sub in SUBDIRS:
        subdir = os.path.join(COMMON_DIR, sub)
        os.makedirs(subdir, exist_ok=True)
        with open(os.path.join(subdir, '__init__.py'), 'w') as f:
            f.write(f'"""Common {sub} package."""\n')
    print('Created common directory structure.')


def move_files():
    for rel in IDENTICAL:
        src = os.path.join(AGENT_DIR, rel)
        dst = os.path.join(COMMON_DIR, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
        os.remove(src)
        multi_src = os.path.join(MULTI_DIR, rel)
        if os.path.exists(multi_src):
            os.remove(multi_src)
        print(f'Moved: {rel}')


def update_imports_in_file(filepath):
    if not os.path.exists(filepath):
        return
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    original = content

    # Pattern for: from ..<pkg>.<module> import ...
    # We only replace imports that target moved modules.
    # Moved packages: backends, loop, tools, utils, plus root-level policy
    # But we must be careful: some files in these packages are NOT moved
    # (e.g., backends/gemini.py, loop/tool_dispatch.py, tools/registry.py).
    # We should only replace imports for the specific moved modules.

    # Build a set of moved module paths for lookup
    moved_modules = set()
    for rel in IDENTICAL:
        # Convert to module path: backends/backend_base.py -> backends.backend_base
        module = rel.replace('/', '.').replace('\\', '.').replace('.py', '')
        moved_modules.add(module)

    # Pattern 1: from ..<pkg>.<module> import ...
    def replace_import1(match):
        full_module = match.group(1) + '.' + match.group(2)
        if full_module in moved_modules:
            return f'from bin.common.{full_module} import '
        else:
            return match.group(0)

    pattern1 = re.compile(
        r'from \.\.(backends|loop|tools|utils)\.(\w+)\s+import\s+'
    )
    content = pattern1.sub(replace_import1, content)

    # Pattern 2: from ..policy import ... (root-level)
    if 'policy.py' in IDENTICAL:
        pattern2 = re.compile(r'from \.\.policy\s+import\s+')
        content = pattern2.sub('from bin.common.policy import ', content)

    # Pattern 3: from ..<pkg> import <name> (importing a module directly)
    def replace_import3(match):
        pkg = match.group(1)
        imported = match.group(2)
        # Check if the imported name is a moved module in that package
        # imported might be like "history as hm" or "history, tool_detector"
        first_name = imported.split(',')[0].strip().split(' as ')[0].strip()
        module_path = f'{pkg}.{first_name}'
        if module_path in moved_modules:
            return f'from bin.common.{pkg} import {imported}'
        else:
            return match.group(0)

    pattern3 = re.compile(
        r'from \.\.(backends|loop|tools|utils)\s+import\s+(\S+)'
    )
    content = pattern3.sub(replace_import3, content)

    if content != original:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f'Updated imports in: {filepath}')


def update_all_imports():
    # Walk agent remaining files
    for root, dirs, files in os.walk(AGENT_DIR):
        for f in files:
            if f.endswith('.py'):
                filepath = os.path.join(root, f)
                update_imports_in_file(filepath)
    # Walk multi_mode remaining files
    for root, dirs, files in os.walk(MULTI_DIR):
        for f in files:
            if f.endswith('.py'):
                filepath = os.path.join(root, f)
                update_imports_in_file(filepath)


if __name__ == '__main__':
    create_common_structure()
    move_files()
    update_all_imports()
    print('Done.')
