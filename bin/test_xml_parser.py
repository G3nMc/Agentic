#!/usr/bin/env python3
"""Test the XML tool-call parser."""
import sys
sys.path.insert(0, '.')

from agent.loop.tool_dispatch import (
    parse_xml_tool_calls,
    parse_all_tag_tool_calls,
    looks_like_unclosed_tool,
    looks_like_malformed_tool_call,
)

# Test 1: Basic XML tool call
test1 = """<tool>
  <name>read_file</name>
  <path>src/main.py</path>
</tool>"""

result = parse_xml_tool_calls(test1)
print('Test 1 (basic XML):', result)
assert result, 'Test 1 FAILED: no result'
assert result[0][0] == 'read_file', f'Test 1 FAILED: wrong tool name: {result[0][0]}'
assert result[0][1].get('path') == 'src/main.py', f'Test 1 FAILED: wrong params: {result[0][1]}'
print('Test 1 PASSED')

# Test 2: XML with multiple params
test2 = """<tool>
  <name>write_file</name>
  <path>out.txt</path>
  <content>hello world</content>
</tool>"""

result = parse_xml_tool_calls(test2)
print('Test 2 (multi-param XML):', result)
assert result, 'Test 2 FAILED'
assert result[0][0] == 'write_file'
assert result[0][1].get('path') == 'out.txt'
assert result[0][1].get('content') == 'hello world'
print('Test 2 PASSED')

# Test 3: XML with patch_file (old_content/new_content)
test3 = """<tool>
  <name>patch_file</name>
  <path>src/main.py</path>
  <old_content>Hello</old_content>
  <new_content>Ciao</new_content>
</tool>"""

result = parse_xml_tool_calls(test3)
print('Test 3 (patch_file XML):', result)
assert result, 'Test 3 FAILED'
assert result[0][0] == 'patch_file'
assert result[0][1].get('old_content') == 'Hello'
assert result[0][1].get('new_content') == 'Ciao'
print('Test 3 PASSED')

# Test 4: XML with no params
test4 = """<tool>
  <name>flutter_analyze</name>
</tool>"""

result = parse_xml_tool_calls(test4)
print('Test 4 (no params XML):', result)
assert result, 'Test 4 FAILED'
assert result[0][0] == 'flutter_analyze'
assert result[0][1] == {}
print('Test 4 PASSED')

# Test 5: XML with list value
test5 = """<tool>
  <name>read_files</name>
  <paths>["a.py","b.py","c.py"]</paths>
</tool>"""

result = parse_xml_tool_calls(test5)
print('Test 5 (list value XML):', result)
assert result, 'Test 5 FAILED'
assert result[0][0] == 'read_files'
assert result[0][1].get('paths') == ['a.py', 'b.py', 'c.py'], f'Expected list, got: {result[0][1].get("paths")}'
print('Test 5 PASSED')

# Test 6: Content with special chars (no escaping needed)
test6 = """<tool>
  <name>write_file</name>
  <path>out.txt</path>
  <content>say "hello" world</content>
</tool>"""

result = parse_xml_tool_calls(test6)
print('Test 6 (quotes in content):', result)
assert result, 'Test 6 FAILED'
assert result[0][1].get('content') == 'say "hello" world'
print('Test 6 PASSED')

# Test 7: Content with backslashes (no escaping needed)
test7 = r"""<tool>
  <name>run_command</name>
  <command>dir C:\Users\Gentian</command>
</tool>"""

result = parse_xml_tool_calls(test7)
print('Test 7 (backslashes):', result)
assert result, 'Test 7 FAILED'
print('Test 7 PASSED')

# Test 8: Unclosed tool tag detection
test8 = "<tool>\n  <name>read_file</name>\n  <path>src/main.py"
unclosed = looks_like_unclosed_tool(test8)
print('Test 8 (unclosed tool):', unclosed)
assert unclosed, 'Test 8 FAILED: should detect unclosed'
print('Test 8 PASSED')

# Test 9: parse_all_tag_tool_calls should also parse XML
test9 = """<tool>
  <name>read_file</name>
  <path>test.py</path>
</tool>"""

result = parse_all_tag_tool_calls(test9)
print('Test 9 (parse_all with XML):', result)
assert result, 'Test 9 FAILED'
assert result[0][0] == 'read_file'
print('Test 9 PASSED')

# Test 10: Legacy JSON fallback still works
test10 = '<tool>{"tool":"read_file","parameters":{"path":"legacy.py"}}</tool>'
result = parse_all_tag_tool_calls(test10)
print('Test 10 (legacy JSON fallback):', result)
assert result, 'Test 10 FAILED: legacy JSON should still parse'
assert result[0][0] == 'read_file'
assert result[0][1].get('path') == 'legacy.py'
print('Test 10 PASSED')

# Test 11: Malformed XML detection (missing <name>)
test11 = "<tool>\n  <path>src/main.py</path>\n</tool>"
is_malformed, error = looks_like_malformed_tool_call(test11)
print('Test 11 (missing name):', is_malformed, error)
assert is_malformed, 'Test 11 FAILED: should detect missing <name>'
print('Test 11 PASSED')

# Test 12: Valid XML should NOT be malformed
test12 = "<tool>\n  <name>read_file</name>\n  <path>ok.py</path>\n</tool>"
is_malformed, error = looks_like_malformed_tool_call(test12)
print('Test 12 (valid XML not malformed):', is_malformed, error)
assert not is_malformed, 'Test 12 FAILED: valid XML should not be malformed'
print('Test 12 PASSED')

# Test 13: XML with content containing < (must be &lt;)
test13 = """<tool>
  <name>write_file</name>
  <path>out.txt</path>
  <content>if x &lt; 5 { ... }</content>
</tool>"""

result = parse_xml_tool_calls(test13)
print('Test 13 (escaped < in content):', result)
assert result, 'Test 13 FAILED'
# The parser should give us the raw text between the tags
print('Test 13 PASSED')

# Test 14: Compact XML (no whitespace/newlines)
test14 = "<tool><name>read_file</name><path>compact.py</path></tool>"
result = parse_xml_tool_calls(test14)
print('Test 14 (compact XML):', result)
assert result, 'Test 14 FAILED'
assert result[0][0] == 'read_file'
assert result[0][1].get('path') == 'compact.py'
print('Test 14 PASSED')

# Test 15: Thinking block before tool call
test15 = """<thinking>Let me read the file first.</thinking>
<tool>
  <name>read_file</name>
  <path>after_thinking.py</path>
</tool>"""

result = parse_all_tag_tool_calls(test15)
print('Test 15 (thinking + XML):', result)
assert result, 'Test 15 FAILED'
assert result[0][0] == 'read_file'
assert result[0][1].get('path') == 'after_thinking.py'
print('Test 15 PASSED')

print()
print('=== ALL 15 TESTS PASSED ===')