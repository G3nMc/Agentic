import os
import filecmp

agent_dir = 'bin/agent'
multi_dir = 'bin/multi_mode'

identical = []
different = []
only_agent = []
only_multi = []

agent_files = set()
multi_files = set()

for r, ds, fs in os.walk(agent_dir):
    for f in fs:
        rel = os.path.relpath(os.path.join(r, f), agent_dir)
        agent_files.add(rel)

for r, ds, fs in os.walk(multi_dir):
    for f in fs:
        rel = os.path.relpath(os.path.join(r, f), multi_dir)
        multi_files.add(rel)

common_names = agent_files & multi_files
only_agent = sorted(agent_files - multi_files)
only_multi = sorted(multi_files - agent_files)

for p in sorted(common_names):
    ap = os.path.join(agent_dir, p)
    mp = os.path.join(multi_dir, p)
    if filecmp.cmp(ap, mp, shallow=False):
        identical.append(p)
    else:
        different.append(p)

print('IDENTICAL:')
for p in identical:
    print(f'  {p}')
print('DIFFERENT:')
for p in different:
    print(f'  {p}')
print('ONLY AGENT:')
for p in only_agent:
    print(f'  {p}')
print('ONLY MULTI:')
for p in only_multi:
    print(f'  {p}')
