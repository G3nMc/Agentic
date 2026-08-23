"""Pure helpers for parsing tool calls out of model replies.

All functions here are stateless and module-level so they can be called
from the run loop without dragging the Orchestrator class along.

PRIMARY FORMAT (XML, no attributes):
    <tool>
      <name>read_file</name>
      <path>src/main.py</path>
    </tool>

    <tool>
      <name>write_file</name>
      <path>out.txt</path>
      <content>hello world</content>
    </tool>

The parser extracts child tags inside <tool>...</tool> as key/value pairs.
The first <name>...</name> child is the tool name; all other children are
parameters.  Values are taken verbatim (no JSON escaping, no attribute
parsing) — the tag body IS the value.

Legacy JSON-in-tags calls (<tool>{"tool":"...","parameters":{...}}</tool>)
and bare JSON are kept as a fallback for backward compatibility with older
conversation history.
"""

from __future__ import annotations

import ast
import json
import re
import sys
from html import unescape as _html_unescape
from typing import Any, Dict, List, Optional, Tuple

from agent.loop.task_protocol import strip_task_tags


def _sanitize_xml_value(value: str) -> str:
    """Decode HTML entities inside an XML tag body.

    Models often emit ``&lt;``, ``&gt;``, ``&amp;``, ``&quot;``,
    ``&apos;``, ``&#60;``, ``&#x3C;``, etc. inside tool parameters
    because the tool-call format is XML-like.  This helper turns those
    entities back into the real characters so that code such as
    ``a &gt; b`` becomes ``a > b`` before it is written to a file or
    executed as a command.

    Double-escaped entities (e.g. ``&amp;gt;``) are decoded iteratively
    up to a small limit, because models sometimes escape the ``&``
    character itself when trying to escape ``<``/``>``.

    The function always runs; the presence of ``&`` is only an
    optimisation, not a guard, because callers must never forget to
    sanitize a tag value.
    """
    if not isinstance(value, str):
        return value
    if "&" not in value:
        return value

    # Iterative unescape to handle double-encoded entities such as
    # &amp;gt; (&gt; after one round, > after two).  Cap the iterations so an
    # intentionally pathological string cannot loop forever.
    for _ in range(3):
        new_value = _html_unescape(value)
        if new_value == value:
            break
        value = new_value
        if "&" not in value:
            break
    return value


# ---------------------------------------------------------------------------
# PRIMARY PARSER — pure XML child-tag format (no attributes)
# ---------------------------------------------------------------------------
#
#   <tool>
#     <name>read_file</name>
#     <path>src/main.py</path>
#   </tool>
#
# The tool name comes from the <name> child. Every other child tag is a
# parameter whose value is the literal text between the open/close tags.
# No attributes, no JSON, no escaping. The body IS the value.

_TOOL_BLOCK_RE = re.compile(
    r"<tool\b[^>]*>(.*?)</tool\s*>",
    re.DOTALL | re.IGNORECASE,
)

# Match <name>...</name> as the first child inside <tool>
_XML_NAME_RE = re.compile(
    r"<name\b[^>]*>(.*?)</name\s*>",
    re.DOTALL | re.IGNORECASE,
)

# Match any child tag: <tagname>value</tagname>
# We exclude <name> since it's the tool name, not a parameter.
_XML_CHILD_TAG_RE = re.compile(
    r"<(\w+)\s*>(.*?)</\1\s*>",
    re.DOTALL | re.IGNORECASE,
)

import re


import re


def _clean_dirty_tool_tag(tag: str) -> str:
    """Normalize malformed XML-like tool tags, including broken closing tags."""

    if not tag:
        return tag

    known_tags = {
        "name",
        "path",
        "content",
        "line",
        "start_line",
        "end_line",
        "pattern",
        "query",
        "file",
        "directory",
        "filename",
        "command",
        "input",
        "value",
        "text",
        "url",
    }

    # Remove markdown fences if the model wrapped the tool in one.
    tag = re.sub(r"```(?:[a-zA-Z0-9_+\-]+)?\s*", "", tag)
    tag = re.sub(r"\s*```", "", tag)

    # Fix malformed tags such as:
    # <name=read_file>
    # <name = read_file>
    # <name="read_file">
    # <name='read_file'>
    # <path=Client/lib/presentation>
    # <line=42>
    #
    # Also fixes the form seen in the log:
    # <name=list_files_recursive</name>
    # <path=Client/lib/presentation
    #
    # The latter is handled separately below because the closing tag is
    # effectively being used as part of the malformed opening tag.
    malformed_equal_re = re.compile(
        r"<([a-zA-Z_][a-zA-Z0-9_-]*)\s*=\s*"
        r"(?:\"([^\"]*)\"|'([^']*)'|([^<>]*?))"
        r"\s*>"
    )

    def replace_equal(match: re.Match) -> str:
        name = match.group(1)

        if name.lower() not in known_tags:
            return match.group(0)

        value = (
            match.group(2)
            if match.group(2) is not None
            else match.group(3)
            if match.group(3) is not None
            else match.group(4)
        )

        value = value.strip()

        return f"<{name}>{value}</{name}>"

    previous = None
    while previous != tag:
        previous = tag
        tag = malformed_equal_re.sub(replace_equal, tag)

    # Fix malformed form from the log:
    # <name=list_files_recursive</name>
    # -> <name>list_files_recursive</name>
    #
    # Also:
    # <path=Client/lib/presentation</path>
    # -> <path>Client/lib/presentation</path>
    malformed_equal_with_close_re = re.compile(
        r"<([a-zA-Z_][a-zA-Z0-9_-]*)\s*=\s*"
        r"([^<>]*?)"
        r"</\1\s*>",
        re.DOTALL | re.IGNORECASE,
        )

    def replace_equal_with_close(match: re.Match) -> str:
        name = match.group(1)

        if name.lower() not in known_tags:
            return match.group(0)

        value = match.group(2).strip()

        return f"<{name}>{value}</{name}>"

    previous = None
    while previous != tag:
        previous = tag
        tag = malformed_equal_with_close_re.sub(
            replace_equal_with_close,
            tag,
        )

    # Fix a very common truncation seen in the log:
    #
    # <path>Client/lib/presentation </tool>
    #
    # -> <path>Client/lib/presentation</path></tool>
    #
    # This is intentionally restricted to known parameter tags so that
    # </tool> is not accidentally treated as content for arbitrary XML.
    for name in known_tags:
        pattern = re.compile(
            rf"<{re.escape(name)}>\s*(.*?)\s*</tool>",
            re.DOTALL | re.IGNORECASE,
            )

        def repair_missing_close(match: re.Match, name=name) -> str:
            value = match.group(1).strip()

            # Do not rewrite an already valid parameter.
            if f"</{name}>" in value.lower():
                return match.group(0)

            return f"<{name}>{value}</{name}></tool>"

        tag = pattern.sub(repair_missing_close, tag)

    # Remove duplicate closing </tool> tags:
    # </tool></tool> -> </tool>
    # </tool> </tool> -> </tool>
    tag = re.sub(
        r"(?:\s*</tool>\s*){2,}",
        "</tool>",
        tag,
        flags=re.IGNORECASE,
    )

    # Normalize whitespace around important values.
    for name in known_tags:
        pattern = re.compile(
            rf"<{re.escape(name)}>\s*(.*?)\s*</{re.escape(name)}>",
            re.DOTALL | re.IGNORECASE,
            )

        def strip_value(match: re.Match, name=name) -> str:
            return f"<{name}>{match.group(1).strip()}</{name}>"

        tag = pattern.sub(strip_value, tag)

    return tag.strip()



def parse_tool_call(block_body: str, tool_defs=None) -> Optional[Tuple[str, Dict[str, Any]]]:
    """Parse one <tool> block body (the inner XML) into (name, params).

    The body looks like:
        <name>read_file</name>
        <path>src/main.py</path>

    No attributes. No JSON. Tag body is the literal value.
    """
    if not block_body or not block_body.strip():
        return None

    # Clean typical model artifacts: leading/trailing whitespace, tabs, and 
    # carriage returns that might interfere with regex or parsing.
    block_body = block_body.replace('\n', '').replace('\r', '').strip()

    # FIX: Some models wrap the content inside <tool> tags with markdown code fences
    # e.g., <tool> ```html <name>tool_name</name>... </tool> ```
    # We strip these fences and any language identifiers (like 'html', 'xml') 
    # so the XML parser can find the tags.
    block_body = re.sub(r"```[a-zA-Z]*\s*", "", block_body)
    block_body = block_body.replace("```", "").strip()

    #For stupid models that hallucinates continuosly
    block_body = _clean_dirty_tool_tag(block_body)

    # Extract tool name
    name_match = _XML_NAME_RE.search(block_body)
    if not name_match:
        return None

    tool_name = name_match.group(1).strip()
    if not tool_name:
        return None

    params: Dict[str, Any] = {}
    for m in _XML_CHILD_TAG_RE.finditer(block_body):
        tag_name = m.group(1).lower()

        if tag_name == "name":
            continue

        # Clean the value: remove trailing/leading whitespace and 
        # specific noise characters (like trailing newlines/tabs) 
        # that models often leave inside the tag.
        raw_value = m.group(2)
        value = _sanitize_xml_value(raw_value).strip()

        # Try to parse as JSON for complex types (lists, ints, bools);
        # if it fails, keep the raw string. This handles <paths>["a.py","b.py"]</paths>
        # while keeping <content>hello "world"</content> as a literal string.
        parsed_value = _maybe_parse_scalar(value)
        params[tag_name] = parsed_value

    if not tool_name:
        return None

    if tool_defs:
        params = _sanitize_params(params, tool_name, tool_defs)

    return tool_name, params


def parse_xml_tool_calls(
        response: str, tool_defs=None
) -> List[Tuple[str, Dict[str, Any]]]:
    """Parse XML-format tool calls from the model reply.

    Supports both complete:
        <tool>
          <name>read_file</name>
          <path>src/main.py</path>
        </tool>

    and truncated:
        <tool>
          <name>read_file</name>
          <path>src/main.py</path>

    Returns the first successfully parsed call.
    """
    if not response or not response.strip():
        return []

    # Clean typical model artifacts: leading/trailing whitespace, tabs, and
    # carriage returns that might interfere with regex or parsing.
    response = response.replace('\n', '').replace('\r', '').strip()

    # response = """We need to read file with line numbers.<tool>
    #             <name>read_file</name>
    #             <path>lib/common/session_changer.dart</path>"""

    cleaned = _CODE_BLOCK_RE.sub("", response)

    # Complete <tool>...</tool> blocks.
    for m in _TOOL_BLOCK_RE.finditer(cleaned):
        body = m.group(1)
        result = parse_tool_call(body, tool_defs)
        if result is not None:
            return [result]

    # Handle an incomplete <tool> block without </tool>.
    start = cleaned.find("<tool>")
    if start != -1:
        body = cleaned[start + len("<tool>"):]

        result = parse_tool_call(body, tool_defs)
        if result is not None:
            return [result]

    return []


# def parse_xml_tool_calls(
#         response: str, tool_defs=None
# ) -> List[Tuple[str, Dict[str, Any]]]:
#     """Parse XML-format tool calls from the model reply.
#
#     Primary format (no attributes):
#         <tool>
#           <name>read_file</name>
#           <path>src/main.py</path>
#         </tool>
#
#     Returns a list but stops at the FIRST successfully-parsed call
#     (same semantics as parse_all_tag_tool_calls).
#     """
#     if not response:
#         return []
#
#     response= """We need to read file with line numbers.<tool>
#                 <name>read_file</name>
#                 <path>lib/common/session_changer.dart</path>"""
#     # Strip markdown code blocks first (same as the JSON path)
#     cleaned = _CODE_BLOCK_RE.sub("", response)
#
#     for m in _TOOL_BLOCK_RE.finditer(cleaned):
#         body = m.group(1)
#         result = _parse_xml_tool_call(body, tool_defs)
#         if result is not None:
#             return [result]
#
#     return []


# ---------------------------------------------------------------------------
# Output-cleaning regexes
# ---------------------------------------------------------------------------

JUNK_TAG_PATTERN = re.compile(
    r"</?(?:plaintext|pre|code|html|body|p|span|div|tool|tool_call|function_call|function|parameter|parameters|arg_key|arg_value|arg_name)\b[^>]*>",
    re.IGNORECASE,
)

CHAT_TEMPLATE_TOKEN_PATTERN = re.compile(r"<\|[^|>]{0,80}\|>")

# ---------------------------------------------------------------------------
# Universal "thinking" / chain-of-thought detection
# ---------------------------------------------------------------------------
#
# Every modern reasoning model leaks chain-of-thought into the visible
# reply in one of two shapes:
#
#   (a) Delimited block. The model wraps its planning in known tags:
#         <think>...</think>          (DeepSeek-R1, Qwen3-reasoning)
#         <thinking>...</thinking>    (Anthropic extended thinking)
#         <reasoning>...</reasoning>  (generic)
#         <|reasoning|>...<|/reasoning|>  (chat-template variants)
#         <analysis>...</analysis>    (some custom finetunes)
#
#   (b) Plain-text preamble before the structured deliverable. Models
#       like ``gpt-oss-*`` and some Llama / Phi finetunes emit
#       sentences such as "We need to read the file." right before
#       the ``<tool>{...}</tool>`` call -- no delimiters at all. Per
#       the orchestrator's tool protocol (the prompt mandates "emit
#       ONLY the tool call"), anything before ``<tool>`` is by
#       definition reasoning that leaked through.
#
# ``extract_thinking`` recognises both shapes. New tag formats can be
# added by appending to ``_THINKING_TAG_PATTERNS`` -- there is no
# model-specific code anywhere else.

_THINKING_TAG_PATTERNS = (
    re.compile(r"<think>(.*?)</think>", re.DOTALL | re.IGNORECASE),
    re.compile(r"<thinking>(.*?)</thinking>", re.DOTALL | re.IGNORECASE),
    re.compile(r"<reasoning>(.*?)</reasoning>", re.DOTALL | re.IGNORECASE),
    re.compile(r"<\|reasoning\|>(.*?)<\|/reasoning\|>", re.DOTALL | re.IGNORECASE),
    re.compile(r"<analysis>(.*?)</analysis>", re.DOTALL | re.IGNORECASE),
)

# Legacy aliases kept for any external caller that imported them
# before the centralisation.
THINK_PATTERN = _THINKING_TAG_PATTERNS[0]
STRAY_THINK_CLOSE_PATTERN = re.compile(
    r"^\s*</(?:think|thinking|reasoning|analysis)>\s*", re.IGNORECASE
)

_TOOL_OPEN_PROBE_RE = re.compile(r"<\s*tool\s*>", re.IGNORECASE)


def extract_thinking(text: str) -> Tuple[str, str]:
    """Separate model chain-of-thought from user-visible content.

    Returns ``(visible, thinking)``. Either can be the empty string.

    Detection (all centralised here, no model-specific code):
      1. Tag-delimited blocks listed in ``_THINKING_TAG_PATTERNS`` are
         removed from the visible text and concatenated into the
         thinking output.
      2. If a ``<tool>`` tag is present in what remains, every byte
         BEFORE the first ``<tool>`` is treated as reasoning. The
         protocol forbids preamble before a tool call, so this is
         provably reasoning even when the model omits the tags.
      3. A stray closing tag (``</think>`` / ``</thinking>`` / ...) at
         the very start is dropped.
    """
    if not text:
        return text, ""

    thinking_parts: List[str] = []
    visible = text

    # (1) Pull out all delimited thinking blocks first.
    for pat in _THINKING_TAG_PATTERNS:
        for m in pat.finditer(visible):
            body = m.group(1).strip()
            if body:
                thinking_parts.append(body)
        visible = pat.sub("", visible)

    # (2) Preamble before the first tool tag is reasoning by protocol.
    tool_open = _TOOL_OPEN_PROBE_RE.search(visible)
    if tool_open and tool_open.start() > 0:
        preamble = visible[: tool_open.start()].strip()
        if preamble:
            thinking_parts.append(preamble)
        visible = visible[tool_open.start():]

    # (3) Strip any stray closing-tag fragment the model leaves behind.
    visible = STRAY_THINK_CLOSE_PATTERN.sub("", visible).strip()

    return visible, "\n\n".join(thinking_parts).strip()


# Hallucinated-transcript cleanup
#
# Some models keep generating an entire pretend ``User: Tool foo
# returned: ... Assistant: ...`` transcript after the real tool call
# when the upstream endpoint silently ignores ``stop=["</tool>"]``
# (seen on Ollama Cloud + nemotron-* / deepseek-*). Without this
# truncation the parser would extract the hallucinated ``<tool>`` calls
# from that transcript and dispatch them.
#
# Two regex tiers:
#  * ``_FAKE_TRANSCRIPT_MARKER_RE`` — generic speaker markers
#    (``User: ``, ``Assistant: ``). Used only AFTER a ``</tool>`` is
#    seen so legitimate replies that quote "User:" in prose are safe.
#  * ``_STRONG_FAKE_MARKER_RE`` — patterns that essentially never
#    appear in legitimate model output (a fake tool-return transcript,
#    an INTERNAL pseudo-directive, or an explicit ``Assistant: <tool>``
#    mid-reply). Safe to truncate on with NO ``</tool>`` gate.
#
# Both regexes intentionally allow arbitrary whitespace (spaces,
# tabs, newlines) before the marker so the upstream stop sequences
# ``\nUser:`` / ``\nAssistant:`` are no longer the only defense
# against the model emitting ``</tool>  User:`` (two spaces, no
# newline -- bypasses the Ollama stop list).
_FAKE_TRANSCRIPT_MARKER_RE = re.compile(
    r"\s*("
    r"User:\s*Tool\s+[`'\"]?[\w_-]+[`'\"]?\s+returned"  # "User: Tool foo returned"
    r"|User:\s+\[INTERNAL"  # "User: [INTERNAL ..."
    r"|\[INTERNAL:"  # bare [INTERNAL: marker
    r"|Assistant:\s"  # "Assistant: ..."
    r"|User:\s"  # generic "User: ..."
    r")",
    re.IGNORECASE,
)

# Strong markers: unique enough to fire even without a preceding
# ``</tool>``. Each pattern is something a well-behaved model would
# essentially never emit in a real reply.
_STRONG_FAKE_MARKER_RE = re.compile(
    r"\s*("
    r"User:\s*Tool\s+[`'\"]?[\w_-]+[`'\"]?\s+returned"  # fake tool result
    r"|User:\s+\[INTERNAL"  # "User: [INTERNAL ..."
    r"|\[INTERNAL:\s*(?:Continue|Either)"  # the canned nudge
    r"|Assistant:\s*<\s*tool\s*>"  # mid-reply tool drift
    r")",
    re.IGNORECASE,
)

_TOOL_CLOSE_RE = re.compile(r"</\s*tool\s*>", re.IGNORECASE)


def _truncate_at_fake_transcript(text: str) -> str:
    """Cut ``text`` at the first hallucinated speaker marker.

    Two-tier defense:
      1. If a closing ``</tool>`` is present, any speaker marker that
         follows it is treated as fake (the model has already finished
         the tool call; anything after is hallucination).
      2. Even without ``</tool>``, the *strong* markers
         (``User: Tool X returned``, ``[INTERNAL: Continue``,
         ``Assistant: <tool>``) trigger a truncation because legitimate
         content essentially never contains them.

    Returns ``text`` unchanged when neither tier matches.
    """
    if not text:
        return text

    # Tier 1: post-</tool> generic markers (allows legitimate quoting
    # of "User:" before any tool is called).
    cut: int | None = None
    m_close = _TOOL_CLOSE_RE.search(text)
    if m_close is not None:
        m_fake = _FAKE_TRANSCRIPT_MARKER_RE.search(text, pos=m_close.end())
        if m_fake is not None:
            cut = m_fake.start()

    # Tier 2: strong markers anywhere in the text. Take the earlier of
    # the two cut positions so we always trim to the safest boundary.
    m_strong = _STRONG_FAKE_MARKER_RE.search(text)
    if m_strong is not None:
        cut = m_strong.start() if cut is None else min(cut, m_strong.start())

    if cut is None:
        return text
    return text[:cut].rstrip()


def clean_history_text(text: str) -> str:
    """Clean assistant text before storing it in conversation self.

    Chain-of-thought (in any of the known forms -- see
    :func:`extract_thinking`) is dropped here so it never pollutes the
    context the next turn sees.
    """
    if not text:
        return text
    cleaned = CHAT_TEMPLATE_TOKEN_PATTERN.sub("", text)
    visible, _thinking = extract_thinking(cleaned)
    # Defensive: cut at the first fake speaker marker if the upstream
    # endpoint ignored ``stop=["</tool>"]`` and let the model emit a
    # pretend transcript after the real tool call.
    visible = _truncate_at_fake_transcript(visible)
    return visible.strip()


def clean_final_answer(text: str) -> str:
    """Clean the final text returned to the user.

    Any chain-of-thought (delimited tags OR plain-text preamble before
    a ``<tool>`` tag) is extracted by :func:`extract_thinking` and
    DROPPED from the user-facing answer (Issue 1 fix). The orchestrator
    UI path does not render ``<think>`` blocks, so keeping them only
    surfaced raw tags / "thinking out loud" in the chat bubble. The
    reasoning is still emitted to the orchestrator stderr log for
    debugging. If no reasoning was detected the answer is returned
    unchanged.

    Task-flow tags (``<tasks>``, ``<task_status>``, ``<task_action>``)
    are also stripped here as a defense-in-depth measure: the tool
    loop already strips them per-iteration, but final-answer / synthesis
    / recap paths may bypass that step. Without this strip the raw
    protocol noise leaks into the chat bubble. The strip uses a lazy
    import to avoid a circular dependency with ``task_protocol``.
    """
    if not text:
        return text

    cleaned = JUNK_TAG_PATTERN.sub("", text)
    cleaned = CHAT_TEMPLATE_TOKEN_PATTERN.sub("", cleaned)
    visible, _thinking = extract_thinking(cleaned)

    # Defense-in-depth: strip task-flow protocol tags from the visible
    # text before it ever reaches the user. Lazy import keeps this
    # module free of a hard dependency on task_protocol.
    try:
        visible = strip_task_tags(visible)
    except ImportError:
        pass

    visible = re.sub(r"\n{3,}", "\n\n", visible).strip()

    if (
            len(visible) >= 2
            and visible[0] == '"'
            and visible[-1] == '"'
            and visible.count('"') == 2
    ):
        visible = visible[1:-1].strip()

    # Issue 1 fix: drop chain-of-thought from the user-facing answer.
    # The orchestrator UI path does not render <think> blocks, so
    # wrapping the reasoning here only surfaced raw tags / "thinking out
    # loud" in the chat bubble. The reasoning is still visible in the
    # orchestrator stderr log; it simply no longer leaks to the user.
    return visible


# ---------------------------------------------------------------------------
# Tool-call detection
# ---------------------------------------------------------------------------


def _count_exact_tag(text: str, tag: str) -> int:
    if not text:
        return 0
    return len(re.findall(rf"<\s*{re.escape(tag)}(?=[\s>/=:]|$)", text, re.IGNORECASE))


def looks_like_unclosed_tool(text: str) -> bool:
    """True if the reply opens a tool tag or tool JSON without closing it."""
    if not text:
        return False

    # PRIMARY: check for unclosed <tool>...</tool> XML blocks.
    # This covers both the new XML format and the legacy JSON-in-tags format.
    opens = _count_exact_tag(text, "tool")
    closes = len(re.findall(r"</\s*tool\s*>", text, re.IGNORECASE))
    if opens > closes:
        return True

    opens = _count_exact_tag(text, "tool_call")
    closes = len(re.findall(r"</\s*tool_call\s*>", text, re.IGNORECASE))
    if opens > closes:
        return True

    opens = _count_exact_tag(text, "function_call")
    closes = len(re.findall(r"</\s*function_call\s*>", text, re.IGNORECASE))
    if opens > closes:
        return True

    if "```json" in text.lower() and text.count("```") % 2 == 1:
        if re.search(r'["\']tool["\']', text):
            return True

    if re.search(r'["\']tool["\']\s*:\s*', text) and text.count("{") > text.count("}"):
        return True

    # Catch truncated array-wrapped tool calls: models sometimes emit
    # [{"tool":"write_file",...}] and get cut off mid-string. If the
    # reply mentions "tool" and brackets are unbalanced, it's a
    # truncated tool call regardless of the brace count.
    if re.search(r'["\']tool["\']\s*:\s*', text) and text.count("[") > text.count("]"):
        return True

    return False


#
# Matches:
#   ```json
#   {...}
#   ```
#
#   ```python
#   read_file(...)
#   ```
#
#   ```
#   anything
#   ```
#
# Non-greedy + DOTALL so multiple blocks are handled safely.
_CODE_BLOCK_RE = re.compile(
    r"```(?:[a-zA-Z0-9_+\-]+)?\s*.*?```",
    re.DOTALL,
)

_REFUSAL_PATTERNS = [
    r"as an? ai",
    r"i can(?:'?| ?no)t access (?:your|the user'?s?|local)",
    r"i (?:do not|don'?t) have (?:the )?ability to access",
    r"i (?:do not|don'?t) have (?:direct )?access to",
    r"(?:i am|i'm) unable to (?:access|read|open|list)",
    r"my environment is isolated",
    r"for security reasons",
    r"please (?:copy|paste) (?:the )?(?:contents|output|result)",
    r"run the following command.*(?:and|then).*paste",
    r"hard drive or files directly",
    r"option\s*1.*copy and paste",
    r"option\s*2.*tree",
]


def looks_like_refusal(text: str) -> bool:
    if not text:
        return False
    low = text.lower()
    return any(re.search(p, low) for p in _REFUSAL_PATTERNS)


def _looks_like_tool_attempt(text: str) -> bool:
    if not text:
        return False

    # Check for explicit tool tags (XML format or legacy JSON-in-tags).
    if re.search(r"<\s*tool\s*>", text, re.IGNORECASE):
        return True
    if re.search(r"</\s*tool\s*>", text, re.IGNORECASE):
        return True

    # XML child-tag indicators: <name>...</name> inside a <tool> context
    if re.search(r"<\s*name\s*>.*</\s*name\s*>", text, re.IGNORECASE | re.DOTALL):
        return True

    # Only match "tool": "name" when it looks like a JSON object start —
    # a bare mention of '"tool": "read_file"' in a final-answer narrative
    # should NOT trigger the malformed path.
    if re.search(r'\{\s*["\']tool["\']\s*:\s*["\']\w+["\']', text):
        return True

    if re.search(
            r"\b(?:tool_call|function_call)\s*[:=]\s*['\"]\w+['\"]", text, re.IGNORECASE
    ):
        return True

    if re.search(r"```(?:json|tool)\b", text, re.IGNORECASE):
        return True

    return False


def parse_all_tag_tool_calls_legacy_json(
        response: str, tool_defs=None
) -> List[Tuple[str, Dict[str, Any]]]:
    """Legacy JSON-only parser — used as a fallback when the primary
    XML parser fails, and by ``looks_like_malformed_tool_call`` to check
    whether a reply is a valid legacy JSON tool call (so we don't
    false-positive on JSON-in-tags that the fallback can still parse).
    """
    if not response:
        return []
    candidates = _gather_candidates(response, tool_defs)
    for raw in candidates:
        for cleaned in json_variants(raw):
            parsed = _maybe_parse_jsonish(cleaned)
            if not isinstance(parsed, dict):
                continue
            normalized = _normalize_tool_spec(parsed, tool_defs)
            if not normalized:
                continue
            name, params = normalized
            return [(name, params)]
    return []


def looks_like_malformed_tool_call(text: str) -> Tuple[bool, str | None]:
    """Detect output that appears to be a tool call but is malformed.

    Checks both the primary XML format and the legacy JSON format.
    """
    if not text:
        return False, None

    # ---- PRIMARY: XML child-tag format check ----
    # If there's a <tool> tag but the XML parser can't extract a valid
    # call from it, it's malformed.
    if re.search(r"<\s*tool\s*>", text, re.IGNORECASE):
        if not parse_xml_tool_calls(text):
            # Don't false-positive on legacy JSON-in-tags that the
            # fallback parser can still handle.
            if not parse_all_tag_tool_calls_legacy_json(text):
                return True, (
                    "Malformed XML tool call: the <tool> block could not be parsed. "
                    "Ensure there is a <name>...</name> child and all parameter "
                    "tags are properly opened and closed.\n"
                    "XML Attributes are FORBIDDEN. PERIOD.\n"
                    "WRONG example: <name=list_files_recursive</name>. '<name=' IS Malformed XML.\n"
                    "WRONG example: <path=client/lib</path> As you can see '<path=' IS Malformed XML.\n"
                    "RULES for XML Tags:\n"
                    "Including content BETWEEN TWO DIFFERENT XML TAGS IS FORBIDDEN:\n"
                    "WRONG EXMAPLES:\n"
                    "<tool>  ```html <name>search_in_files</name> .....\n"
                    "<tool> ```code <name>search_in_files</name> .....\n"
                    "<tool> ``` <name>search_in_files</name> .....\n"
                    "<tool>code<name>search_in_files</name> .....\n"
                    "CORRECT TAG FORMAT:\n"
                    "<tool><name>search_in_files</name> .....\n"
                    "<tool><name>read_file</name> .....\n"
                    "<tool><name>patch_file</name> .....\n"
                    "UNIQUE CORRECT TOOL CALL FORMAT:\n"
                    "<tool>\n"
                    "  <name>tool_name</name>\n"
                    "  <key>value</key>\n"
                    "</tool>\n"
                    "Example:\n"
                    "<tool>\n"
                    "  <name>read_file</name>\n"
                    "  <path>src/main.py</path>\n"
                    "</tool>"
                )

    # ---- FALLBACK: legacy JSON format check ----
    if not _looks_like_tool_attempt(text):
        return False, None

    if parse_all_tag_tool_calls_legacy_json(text):
        return False, None

    correct_format = (
        "XML Attributes are FORBIDDEN. PERIOD.\n"
        "WRONG example: <name=list_files_recursive</name>. '<name=' IS Malformed XML.\n"
        "WRONG example: <path=client/lib</path> As you can see '<path=' IS Malformed XML.\n"
        "RULES for XML Tags:\n"
        "Including content BETWEEN TWO DIFFERENT XML TAGS IS FORBIDDEN:\n"
        "WRONG EXMAPLES:\n"
        "<tool>  ```html <name>search_in_files</name> .....\n"
        "<tool> ```code <name>search_in_files</name> .....\n"
        "<tool> ``` <name>search_in_files</name> .....\n"
        "<tool>code<name>search_in_files</name> .....\n"
        "CORRECT TAG FORMAT:\n"
        "<tool><name>search_in_files</name> .....\n"
        "<tool><name>read_file</name> .....\n"
        "<tool><name>patch_file</name> .....\n"
        "UNIQUE CORRECT TOOL CALL FORMAT:\n"
        "<tool>\n"
        "  <name>tool_name</name>\n"
        "  <key>value</key>\n"
        "</tool>\n"
        "Example:\n"
        "<tool>\n"
        "  <name>read_file</name>\n"
        "  <path>src/main.py</path>\n"
        "</tool>"
    )

    # Require JSON key position context ({  or ,) to avoid false positives
    # on comparison operators like  "count" > 0  in narrative text.
    if re.search(r'[{,]\s*"\w+"\s*>', text):
        return True, (
            f"Malformed tool call: JSON syntax error. Found '\"key\">' instead of '\"key\":'. "
            f"{correct_format}"
        )

    if re.search(r'\{\s*["\']tool["\']', text) and not text.rstrip().endswith("}"):
        # Don't false-positive on <tool>...</tool> wrapped calls — the
        # outer text ends with </tool>, not "}", but the JSON inside the
        # tags may be perfectly valid. Extract the JSON body and check
        # whether IT is unclosed instead.
        tag_match = re.search(r'<tool[^>]*>(.*?)</tool>', text, re.DOTALL | re.IGNORECASE)
        if tag_match:
            inner = tag_match.group(1).strip()
            if inner.endswith("}"):
                # Braces are balanced, but the content might still be
                # broken (e.g. double-escaped backslashes causing a
                # premature string close).  Verify with json.loads before
                # declaring it valid.
                try:
                    json.loads(inner)
                except json.JSONDecodeError:
                    pass  # Fall through to the catch-all below.
                else:
                    return False, None  # JSON inside tags is valid
        return True, (
            f"Malformed tool call: Unclosed JSON object. The tool call starts with '{{' but does not end with '}}'. "
            f"{correct_format}"
        )

    # Require JSON key position context to avoid false positives.
    if re.search(r'\{[^}]*[{,]\s*"\w+"\s*>', text):
        return True, (
            f"Malformed tool call: Invalid JSON syntax. Found '>' instead of ':' as a key-value separator. "
            f"{correct_format}"
        )

    if re.search(r'"tool"\s*"[a-zA-Z_]+"', text) and '"tool":' not in text:
        return True, (
            f"Malformed tool call: Missing colon after 'tool' key. {correct_format}"
        )

    # Require JSON key position context for the same reason as above.
    if re.search(r'[{,]\s*["\']parameters["\']\s*>', text):
        return True, (
            f"Malformed tool call: Invalid syntax after 'parameters' key. Use ':' not '>'. {correct_format}"
        )

    # Catch-all: the text looks like a tool call (has {"tool":...), didn't
    # parse, and none of the specific patterns above matched.  Try a bare
    # json.loads on every JSON object extract_json_objects can find — if
    # any fail, report the parse error so the orchestrator can nudge the
    # model instead of silently returning raw JSON to the user.
    #
    # This catches double-escaped backslashes (\\\\\\\" breaking the string),
    # premature quote closure, and other content-level JSON errors that
    # the syntactic patterns above don't cover.
    for obj in extract_json_objects(text):
        try:
            json.loads(obj)
        except json.JSONDecodeError as e:
            return True, (
                f"Malformed tool call: JSON parse error at position {e.pos}: {e.msg}. "
                f"The JSON between the braces is not valid — check for double-escaped "
                f"backslashes or unescaped quotes inside string values. "
                f"{correct_format}"
            )

    # Final safety net: if we reached here, _looks_like_tool_attempt(text)
    # was True (checked at the top) and parse_all_tag_tool_calls(text)
    # returned nothing (also checked at the top), but none of the specific
    # syntax patterns or the extract_json_objects catch-all above fired.
    # This happens when the JSON is so truncated that the brace-walker in
    # extract_json_objects can't even extract a complete object — e.g. the
    # model opened {"tool":"write_file","parameters":{"content":"... but
    # ran out of tokens mid-string, leaving an unclosed string literal that
    # swallows the closing braces. The trailing bytes may happen to end
    # with "}" (from an outer array wrapper like [{...}]}) which fooled
    # the rstrip().endswith("}") check at line 412 above.
    #
    # Without this guard the raw JSON is returned verbatim to the user as
    # a "final answer." Treat any reply that starts with a JSON opener and
    # contains a "tool":"name" key as a malformed tool call so the
    # orchestrator can nudge/retry instead of leaking the broken JSON.
    stripped = text.lstrip()
    if stripped[:1] in ("{", "[") and re.search(
            r'["\']tool["\']\s*:\s*["\']\w+["\']', stripped
    ):
        return True, (
            f"Malformed tool call: The reply looks like a JSON tool call "
            f"but could not be parsed — it is likely truncated or has "
            f"unbalanced braces/brackets (e.g. an unclosed string literal "
            f"swallowing the closing braces). Re-emit the tool call in "
            f"full, or split the payload if it is too large. "
            f"{correct_format}"
        )

    return False, None


# ---------------------------------------------------------------------------
# Tool-call parsing
# ---------------------------------------------------------------------------


def json_variants(raw: str):
    """Yield progressively cleaned forms of a candidate JSON fragment."""
    yield raw
    yield re.sub(r",(\s*[}\]])", r"\1", raw)
    yield raw.replace("“", '"').replace("”", '"').replace("‘", "'").replace("’", "'")


def extract_json_objects(text: str) -> List[str]:
    """
    Return every balanced top-level {...} substring.

    Handles nesting and string literals containing braces.
    """
    out: List[str] = []
    if not text:
        return out

    i = 0
    n = len(text)

    while i < n:
        if text[i] != "{":
            i += 1
            continue

        depth = 0
        in_str = False
        esc = False
        start = i

        while i < n:
            c = text[i]
            if in_str:
                if esc:
                    esc = False
                elif c == "\\":
                    esc = True
                elif c == '"':
                    in_str = False
            elif c == '"':
                in_str = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    out.append(text[start: i + 1])
                    i += 1
                    break
            i += 1
        else:
            break

    return out


def _maybe_parse_scalar(value: str) -> Any:
    """Try to decode a scalar-ish string into a Python value."""
    if value is None:
        return value

    s = value.strip()
    if s == "":
        return s

    for candidate in json_variants(s):
        try:
            return json.loads(candidate)
        except Exception:
            pass

    lowered = s.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if lowered == "null":
        return None

    return s


_OPEN_TAG_RE = re.compile(
    r"<(?P<tag>tool|tool_call|function_call|function)(?=[\s>/=:]|$)"
    r"(?:\s*[=:]\s*(?P<name>[a-zA-Z_][\w\-]*))?[^>]*>",
    re.IGNORECASE,
)

_PARAM_TAG_RE = re.compile(
    r"<(?P<tag>parameter|parameters)(?=[\s>/=:]|$)"
    r"(?:\s*[=:]\s*(?P<name>[a-zA-Z_][\w\-]*))?\s*>"
    r"(?P<value>.*?)"
    r"</\s*(?P=tag)\s*>",
    re.IGNORECASE | re.DOTALL,
)

_HYBRID_RE = re.compile(
    r'["\']?(?:tool|name)["\']?\s*["\':=]\s*["\']([a-zA-Z_][\w\-]*)["\']'
    r"[^<{]*?<\s*(?:parameters|parameter)\b[^>]*>\s*(\{.*?})",
    re.DOTALL | re.IGNORECASE,
)

_WRAPPER_LEAK_KEYS = ("parameters", "arguments", "args", "tool", "name", "function")

_TOOL_FAMILY_CLOSE_RE = re.compile(
    r"</\s*(?:tool|tool_call|function_call|function)\s*>",
    re.IGNORECASE,
)


def _iter_xmlish_blocks(text: str):
    """Yield (tag_name, opener_name, body) for every XML-ish tool block.

    Accepts mismatched closers within the tool family (e.g. ``<tool>...
    </tool_call>``) — small open-source models (glm, some qwen builds)
    routinely mix the two grammars in a single reply.
    """
    if not text:
        return

    pos = 0
    n = len(text)

    while pos < n:
        m = _OPEN_TAG_RE.search(text, pos)
        if not m:
            break

        tag = m.group("tag").lower()
        opener_name = m.group("name")

        close_m = _TOOL_FAMILY_CLOSE_RE.search(text, m.end())
        if not close_m:
            pos = m.end()
            continue

        body = text[m.end(): close_m.start()]
        yield tag, opener_name, body
        pos = close_m.end()


_ARG_KV_RE = re.compile(
    r"<arg_key>\s*(?P<k>[^<]*?)\s*</arg_key>\s*<arg_value>\s*(?P<v>.*?)\s*</arg_value>",
    re.DOTALL | re.IGNORECASE,
)
_ARG_KV_UNCLOSED_RE = re.compile(
    # <arg_key>K</arg_key><arg_value>V"   — value uses a bare `"` as terminator.
    r'<arg_key>\s*(?P<k>[^<]*?)\s*</arg_key>\s*<arg_value>(?P<v>[^<"]*?)"',
    re.DOTALL | re.IGNORECASE,
)
_ARG_VALUE_AFTER_COLON_RE = re.compile(
    r":\s*<arg_value>\s*(?P<v>.*?)\s*</arg_value>",
    re.DOTALL | re.IGNORECASE,
)
_ARG_VALUE_AFTER_COLON_UNCLOSED_RE = re.compile(
    # :<arg_value>VAL"   — model used `"` instead of `</arg_value>` as terminator.
    r':\s*<arg_value>(?P<v>[^<"]*?)"',
    re.DOTALL | re.IGNORECASE,
)
_QUOTED_VALUE_CLOSED_BY_TAG_RE = re.compile(
    # :"VAL</arg_value>   — model opened with `"` (valid JSON) but closed with </arg_value>.
    r':\s*"(?P<v>[^"]*?)</arg_value>',
    re.DOTALL | re.IGNORECASE,
)
_STRAY_ARG_TAG_RE = re.compile(
    r"</?arg_(?:key|value|name)\b[^>]*>",
    re.IGNORECASE,
)


def _normalize_glm_arg_tags(text: str) -> str:
    """Convert glm-style ``<arg_key>K</arg_key><arg_value>V</arg_value>`` pairs
    into JSON ``"K":"V"`` so the standard JSON parser can succeed.

    Handles every malformed variant observed in the wild:

      1. ``"key": <arg_value>VAL</arg_value>``         →  ``"key": "VAL"``
      2. ``<arg_key>K</arg_key><arg_value>V</arg_value>``  →  ``, "K": "V"``
      3. ``"key": <arg_value>VAL"``                    →  ``"key": "VAL"``  (unclosed)
      4. ``<arg_key>K</arg_key><arg_value>V"``         →  ``, "K": "V"``   (unclosed)
      5. ``"key": "VAL</arg_value>``                   →  ``"key": "VAL"`` (open `"`,
                                                          model substituted close-tag
                                                          for the closing `"`)

    Stray ``<arg_*>`` tags and tool-family close tags are stripped after
    repair; missing trailing braces are restored by ``_autoclose_braces``.
    """
    if not text:
        return text
    low = text.lower()
    if (
            "<arg_value>" not in low
            and "<arg_key>" not in low
            and "</arg_value>" not in low
    ):
        return text

    def _esc(s: str) -> str:
        # Just enough escaping to land valid JSON.
        return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

    out = _ARG_KV_RE.sub(
        lambda m: ', "' + _esc(m.group("k")) + '": "' + _esc(m.group("v")) + '"',
        text,
    )
    out = _ARG_KV_UNCLOSED_RE.sub(
        lambda m: ', "' + _esc(m.group("k")) + '": "' + _esc(m.group("v")) + '"',
        out,
    )
    out = _ARG_VALUE_AFTER_COLON_RE.sub(
        lambda m: ': "' + _esc(m.group("v")) + '"',
        out,
    )
    out = _ARG_VALUE_AFTER_COLON_UNCLOSED_RE.sub(
        lambda m: ': "' + _esc(m.group("v")) + '"',
        out,
    )
    out = _QUOTED_VALUE_CLOSED_BY_TAG_RE.sub(
        lambda m: ': "' + _esc(m.group("v")) + '"',
        out,
    )

    # Strip stragglers: leftover <arg_*> tags and tool-family close tags.
    # Leaving them inline would put non-JSON garbage inside the parameters
    # object — extract_json_objects then yields a candidate that fails to
    # parse.
    out = _STRAY_ARG_TAG_RE.sub("", out)
    out = _TOOL_FAMILY_CLOSE_RE.sub("", out)

    # glm hybrids frequently drop the trailing braces (the close-tag stood
    # in for them in the model's mental model). If the normalized string
    # has more `{` than `}` outside string literals, append closers so
    # extract_json_objects can balance the candidate.
    return _autoclose_braces(out)


def _autoclose_braces(text: str) -> str:
    """Append ``}`` characters to balance unclosed objects, ignoring braces
    inside JSON string literals.
    """
    depth = 0
    in_str = False
    esc = False
    for ch in text:
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            if depth > 0:
                depth -= 1
    if depth <= 0:
        return text
    return text + ("}" * depth)


def _tool_defs_iter(tool_defs):
    return tool_defs or []


def _tool_name_and_schema(
        defn: Dict[str, Any],
) -> Tuple[Optional[str], Optional[Dict[str, Any]]]:
    """Extract tool name and parameter schema from a tool definition."""
    if not isinstance(defn, dict):
        return None, None

    fn = defn.get("function")
    if isinstance(fn, dict):
        name = fn.get("name")
        schema = (
            fn.get("parameters") if isinstance(fn.get("parameters"), dict) else None
        )
        return name, schema

    name = defn.get("name")
    if isinstance(name, str):
        schema = (
            defn.get("parameters") if isinstance(defn.get("parameters"), dict) else None
        )
        return name, schema

    return None, None


def _allowed_param_names(tool_name: str, tool_defs) -> Optional[set]:
    """Return allowed parameter names for a tool if schema is available."""
    if not tool_name or not tool_defs:
        return None

    for td in _tool_defs_iter(tool_defs):
        name, schema = _tool_name_and_schema(td)
        if name != tool_name or not schema:
            continue
        props = schema.get("properties") or {}
        if not props:
            return None
        return set(props.keys())

    return None


def _infer_tool_name_from_params(params: Dict[str, Any], tool_defs) -> Optional[str]:
    """Infer the tool name from parameter keys when the model omitted it."""
    if not tool_defs or not params:
        return None

    param_keys = set(params.keys())
    best_name = None
    best_score = -1

    for td in _tool_defs_iter(tool_defs):
        name, schema = _tool_name_and_schema(td)
        if not name or not schema:
            continue

        props = schema.get("properties") or {}
        required = set(schema.get("required", []) or [])
        prop_keys = set(props.keys())

        overlap = len(param_keys & prop_keys)
        if overlap == 0:
            continue

        if required and not required.issubset(param_keys):
            continue

        if overlap < 2 < len(prop_keys) and not required:
            continue

        score = overlap * 10 + (5 if param_keys.issubset(prop_keys) else 0)
        if score > best_score:
            best_score = score
            best_name = name

    return best_name


def _decode_embedded_tool_call(name_value: Any) -> Optional[Tuple[str, Dict[str, Any]]]:
    """Decode malformed tool-name payloads that embed a full call object."""
    if not isinstance(name_value, str):
        return None

    raw = name_value.strip()
    if not (raw.startswith("{") and raw.endswith("}")):
        return None

    try:
        embedded = json.loads(raw)
    except json.JSONDecodeError:
        return None

    if not isinstance(embedded, dict):
        return None

    emb_name = embedded.get("name") or embedded.get("tool")
    emb_params = (
            embedded.get("arguments")
            or embedded.get("parameters")
            or embedded.get("args")
            or {}
    )

    if isinstance(emb_params, str):
        try:
            emb_params = json.loads(emb_params)
        except json.JSONDecodeError:
            emb_params = {}

    if not isinstance(emb_name, str) or not emb_name:
        return None
    if not isinstance(emb_params, dict):
        emb_params = {}

    return emb_name, emb_params


def _sanitize_params(
        params: Dict[str, Any],
        tool_name: str,
        tool_defs,
) -> Dict[str, Any]:
    """Strip wrapper-key leaks and double-nesting before execution."""
    if not isinstance(params, dict):
        return {} if params is None else params

    for wrapper in ("parameters", "arguments", "args"):
        if wrapper not in params:
            continue
        inner = params[wrapper]
        if not isinstance(inner, dict) or not inner:
            continue

        non_wrapper_keys = [k for k in params if k not in _WRAPPER_LEAK_KEYS]
        if non_wrapper_keys:
            continue

        params = dict(inner)
        break

    allowed = _allowed_param_names(tool_name, tool_defs)

    cleaned: Dict[str, Any] = {}
    dropped: List[str] = []

    for k, v in params.items():
        if k in _WRAPPER_LEAK_KEYS:
            if allowed is not None and k in allowed:
                cleaned[k] = v
                continue

            is_empty = v in (None, "", {}, []) or (isinstance(v, str) and not v.strip())

            if is_empty or allowed is not None:
                dropped.append(k)
                continue

            cleaned[k] = v
        else:
            cleaned[k] = v

    if allowed is not None:
        unknown = [k for k in cleaned if k not in allowed]
        for k in unknown:
            dropped.append(k)
            cleaned.pop(k, None)

    if dropped:
        try:
            print(
                f"[tool-dispatch] sanitized {tool_name}({list(cleaned.keys())}); "
                f"dropped hallucinated keys: {dropped}",
                file=sys.stderr,
                flush=True,
            )
        except Exception:
            pass
        # Record the drop so the orchestrator can feed a corrective
        # message back to the model. Without this signal the model
        # silently re-emits the same call → repeat-detector → recap
        # bailout. See drain_recent_drops().
        try:
            _RECENT_DROPS.append((tool_name, list(dropped), list(cleaned.keys())))
            # Bound the buffer in case nobody drains it.
            if len(_RECENT_DROPS) > 32:
                del _RECENT_DROPS[:-32]
        except Exception:
            pass

    return cleaned


# (tool_name, dropped_keys, kept_keys) — appended by _sanitize_params,
# drained by the orchestrator each iteration so the model gets told
# exactly which keys it emitted that aren't part of the schema.
_RECENT_DROPS: List[Tuple[str, List[str], List[str]]] = []


def drain_recent_drops() -> List[Tuple[str, List[str], List[str]]]:
    """Pop and return all sanitization drops since the last drain."""
    drops = list(_RECENT_DROPS)
    _RECENT_DROPS.clear()
    return drops


def _normalize_alternative_tool_keys(data: Dict[str, Any]) -> Dict[str, Any]:
    """
    Convert alternative tool-call key formats to the standard format.

    Handles common mistakes like:
      - {"type": "...", "params": {...}}
      - {"function": "...", "args": {...}}
      - {"name": "...", "input": {...}}
      - nested OpenAI-like function call objects
    """
    if not isinstance(data, dict):
        return data

    result: Dict[str, Any] = {}

    tool_name = data.get("tool") if isinstance(data.get("tool"), str) else None
    if not tool_name and isinstance(data.get("name"), str):
        tool_name = data.get("name")

    function_call = data.get("function_call")
    if isinstance(function_call, dict):
        if not tool_name and isinstance(function_call.get("name"), str):
            tool_name = function_call.get("name")
        if "arguments" in function_call and "parameters" not in data:
            data = dict(data)
            data["parameters"] = function_call.get("arguments")

    function_obj = data.get("function")
    if isinstance(function_obj, dict):
        if not tool_name and isinstance(function_obj.get("name"), str):
            tool_name = function_obj.get("name")
        if "arguments" in function_obj and "parameters" not in data:
            data = dict(data)
            data["parameters"] = function_obj.get("arguments")
        if "parameters" in function_obj and "parameters" not in data:
            data = dict(data)
            data["parameters"] = function_obj.get("parameters")
    elif isinstance(function_obj, str) and function_obj:
        if not tool_name:
            tool_name = function_obj

    type_value = data.get("type")
    if isinstance(type_value, str):
        normalized_type = type_value.lower()
        if normalized_type not in {"function", "tool_call", "function_call"}:
            if not tool_name and any(
                    k in data
                    for k in ("parameters", "params", "arguments", "args", "input")
            ):
                tool_name = type_value

    if isinstance(tool_name, str) and tool_name:
        result["tool"] = tool_name

    params = (
            data.get("parameters")
            or data.get("params")
            or data.get("arguments")
            or data.get("args")
            or data.get("input")
            or {}
    )

    if isinstance(params, str):
        try:
            params = json.loads(params)
        except json.JSONDecodeError:
            params = {}
    elif params is None:
        params = {}

    if isinstance(params, dict):
        result["parameters"] = params

    skip_keys = {
        "tool",
        "type",
        "name",
        "function",
        "function_call",
        "parameters",
        "params",
        "arguments",
        "args",
        "input",
    }
    for key, value in data.items():
        if key not in skip_keys:
            # If the model put tool parameters at the top level (e.g.
            # {"tool":"read_files","paths":[...]} with no "parameters"
            # wrapper), fold them into result["parameters"] so the
            # dispatcher sees them. Without this, paths/files/etc.
            # become orphan top-level keys and the tool gets called
            # with an empty parameters dict.
            if isinstance(result.get("parameters"), dict):
                result["parameters"][key] = value
            else:
                result["parameters"] = {key: value}

    return result


def _normalize_tool_spec(
        data: Dict[str, Any], tool_defs
) -> Optional[Tuple[str, Dict[str, Any]]]:
    """Normalize a JSON-like dict into (tool_name, parameters)."""
    if not isinstance(data, dict):
        return None

    data = _normalize_alternative_tool_keys(data)

    name = data.get("tool")
    if isinstance(name, str):
        for prefix in ("functions/", "tools/", "tool/", "func/"):
            if name.startswith(prefix):
                name = name[len(prefix):]
                break

    params = data.get("parameters", {})

    if isinstance(params, str):
        try:
            params = json.loads(params)
        except json.JSONDecodeError:
            params = {}
    elif params is None:
        params = {}
    elif not isinstance(params, dict):
        params = {}

    embedded = _decode_embedded_tool_call(name)
    if embedded is not None:
        emb_name, emb_params = embedded
        if params:
            merged = dict(emb_params)
            merged.update(params)
            params = merged
        else:
            params = emb_params
        name = emb_name

    if not isinstance(name, str) or not name:
        name = _infer_tool_name_from_params(params, tool_defs)

    if isinstance(name, str) and name:
        params = _sanitize_params(params, name, tool_defs)
        return name, params

    return None


def _maybe_parse_jsonish(text: str) -> Optional[Any]:
    if not isinstance(text, str):
        return None

    for candidate in json_variants(text):
        try:
            return json.loads(candidate)
        except Exception:
            pass

    try:
        py_like = (
            text.replace("null", "None")
            .replace("true", "True")
            .replace("false", "False")
        )
        return ast.literal_eval(py_like)
    except Exception:
        return None


def _is_explicit_tool_dict(data: Any) -> bool:
    if not isinstance(data, dict):
        return False

    keys = set(data.keys())
    has_tool = isinstance(data.get("tool"), str) and bool(data.get("tool").strip())
    has_name = isinstance(data.get("name"), str) and bool(data.get("name").strip())
    has_function_call = isinstance(data.get("function_call"), dict)
    has_function_obj = isinstance(data.get("function"), dict) or isinstance(
        data.get("function"), str
    )
    has_params = any(
        k in keys for k in ("parameters", "params", "arguments", "args", "input")
    )
    type_value = data.get("type")
    known_type = isinstance(type_value, str) and type_value.lower() in {
        "function",
        "tool_call",
        "function_call",
    }

    if has_function_call or has_function_obj:
        return True

    if has_tool and (has_params or has_name):
        return True

    if has_name and has_params:
        return True

    if known_type and (has_tool or has_name or has_params):
        return True

    if has_tool and keys <= {"tool", "name", "type"}:
        return True

    # Fallback: {"tool":"read_files","paths":[...]} — the model put the
    # tool's parameters at the top level instead of nesting them under
    # "parameters". Recognize this as a valid tool dict so the parser
    # can normalize it (the params get folded into "parameters" by
    # _normalize_alternative_tool_keys). Without this, the parser
    # returns [] and the malformed-detector false-positives on the
    # "Unclosed JSON" check, wasting all retries.
    _structural_keys = {"tool", "name", "type", "parameters", "params",
                        "arguments", "args", "input", "function",
                        "function_call"}
    if has_tool and (keys - _structural_keys):
        return True

    return False


def repair_hybrid_tool_call(text: str) -> Optional[str]:
    """
    Repair common malformed patterns where a model mixes JSON and XML.
    Returns a valid JSON string or None.
    """
    if not text:
        return None

    low = text.lower()
    if not re.search(r"<\s*(?:parameter|parameters)\b", low):
        return None

    m = _HYBRID_RE.search(text)
    if m:
        name = m.group(1)
        params_raw = m.group(2)

        depth = 0
        end = -1
        for i, ch in enumerate(params_raw):
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    end = i + 1
                    break

        if end > 0:
            params_raw = params_raw[:end]

        params_obj = _maybe_parse_jsonish(params_raw)
        if isinstance(params_obj, dict):
            return json.dumps({"tool": name, "parameters": params_obj})

    open_m = _OPEN_TAG_RE.search(text)
    if not open_m:
        return None

    opener_name = open_m.group("name")
    body_start = open_m.end()
    close_re = re.compile(rf"</\s*{re.escape(open_m.group('tag'))}\s*>", re.IGNORECASE)
    close_m = close_re.search(text, body_start)
    body = text[body_start: close_m.start()] if close_m else text[body_start:]

    params: Dict[str, Any] = {}
    for pm in _PARAM_TAG_RE.finditer(body):
        p_name = pm.group("name")
        if not p_name:
            continue
        params[p_name] = _maybe_parse_scalar(pm.group("value"))

    if not params:
        return None

    if opener_name:
        return json.dumps({"tool": opener_name, "parameters": params})

    return None


def _is_standalone_python_call_context(text: str, start: int, end: int) -> bool:
    before = text[:start].strip()
    after = text[end:].strip()
    if not before and not after:
        return True
    if re.fullmatch(r"[\s`]*", text[:start]) and re.fullmatch(r"[\s`]*", text[end:]):
        return True
    return False


def _gather_candidates(response: str, tool_defs) -> List[str]:
    """Collect all candidate tool-call fragments from the model reply."""
    candidates: List[str] = []
    seen_fragments: set = set()

    def add_candidate(fragment: str):
        fragment = (fragment or "").strip()
        if fragment and fragment not in seen_fragments:
            seen_fragments.add(fragment)
            candidates.append(fragment)

    # Strip markdown code blocks before extraction so that example tool calls
    # inside a code fence (e.g. a Python prompt array) are not mistaken for
    # real tool invocations. The model must never emit a real tool call inside
    # a code block, so this is always safe.
    response = _CODE_BLOCK_RE.sub("", response)

    # glm/qwen builds occasionally splice <arg_key>/<arg_value> tags into the
    # parameters JSON. Normalize once up front and run the full extraction
    # over the repaired text in addition to the original — keeping the
    # original means we never make things worse for well-formed replies.
    normalized = _normalize_glm_arg_tags(response)
    extra_responses = [normalized] if normalized != response else []

    for tag, opener_name, body in _iter_xmlish_blocks(response):
        repaired = repair_hybrid_tool_call(
            f"<{tag}{'=' + opener_name if opener_name else ''}>{body}</{tag}>"
        )
        if repaired:
            add_candidate(repaired)

        for obj in extract_json_objects(body):
            parsed = _maybe_parse_jsonish(obj)
            if isinstance(parsed, dict) and _is_explicit_tool_dict(parsed):
                add_candidate(obj)

        params: Dict[str, Any] = {}
        for pm in _PARAM_TAG_RE.finditer(body):
            p_name = pm.group("name")
            if not p_name:
                continue
            params[p_name] = _maybe_parse_scalar(pm.group("value"))

        if params:
            inferred_name = opener_name or _infer_tool_name_from_params(
                params, tool_defs
            )
            if inferred_name:
                add_candidate(json.dumps({"tool": inferred_name, "parameters": params}))

    repaired_all = repair_hybrid_tool_call(response)
    if repaired_all:
        add_candidate(repaired_all)

    for m in re.finditer(
            r"```(?:json|tool)?\s*({.*?})\s*```",
            response,
            re.DOTALL | re.IGNORECASE,
    ):
        for obj in extract_json_objects(m.group(1)):
            parsed = _maybe_parse_jsonish(obj)
            if isinstance(parsed, dict) and _is_explicit_tool_dict(parsed):
                add_candidate(obj)

    for obj in extract_json_objects(response):
        parsed = _maybe_parse_jsonish(obj)
        if isinstance(parsed, dict) and _is_explicit_tool_dict(parsed):
            add_candidate(obj)

    if tool_defs:
        known = {
            name
            for td in _tool_defs_iter(tool_defs)
            for name, _schema in (_tool_name_and_schema(td),)
            if isinstance(name, str) and name
        }

        for m in re.finditer(r"\b([a-zA-Z_][a-zA-Z0-9_]*)\s*\(([^)]*)\)", response):
            func_name = m.group(1)
            if func_name not in known:
                continue
            if not _is_standalone_python_call_context(response, m.start(), m.end()):
                continue
            pargs = parse_python_call_args(func_name, m.group(2), tool_defs)
            add_candidate(json.dumps({"tool": func_name, "parameters": pargs}))

    # Re-run JSON-object extraction over the glm-normalized text; if the
    # repair turned a malformed reply into something parseable, surface the
    # extra candidates here without disturbing the order of the originals.
    for repaired_text in extra_responses:
        for obj in extract_json_objects(repaired_text):
            parsed = _maybe_parse_jsonish(obj)
            if isinstance(parsed, dict) and _is_explicit_tool_dict(parsed):
                add_candidate(obj)

    return candidates


def parse_python_call_args(func_name: str, args_str: str, tool_defs) -> dict:
    """
    Map a Python-style argument string onto named parameters using the
    ordered property list from the tool definition.
    """
    param_names: List[str] = []
    for td in _tool_defs_iter(tool_defs):
        name, schema = _tool_name_and_schema(td)
        if name == func_name and schema:
            props = schema.get("properties", {})
            param_names = list(props.keys())
            break

    params: Dict[str, Any] = {}
    args_str = (args_str or "").strip()
    if not args_str:
        return params

    try:
        tree = ast.parse("_f(" + args_str + ")", mode="eval")
        call: ast.expr = tree.body

        for i, arg in enumerate(call.args):
            key = param_names[i] if i < len(param_names) else f"arg{i}"
            params[key] = ast.literal_eval(arg)

        for kw in call.keywords:
            params[kw.arg] = ast.literal_eval(kw.value)
    except Exception:
        pass

    return params


def parse_all_tag_tool_calls(
        response: str, tool_defs=None
) -> List[Tuple[str, Dict[str, Any]]]:
    """Parse tool invocations out of the model reply.

    PRIMARY path: XML child-tag format (no attributes):
        <tool>
          <name>read_file</name>
          <path>src/main.py</path>
        </tool>

    FALLBACK: legacy JSON-in-tags format:
        <tool>{"tool":"read_file","parameters":{"path":"src/main.py"}}</tool>

    Returns a list (kept for API compatibility) but stops at the FIRST
    successfully-parsed call. This is intentional hardening: some
    models hallucinate a chain of fake ``<tool>...</tool>`` tags after
    the real one (see ``NEVER SIMULATE TOOL RETURNS`` in the system
    prompt). Executing those hallucinated calls causes runaway loops.
    The agent dispatches one real tool per iteration; if multiple
    operations are needed the model is expected to use the BATCH tools
    (``read_files`` / ``create_directories`` / ``delete_files`` / ...).
    """
    if not response:
        return []

    # ---- PRIMARY: XML child-tag parser ----
    xml_calls = parse_xml_tool_calls(response, tool_defs)
    if xml_calls:
        return xml_calls

    # ---- FALLBACK: legacy JSON-in-tags parser ----
    candidates = _gather_candidates(response, tool_defs)

    for raw in candidates:
        for cleaned in json_variants(raw):
            parsed = _maybe_parse_jsonish(cleaned)
            if not isinstance(parsed, dict):
                continue

            normalized = _normalize_tool_spec(parsed, tool_defs)
            if not normalized:
                continue

            name, params = normalized
            # First valid tool call wins; later candidates ignored.
            return [(name, params)]

    return []


def parse_tag_tool_call(
        response: str, tool_defs=None
) -> Optional[Tuple[str, Dict[str, Any]]]:
    """Parse a single tool invocation. Returns the first valid match or None."""
    calls = parse_all_tag_tool_calls(response, tool_defs)
    return calls[0] if calls else None
