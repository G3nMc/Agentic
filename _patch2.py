data = open('bin/agent/tools/registry.py', 'r', encoding='utf-8').read()

old = '            "- When you need to read multiple files at once, use read_files instead of making separate read_file calls for each one. This saves iterations and context.",'

new_lines = [
    '            "- PREFER BATCHED READING: When you need to read 2 or more files, ALWAYS use read_files with a list of paths instead of calling read_file multiple times. read_files reads all files in a single tool call, saving iterations and context window space. For example, instead of:",',
    '',
    '            \'    <tool>{"tool":"read_file","parameters":{"path":"a.py"}}</tool>\',',
    '',
    '            "    then",',
    '',
    '            \'    <tool>{"tool":"read_file","parameters":{"path":"b.py"}}</tool>\',',
    '',
    '            "    then",',
    '',
    '            \'    <tool>{"tool":"read_file","parameters":{"path":"c.py"}}</tool>\',',
    '',
    '            "  DO THIS IN ONE CALL:",',
    '',
    '            \'    <tool>{"tool":"read_files","parameters":{"paths":["a.py","b.py","c.py"]}}</tool>\',',
    '',
    '            "- The ONLY time you should call read_file instead of read_files is when you need exactly ONE file, or when you need start_line/end_line/offset/limit for a specific section of a large file.",',
]

new = '\n'.join(new_lines)

count = data.count(old)
print(f'Found {count} occurrences')

data = data.replace(old, new)

open('bin/agent/tools/registry.py', 'w', encoding='utf-8').write(data)
print('Done')
