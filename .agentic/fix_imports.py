import os
import re

AGENT_DIR = 'bin/agent'
MULTI_DIR = 'bin/multi_mode'

# Identical files that were moved
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

# Build a set of moved module names
moved_modules = set()
for rel in IDENTICAL:
    module = rel.replace('/', '.').replace('\\', '.').replace('.py', '')
    moved_modules.add(module)

# Also build a set of just the filenames without extension for same-directory matching
moved_names = set()
for rel in IDENTICAL:
    name = os.path.splitext(os.path.basename(rel))[0]
    moved_names.add(name)


def update_imports_in_file(filepath):
    if not os.path.exists(filepath):
        return
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    original = content

    # Determine which package this file is in (agent or multi_mode)
    # We need to know the package to compute the correct relative path to common.
    # Since common is at bin/common, and the file is at bin/agent/backends/gemini.py,
    # the import should be: from bin.common.backends.backend_base import ...
    # We'll use absolute imports for same-directory moved modules.

    # Pattern: from .<name> import ...
    def replace_dot_import(match):
        name = match.group(1)
        if name in moved_names:
            # Find the full module path for this name
            # We need to know which package this name belongs to.
            # Look up in moved_modules
            for mod in moved_modules:
                if mod.endswith('.' + name):
                    return f'from bin.common.{mod} import '
        return match.group(0)

    pattern_dot = re.compile(r'from \.(\w+) import ')
    content = pattern_dot.sub(replace_dot_import, content)

    # Pattern: from ..<pkg>.<module> import ...
    def replace_dotdot_import(match):
        pkg = match.group(1)
        mod = match.group(2)
        full = f'{pkg}.{mod}'
        if full in moved_modules:
            return f'from bin.common.{full} import '
        return match.group(0)

    pattern_dotdot = re.compile(r'from \.\.(backends|loop|tools|utils)\.(\w+) import ')
    content = pattern_dotdot.sub(replace_dotdot_import, content)

    # Pattern: from ..policy import ...
    if 'policy.py' in IDENTICAL:
        pattern_policy = re.compile(r'from \.\.policy import ')
        content = pattern_policy.sub('from bin.common.policy import ', content)

    # Pattern: from ..<pkg> import <name>
    def replace_dotdot_pkg_import(match):
        pkg = match.group(1)
        imported = match.group(2)
        first_name = imported.split(',')[0].strip().split(' as ')[0].strip()
        full = f'{pkg}.{first_name}'
        if full in moved_modules:
            return f'from bin.common.{pkg} import {imported}'
        return match.group(0)

    pattern_dotdot_pkg = re.compile(r'from \.\.(backends|loop|tools|utils) import (\S+)')
    content = pattern_dotdot_pkg.sub(replace_dotdot_pkg_import, content)

    if content != original:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f'Updated: {filepath}')


def update_all():
    for root, dirs, files in os.walk(AGENT_DIR):
        for f in files:
            if f.endswith('.py'):
                update_imports_in_file(os.path.join(root, f))
    for root, dirs, files in os.walk(MULTI_DIR):
        for f in files:
            if f.endswith('.py'):
                update_imports_in_file(os.path.join(root, f))


if __name__ == '__main__':
    update_all()
    print('Done.')
