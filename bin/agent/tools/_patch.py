import os

# Find the project root by looking for the registry file
paths_to_try = ["registry.py", "bin/agent/tools/registry.py"]
registry_path = None
for p in paths_to_try:
    if os.path.exists(p):
        registry_path = p
        break

if not registry_path:
    print("ERROR: registry.py not found")
    exit(1)

print(f"Found registry at: {registry_path}")

data = open(registry_path, "r", encoding="utf-8").read()

old = "- When you need to read multiple files at once, use read_files instead of making separate read_file calls for each one. This saves iterations and context."

old_formatted = f'            "{old}",'

count = data.count(old_formatted)
print(f"Found {count} formatted occurrences of old text")

if count == 0:
    print("No occurrences found - may already be patched")
    exit(0)

new_lines = [
    '            "- PREFER BATCHED READING: When you need to read 2 or more files, ALWAYS use read_files with a list of paths instead of calling read_file multiple times. read_files reads all files in a single tool call, saving iterations and context window space. For example, instead of:",',
    "",
    '            \'    <tool>{"tool":"read_file","parameters":{"path":"a.py"}}</tool>\',',
    "",
    '            "    then",',
    "",
    '            \'    <tool>{"tool":"read_file","parameters":{"path":"b.py"}}</tool>\',',
    "",
    '            "    then",',
    "",
    '            \'    <tool>{"tool":"read_file","parameters":{"path":"c.py"}}</tool>\',',
    "",
    '            "  DO THIS IN ONE CALL:",',
    "",
    '            \'    <tool>{"tool":"read_files","parameters":{"paths":["a.py","b.py","c.py"]}}</tool>\',',
    "",
    '            "- The ONLY time you should call read_file instead of read_files is when you need exactly ONE file, or when you need start_line/end_line/offset/limit for a specific section of a large file.",',
]

new_formatted = "\n".join(new_lines)

data = data.replace(old_formatted, new_formatted)
open(registry_path, "w", encoding="utf-8").write(data)
print("Replaced successfully")
