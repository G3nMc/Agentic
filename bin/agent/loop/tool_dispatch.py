# """Pure helpers for parsing tool calls out of model replies.
#
# All functions here are stateless and module-level so they can be called
# from the run loop without dragging the Orchestrator class along.
# """
# from __future__ import annotations
#
# import json
# import re
# from typing import Any, Dict, List, Optional, Tuple
#
# # ---------------------------------------------------------------------------
# # Output-cleaning regexes
# # ---------------------------------------------------------------------------
#
# # HTML-ish tags small models sometimes wrap their output in. `<plaintext>`
# # is a deprecated tag phi3 loves to emit; `<pre>`/`<code>` appear when the
# # model decides the answer deserves "formatting". We strip the wrappers
# # but keep the inner text so the UI renders clean markdown. Stray
# # `</tool>` closers that slipped past the parser are also dropped.
# JUNK_TAG_PATTERN = re.compile(
#     r"</?(?:plaintext|pre|code|html|body|p|span|div|tool)\b[^>]*>",
#     re.IGNORECASE,
# )
# # Reasoning models (DeepSeek-R1, QwQ, groq reasoning variants) wrap their
# # chain-of-thought in <think>…</think>. Strip the entire block so only the
# # final answer reaches the user.
# THINK_PATTERN = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)
# # Some models leak their raw chat-template control tokens into the
# # response (`<|im_start|>`, `<|im_end|>`, `<|im_sep|>`, `<|endoftext|>`,
# # `<|user|>`, `<|assistant|>`, `<|system|>`, `<|eot_id|>`,
# # `<|start_header_id|>...<|end_header_id|>`, etc.). Strip them all —
# # they are never meant to be user-visible.
# CHAT_TEMPLATE_TOKEN_PATTERN = re.compile(r"<\|[^|>]{0,40}\|>")
# # Stray closing `</think>` without an opening tag (the model emitted
# # the close tag at the start of its reply because thinking was
# # truncated by max_tokens or the prompt template).
# STRAY_THINK_CLOSE_PATTERN = re.compile(r"^\s*</think>\s*", re.IGNORECASE)
#
#
# def clean_history_text(text: str) -> str:
#     """Stripping applied before storing an assistant reply in history.
#
#     Removes <think> reasoning blocks and chat-template control tokens
#     so they don't waste context on the next turn. Keeps everything else
#     so the parser still sees `<tool>…</tool>` tags etc.
#     """
#     if not text:
#         return text
#     cleaned = THINK_PATTERN.sub("", text)
#     cleaned = CHAT_TEMPLATE_TOKEN_PATTERN.sub("", cleaned)
#     cleaned = STRAY_THINK_CLOSE_PATTERN.sub("", cleaned).strip()
#     return cleaned
#
#
# def clean_final_answer(text: str) -> str:
#     """Stripping applied to the text returned to the user.
#
#     <think>…</think> blocks are intentionally preserved here — the
#     Flutter UI renders them as a collapsible "Reasoning" section.
#     They are stripped from history entries (in :func:`clean_history_text`)
#     to save context.
#     """
#     if not text:
#         return text
#     cleaned = JUNK_TAG_PATTERN.sub("", text)
#     # Strip leaked chat-template control tokens (phi-4 / Qwen / Llama).
#     cleaned = CHAT_TEMPLATE_TOKEN_PATTERN.sub("", cleaned)
#     # Drop a stray `</think>` at the very start of the reply.
#     cleaned = STRAY_THINK_CLOSE_PATTERN.sub("", cleaned)
#     # Collapse runs of blank lines the stripping may have produced.
#     cleaned = re.sub(r"\n{3,}", "\n\n", cleaned)
#     cleaned = cleaned.strip()
#     # Some small models (phi3, llama3.2) wrap every reply in a pair of
#     # double-quotes: `"The file was created."` → strip them when the
#     # entire response is wrapped (not mid-text quoted content).
#     if (
#             len(cleaned) >= 2
#             and cleaned[0] == '"'
#             and cleaned[-1] == '"'
#             and cleaned.count('"') == 2
#     ):
#         cleaned = cleaned[1:-1].strip()
#     return cleaned
#
#
# # ---------------------------------------------------------------------------
# # Tool-call detection
# # ---------------------------------------------------------------------------
#
# def looks_like_unclosed_tool(text: str) -> bool:
#     """True if the reply opens a `<tool>` tag (or a ```json fence intended
#     as a tool call) without a matching close. Used to detect responses
#     that were cut off by max_tokens mid-JSON."""
#     if not text:
#         return False
#     opens = text.count("<tool>")
#     closes = text.count("</tool>")
#     if opens > closes:
#         return True
#     # Fallback: fenced ```json ... that carries a `"tool"` key but no
#     # matching closing fence.
#     if "```json" in text and text.count("```") % 2 == 1:
#         if '"tool"' in text or "'tool'" in text:
#             return True
#     return False
#
#
# def looks_like_malformed_tool_call(text: str) -> bool:
#     """True when the model appears to be attempting a tool call, but the
#     parser could not extract a valid one."""
#     if not text:
#         return False
#     low = text.lower()
#     if "<tool" in low:
#         return True
#     if '"tool"' in text or "'tool'" in text:
#         return True
#     if ("```json" in low or "```tool" in low) and "parameters" in low:
#         return True
#     return False
#
#
# # Heuristic patterns that strongly suggest the model has ignored the
# # tool-use instructions and is emitting a safety refusal instead.
# REFUSAL_PATTERNS = [
#     r"as an? ai",
#     r"i can(?:'?| ?no)t access (?:your|the user'?s?|local)",
#     r"i (?:do not|don'?t) have (?:the )?ability to access",
#     r"i (?:do not|don'?t) have (?:direct )?access to",
#     r"(?:i am|i'm) unable to (?:access|read|open|list)",
#     r"my environment is isolated",
#     r"for security reasons",
#     r"please (?:copy|paste) (?:the )?(?:contents|output|result)",
#     r"run the following command.*(?:and|then).*paste",
#     r"hard drive or files directly",
#     r"option\s*1.*copy and paste",
#     r"option\s*2.*tree",
# ]
#
#
# def looks_like_refusal(text: str) -> bool:
#     if not text:
#         return False
#     low = text.lower()
#     return any(re.search(p, low) for p in REFUSAL_PATTERNS)
#
#
# # ---------------------------------------------------------------------------
# # Tool-call parsing
# # ---------------------------------------------------------------------------
#
# # Matches the hybrid JSON-inside-XML pattern some models emit, e.g.:
# #   {"tool":"run_command"><parameters>{"command":"..."}}
# # Captures: (1) tool name, (2) parameters JSON body.
# _HYBRID_RE = re.compile(
#     r'["\']?(?:tool|name)["\']?\s*["\':=]\s*["\']([a-zA-Z_][\w\-]*)["\']'
#     r'[^<{]*?<\s*parameters\s*>?\s*(\{.*?\})',
#     re.DOTALL | re.IGNORECASE,
# )
#
# _TAG_RE = re.compile(
#     r"<(tool|tool_call|function_call)[^>]*>(.*?)</\1>",
#     re.DOTALL | re.IGNORECASE,
# )
#
#
# def repair_hybrid_tool_call(text: str) -> Optional[str]:
#     """
#     Repair the common malformed pattern where a model mixes JSON and XML:
#         {"tool":"NAME"><parameters>{"key":"val"}}
#         {"tool":"NAME"}<parameters>{"key":"val"}</parameters>
#     Returns a valid JSON string ``{"tool":"NAME","parameters":{...}}`` or
#     None if no repair could be made.
#     """
#     if not text or "<parameters" not in text.lower():
#         return None
#     m = _HYBRID_RE.search(text)
#     if not m:
#         return None
#     name = m.group(1)
#     params_raw = m.group(2)
#     # Balance braces — the regex is non-greedy so it may under-count.
#     depth = 0
#     end = -1
#     for i, ch in enumerate(params_raw):
#         if ch == "{":
#             depth += 1
#         elif ch == "}":
#             depth -= 1
#             if depth == 0:
#                 end = i + 1
#                 break
#     if end > 0:
#         params_raw = params_raw[:end]
#     try:
#         params_obj = json.loads(params_raw)
#     except json.JSONDecodeError:
#         return None
#     return json.dumps({"tool": name, "parameters": params_obj})
#
#
# def extract_json_objects(text: str) -> List[str]:
#     """
#     Scan `text` and return every top-level `{...}` substring with
#     correctly balanced braces. Handles nested objects and string
#     literals containing `{` or `}`. This is the brace-counter the
#     regex engine can't easily do on its own.
#     """
#     out: List[str] = []
#     i = 0
#     n = len(text)
#     while i < n:
#         if text[i] != '{':
#             i += 1
#             continue
#         depth = 0
#         in_str = False
#         esc = False
#         start = i
#         while i < n:
#             c = text[i]
#             if in_str:
#                 if esc:
#                     esc = False
#                 elif c == '\\':
#                     esc = True
#                 elif c == '"':
#                     in_str = False
#             elif c == '"':
#                 in_str = True
#             elif c == '{':
#                 depth += 1
#             elif c == '}':
#                 depth -= 1
#                 if depth == 0:
#                     out.append(text[start:i + 1])
#                     i += 1
#                     break
#             i += 1
#         else:
#             break  # unbalanced, stop
#     return out
#
#
# def parse_python_call_args(func_name: str, args_str: str, tool_defs) -> dict:
#     """
#     Map a Python-style argument string such as '"lib/main.dart"' or
#     'pattern="foo", path="lib/"' onto named parameters using the ordered
#     property list from the tool definition.
#     """
#     import ast as _ast
#
#     # Look up ordered parameter names from the tool definition.
#     param_names: List[str] = []
#     for td in tool_defs:
#         fn = td.get("function", {})
#         if fn.get("name") == func_name:
#             param_names = list(fn.get("parameters", {}).get("properties", {}).keys())
#             break
#
#     params: Dict[str, Any] = {}
#     args_str = args_str.strip()
#     if not args_str:
#         return params
#
#     try:
#         tree = _ast.parse("_f(" + args_str + ")", mode="eval")
#         call = tree.body
#         for i, arg in enumerate(call.args):
#             key = param_names[i] if i < len(param_names) else ("arg" + str(i))
#             params[key] = _ast.literal_eval(arg)
#         for kw in call.keywords:
#             params[kw.arg] = _ast.literal_eval(kw.value)
#     except Exception:
#         pass
#
#     return params
#
#
# def json_variants(raw: str):
#     """Yield progressively-cleaned forms of a candidate JSON fragment."""
#     yield raw
#     # Strip simple trailing commas that break json.loads.
#     yield re.sub(r",(\s*[}\]])", r"\1", raw)
#     # Replace smart quotes with standard ones.
#     yield (raw.replace("“", '"').replace("”", '"')
#            .replace("‘", "'").replace("’", "'"))
#
#
# def _gather_candidates(response: str, tool_defs) -> List[str]:
#     """Collect all JSON-object substrings that could plausibly be a tool call."""
#     candidates: List[str] = []
#
#     # 1. Preferred: <tool>…</tool>, plus <tool_call> / <function_call>.
#     for m in _TAG_RE.finditer(response):
#         body = m.group(2)
#         candidates.extend(extract_json_objects(body))
#         repaired = repair_hybrid_tool_call(body)
#         if repaired:
#             candidates.append(repaired)
#
#     # 1b. Free-text hybrid (no wrapping tag) — repair whole response.
#     if "<parameters>" in response.lower():
#         repaired_all = repair_hybrid_tool_call(response)
#         if repaired_all:
#             candidates.append(repaired_all)
#
#     # 2. ```json { … } ``` fences (some coder models love these).
#     for m in re.finditer(r"```(?:json|tool)?\s*(\{.*?\})\s*```", response, re.DOTALL):
#         candidates.extend(extract_json_objects(m.group(1)))
#
#     # 3. Any JSON-looking object in free text that mentions "tool" or "name".
#     candidates.extend(
#         obj for obj in extract_json_objects(response)
#         if '"tool"' in obj or '"name"' in obj
#     )
#
#     # 4. Python-style call: tool_name("arg") or tool_name(param="value").
#     if tool_defs:
#         _known = {td["function"]["name"] for td in tool_defs if "function" in td}
#         for m in re.finditer(r'\b([a-z_][a-z0-9_]*)\s*\(([^)]*)\)', response):
#             if m.group(1) in _known:
#                 _pargs = parse_python_call_args(m.group(1), m.group(2), tool_defs)
#                 candidates.append(
#                     json.dumps({"tool": m.group(1), "parameters": _pargs})
#                 )
#
#     return candidates
#
#
# def parse_all_tag_tool_calls(response: str, tool_defs=None) -> List[Tuple[str, Dict[str, Any]]]:
#     """Parse ALL tool invocations out of the model reply.
#
#     Returns a list of (name, params) tuples, deduplicated by (name,
#     canonical-params-json) so the free-text JSON scan doesn't re-pick up
#     objects already captured inside <tool> tags.
#     """
#     if not response:
#         return []
#
#     candidates = _gather_candidates(response, tool_defs)
#
#     results: List[Tuple[str, Dict[str, Any]]] = []
#     seen: set = set()
#     for raw in candidates:
#         for cleaned in json_variants(raw):
#             try:
#                 data = json.loads(cleaned)
#             except json.JSONDecodeError:
#                 continue
#             if not isinstance(data, dict):
#                 continue
#             name = data.get("tool") or data.get("name")
#             params = (data.get("parameters") or data.get("arguments") or data.get("args") or {})
#             if isinstance(params, str):
#                 try:
#                     params = json.loads(params)
#                 except json.JSONDecodeError:
#                     params = {}
#             if isinstance(name, str) and isinstance(params, dict):
#                 key = (name, json.dumps(params, sort_keys=True))
#                 if key not in seen:
#                     seen.add(key)
#                     results.append((name, params))
#                 break
#     return results
#
#
# def parse_tag_tool_call(response: str, tool_defs=None) -> Optional[Tuple[str, Dict[str, Any]]]:
#     """Parse a single tool invocation. Returns the first valid match or None."""
#     calls = parse_all_tag_tool_calls(response, tool_defs)
#     return calls[0] if calls else None



"""Pure helpers for parsing tool calls out of model replies.

All functions here are stateless and module-level so they can be called
from the run loop without dragging the Orchestrator class along.
"""
from __future__ import annotations

import ast
import json
import re
from typing import Any, Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Output-cleaning regexes
# ---------------------------------------------------------------------------

# HTML-ish tags small models sometimes wrap their output in. `<plaintext>`
# is a deprecated tag phi3 loves to emit; `<pre>`/`<code>` appear when the
# model decides the answer deserves "formatting". We strip the wrappers
# but keep the inner text so the UI renders clean markdown. Stray
# `</tool>` closers that slipped past the parser are also dropped.
JUNK_TAG_PATTERN = re.compile(
    r"</?(?:plaintext|pre|code|html|body|p|span|div|tool|tool_call|function_call|function|parameter)\b[^>]*>",
    re.IGNORECASE,
)

# Reasoning models (DeepSeek-R1, QwQ, groq reasoning variants) wrap their
# chain-of-thought in <think>…</think>. Strip the entire block so only the
# final answer reaches the user.
THINK_PATTERN = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)

# Some models leak their raw chat-template control tokens into the
# response (`<|im_start|>`, `<|im_end|>`, `<|im_sep|>`, `<|endoftext|>`,
# `<|user|>`, `<|assistant|>`, `<|system|>`, `<|eot_id|>`,
# `<|start_header_id|>...<|end_header_id|>`, etc.). Strip them all —
# they are never meant to be user-visible.
CHAT_TEMPLATE_TOKEN_PATTERN = re.compile(r"<\|[^|>]{0,40}\|>")

# Stray closing `</think>` without an opening tag (the model emitted
# the close tag at the start of its reply because thinking was
# truncated by max_tokens or the prompt template).
STRAY_THINK_CLOSE_PATTERN = re.compile(r"^\s*</think>\s*", re.IGNORECASE)


def clean_history_text(text: str) -> str:
    """Stripping applied before storing an assistant reply in history.

    Removes <think> reasoning blocks and chat-template control tokens
    so they don't waste context on the next turn. Keeps everything else
    so the parser still sees tool tags etc.
    """
    if not text:
        return text
    cleaned = THINK_PATTERN.sub("", text)
    cleaned = CHAT_TEMPLATE_TOKEN_PATTERN.sub("", cleaned)
    cleaned = STRAY_THINK_CLOSE_PATTERN.sub("", cleaned).strip()
    return cleaned


def clean_final_answer(text: str) -> str:
    """Stripping applied to the text returned to the user.

    <think>…</think> blocks are intentionally preserved here — the
    Flutter UI renders them as a collapsible "Reasoning" section.
    They are stripped from history entries (in :func:`clean_history_text`)
    to save context.
    """
    if not text:
        return text
    cleaned = JUNK_TAG_PATTERN.sub("", text)
    cleaned = CHAT_TEMPLATE_TOKEN_PATTERN.sub("", cleaned)
    cleaned = STRAY_THINK_CLOSE_PATTERN.sub("", cleaned)
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned)
    cleaned = cleaned.strip()
    if (
            len(cleaned) >= 2
            and cleaned[0] == '"'
            and cleaned[-1] == '"'
            and cleaned.count('"') == 2
    ):
        cleaned = cleaned[1:-1].strip()
    return cleaned


# ---------------------------------------------------------------------------
# Tool-call detection
# ---------------------------------------------------------------------------

def looks_like_unclosed_tool(text: str) -> bool:
    """True if the reply opens a tool tag or fenced JSON tool call without
    a matching close. Used to detect responses that were cut off by
    max_tokens mid-call."""
    if not text:
        return False
    opens = text.count("<tool>")
    closes = text.count("</tool>")
    if opens > closes:
        return True
    if text.count("<tool_call>") > text.count("</tool_call>"):
        return True
    if text.count("<function_call>") > text.count("</function_call>"):
        return True
    if "```json" in text and text.count("```") % 2 == 1:
        if '"tool"' in text or "'tool'" in text:
            return True
    return False


def looks_like_malformed_tool_call(text: str) -> bool:
    """True when the model appears to be attempting a tool call, but the
    parser could not extract a valid one."""
    if not text:
        return False
    low = text.lower()
    if "<tool" in low:
        return True
    if "<tool_call" in low or "<function_call" in low or "<function" in low:
        return True
    if '"tool"' in text or "'tool'" in text:
        return True
    if ("```json" in low or "```tool" in low) and "parameters" in low:
        return True
    if "<parameter=" in low:
        return True
    return False


# Heuristic patterns that strongly suggest the model has ignored the
# tool-use instructions and is emitting a safety refusal instead.
REFUSAL_PATTERNS = [
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
    return any(re.search(p, low) for p in REFUSAL_PATTERNS)


# ---------------------------------------------------------------------------
# Tool-call parsing
# ---------------------------------------------------------------------------

# Matches the hybrid JSON-inside-XML pattern some models emit.
_HYBRID_RE = re.compile(
    r'["\']?(?:tool|name)["\']?\s*["\':=]\s*["\']([a-zA-Z_][\w\-]*)["\']'
    r'[^<{]*?<\s*(?:parameters|parameter)\s*>?\s*(\{.*?\})',
    re.DOTALL | re.IGNORECASE,
    )

# Opening tags that may wrap a tool invocation.
# Examples:
#   <tool>
#   <tool=read_file>
#   <tool_call>
#   <function_call>
#   <function=read_file>
_OPEN_TAG_RE = re.compile(
    r"<(?P<tag>tool|tool_call|function_call|function)"
    r"(?:\s*(?:=|:)\s*(?P<name>[a-zA-Z_][\w\-]*))?[^>]*>",
    re.IGNORECASE,
)

# Parameter tags inside XML-ish tool calls.
# Examples:
#   <parameter=path>lib/main.dart</parameter>
#   <parameter=file_glob>*.dart</parameter>
_PARAM_TAG_RE = re.compile(
    r"<parameter(?:\s*(?:=|:)\s*(?P<name>[a-zA-Z_][\w\-]*))\s*>"
    r"(?P<value>.*?)"
    r"</parameter>",
    re.IGNORECASE | re.DOTALL,
    )


def _maybe_parse_scalar(value: str) -> Any:
    """Try to decode a scalar-ish string into a Python value.

    Useful for parameter tag values:
    - `"abc"` -> "abc"
    - `true` -> True
    - `123` -> 123
    - otherwise return the stripped string unchanged
    """
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
    return s


def _iter_xmlish_blocks(text: str):
    """Yield (tag_name, opener_name, body) for every XML-ish tool block."""
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

        close_re = re.compile(rf"</\s*{re.escape(tag)}\s*>", re.IGNORECASE)
        close_m = close_re.search(text, m.end())
        if not close_m:
            pos = m.end()
            continue

        body = text[m.end():close_m.start()]
        yield tag, opener_name, body
        pos = close_m.end()


def extract_json_objects(text: str) -> List[str]:
    """
    Scan `text` and return every top-level `{...}` substring with
    correctly balanced braces. Handles nested objects and string
    literals containing `{` or `}`.
    """
    out: List[str] = []
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
                    out.append(text[start:i + 1])
                    i += 1
                    break
            i += 1
        else:
            break
    return out


def parse_python_call_args(func_name: str, args_str: str, tool_defs) -> dict:
    """
    Map a Python-style argument string such as '"lib/main.dart"' or
    'pattern="foo", path="lib/"' onto named parameters using the ordered
    property list from the tool definition.
    """
    # Look up ordered parameter names from the tool definition.
    param_names: List[str] = []
    for td in tool_defs or []:
        fn = td.get("function", {})
        if fn.get("name") == func_name:
            param_names = list(fn.get("parameters", {}).get("properties", {}).keys())
            break

    params: Dict[str, Any] = {}
    args_str = args_str.strip()
    if not args_str:
        return params

    try:
        tree = ast.parse("_f(" + args_str + ")", mode="eval")
        call = tree.body
        for i, arg in enumerate(call.args):
            key = param_names[i] if i < len(param_names) else ("arg" + str(i))
            params[key] = ast.literal_eval(arg)
        for kw in call.keywords:
            params[kw.arg] = ast.literal_eval(kw.value)
    except Exception:
        pass

    return params


def json_variants(raw: str):
    """Yield progressively-cleaned forms of a candidate JSON fragment."""
    yield raw
    yield re.sub(r",(\s*[}\]])", r"\1", raw)
    yield (
        raw.replace("“", '"')
        .replace("”", '"')
        .replace("‘", "'")
        .replace("’", "'")
    )


def repair_hybrid_tool_call(text: str) -> Optional[str]:
    """
    Repair common malformed patterns where a model mixes JSON and XML:
        {"tool":"NAME"><parameters>{"key":"val"}}
        {"tool":"NAME"}<parameters>{"key":"val"}</parameters>
        <tool=NAME><parameter=path>...</parameter></tool>
    Returns a valid JSON string `{"tool":"NAME","parameters":{...}}`
    or None if no repair could be made.
    """
    if not text:
        return None

    low = text.lower()
    if "<parameter" not in low and "<parameters" not in low:
        return None

    # Case 1: JSON-ish tool/name + XML-ish parameters.
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
        try:
            params_obj = json.loads(params_raw)
            return json.dumps({"tool": name, "parameters": params_obj})
        except json.JSONDecodeError:
            pass

    # Case 2: XML-ish `<parameter=...>` blocks plus a known opener.
    open_m = _OPEN_TAG_RE.search(text)
    if not open_m:
        return None

    opener_name = open_m.group("name")
    body_start = open_m.end()
    close_re = re.compile(rf"</\s*{re.escape(open_m.group('tag'))}\s*>", re.IGNORECASE)
    close_m = close_re.search(text, body_start)
    body = text[body_start:close_m.start()] if close_m else text[body_start:]

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


def _infer_tool_name_from_params(params: Dict[str, Any], tool_defs) -> Optional[str]:
    """Infer the tool name from parameter keys when the model omitted it."""
    if not tool_defs or not params:
        return None

    param_keys = set(params.keys())
    best_name = None
    best_score = -1

    for td in tool_defs:
        fn = td.get("function", {})
        name = fn.get("name")
        if not name:
            continue

        spec = fn.get("parameters", {}) or {}
        props = spec.get("properties", {}) or {}
        required = set(spec.get("required", []) or [])
        prop_keys = set(props.keys())

        overlap = len(param_keys & prop_keys)
        if overlap == 0:
            continue

        if required and not required.issubset(param_keys):
            continue

        score = overlap * 10 + (5 if param_keys.issubset(prop_keys) else 0)
        if score > best_score:
            best_score = score
            best_name = name

    return best_name


def _normalize_tool_spec(data: Dict[str, Any], tool_defs) -> Optional[Tuple[str, Dict[str, Any]]]:
    """Normalize a JSON-like dict into (tool_name, parameters)."""
    if not isinstance(data, dict):
        return None

    name = data.get("tool") or data.get("name")
    params = data.get("parameters") or data.get("arguments") or data.get("args") or {}

    if isinstance(params, str):
        try:
            params = json.loads(params)
        except json.JSONDecodeError:
            params = {}

    if not isinstance(params, dict):
        return None

    if not isinstance(name, str) or not name:
        name = _infer_tool_name_from_params(params, tool_defs)

    if isinstance(name, str) and name:
        return name, params

    return None


def _gather_candidates(response: str, tool_defs) -> List[str]:
    """Collect all candidate tool-call fragments from the model reply."""
    candidates: List[str] = []
    seen_fragments: set = set()

    def add_candidate(fragment: str):
        fragment = fragment.strip()
        if fragment and fragment not in seen_fragments:
            seen_fragments.add(fragment)
            candidates.append(fragment)

    # 1. XML-ish blocks: <tool>, <tool_call>, <function_call>, <function>.
    for tag, opener_name, body in _iter_xmlish_blocks(response):
        # First try to repair direct XML-ish parameter blocks into JSON.
        repaired = repair_hybrid_tool_call(f"<{tag}{'=' + opener_name if opener_name else ''}>{body}</{tag}>")
        if repaired:
            add_candidate(repaired)

        # Direct JSON objects inside the block.
        for obj in extract_json_objects(body):
            add_candidate(obj)

        # Explicit parameter tags.
        params: Dict[str, Any] = {}
        for pm in _PARAM_TAG_RE.finditer(body):
            p_name = pm.group("name")
            if not p_name:
                continue
            params[p_name] = _maybe_parse_scalar(pm.group("value"))

        if params:
            inferred_name = opener_name or _infer_tool_name_from_params(params, tool_defs)
            if inferred_name:
                add_candidate(json.dumps({"tool": inferred_name, "parameters": params}))

    # 1b. Free-text hybrid repair over the whole response.
    repaired_all = repair_hybrid_tool_call(response)
    if repaired_all:
        add_candidate(repaired_all)

    # 2. ```json ... ``` fences.
    for m in re.finditer(r"```(?:json|tool)?\s*(\{.*?\})\s*```", response, re.DOTALL | re.IGNORECASE):
        for obj in extract_json_objects(m.group(1)):
            add_candidate(obj)

    # 3. Any JSON-looking object in free text that mentions tool/name.
    for obj in extract_json_objects(response):
        if '"tool"' in obj or '"name"' in obj:
            add_candidate(obj)

    # 4. Python-style call: tool_name("arg") or tool_name(param="value").
    if tool_defs:
        known = {td.get("function", {}).get("name") for td in tool_defs if "function" in td}
        for m in re.finditer(r"\b([a-zA-Z_][a-zA-Z0-9_]*)\s*\(([^)]*)\)", response):
            func_name = m.group(1)
            if func_name in known:
                pargs = parse_python_call_args(func_name, m.group(2), tool_defs)
                add_candidate(json.dumps({"tool": func_name, "parameters": pargs}))

    return candidates


def parse_all_tag_tool_calls(response: str, tool_defs=None) -> List[Tuple[str, Dict[str, Any]]]:
    """Parse ALL tool invocations out of the model reply.

    Returns a list of (name, params) tuples, deduplicated by (name,
    canonical-params-json) so the free-text JSON scan doesn't re-pick up
    objects already captured inside tool tags.
    """
    if not response:
        return []

    candidates = _gather_candidates(response, tool_defs)

    results: List[Tuple[str, Dict[str, Any]]] = []
    seen: set = set()

    for raw in candidates:
        for cleaned in json_variants(raw):
            try:
                data = json.loads(cleaned)
            except json.JSONDecodeError:
                continue

            normalized = _normalize_tool_spec(data, tool_defs)
            if not normalized:
                continue

            name, params = normalized
            key = (name, json.dumps(params, sort_keys=True, ensure_ascii=False))
            if key not in seen:
                seen.add(key)
                results.append((name, params))
            break

    return results


def parse_tag_tool_call(response: str, tool_defs=None) -> Optional[Tuple[str, Dict[str, Any]]]:
    """Parse a single tool invocation. Returns the first valid match or None."""
    calls = parse_all_tag_tool_calls(response, tool_defs)
    return calls[0] if calls else None