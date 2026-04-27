"""Pure helpers for parsing tool calls out of model replies.

All functions here are stateless and module-level so they can be called
from the run loop without dragging the Orchestrator class along.
"""
from __future__ import annotations

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
    r"</?(?:plaintext|pre|code|html|body|p|span|div|tool)\b[^>]*>",
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
    so the parser still sees `<tool>…</tool>` tags etc.
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
    # Strip leaked chat-template control tokens (phi-4 / Qwen / Llama).
    cleaned = CHAT_TEMPLATE_TOKEN_PATTERN.sub("", cleaned)
    # Drop a stray `</think>` at the very start of the reply.
    cleaned = STRAY_THINK_CLOSE_PATTERN.sub("", cleaned)
    # Collapse runs of blank lines the stripping may have produced.
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned)
    cleaned = cleaned.strip()
    # Some small models (phi3, llama3.2) wrap every reply in a pair of
    # double-quotes: `"The file was created."` → strip them when the
    # entire response is wrapped (not mid-text quoted content).
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
    """True if the reply opens a `<tool>` tag (or a ```json fence intended
    as a tool call) without a matching close. Used to detect responses
    that were cut off by max_tokens mid-JSON."""
    if not text:
        return False
    opens = text.count("<tool>")
    closes = text.count("</tool>")
    if opens > closes:
        return True
    # Fallback: fenced ```json ... that carries a `"tool"` key but no
    # matching closing fence.
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
    if '"tool"' in text or "'tool'" in text:
        return True
    if ("```json" in low or "```tool" in low) and "parameters" in low:
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

# Matches the hybrid JSON-inside-XML pattern some models emit, e.g.:
#   {"tool":"run_command"><parameters>{"command":"..."}}
# Captures: (1) tool name, (2) parameters JSON body.
_HYBRID_RE = re.compile(
    r'["\']?(?:tool|name)["\']?\s*["\':=]\s*["\']([a-zA-Z_][\w\-]*)["\']'
    r'[^<{]*?<\s*parameters\s*>?\s*(\{.*?\})',
    re.DOTALL | re.IGNORECASE,
)

_TAG_RE = re.compile(
    r"<(tool|tool_call|function_call)[^>]*>(.*?)</\1>",
    re.DOTALL | re.IGNORECASE,
)


def repair_hybrid_tool_call(text: str) -> Optional[str]:
    """
    Repair the common malformed pattern where a model mixes JSON and XML:
        {"tool":"NAME"><parameters>{"key":"val"}}
        {"tool":"NAME"}<parameters>{"key":"val"}</parameters>
    Returns a valid JSON string ``{"tool":"NAME","parameters":{...}}`` or
    None if no repair could be made.
    """
    if not text or "<parameters" not in text.lower():
        return None
    m = _HYBRID_RE.search(text)
    if not m:
        return None
    name = m.group(1)
    params_raw = m.group(2)
    # Balance braces — the regex is non-greedy so it may under-count.
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
    except json.JSONDecodeError:
        return None
    return json.dumps({"tool": name, "parameters": params_obj})


def extract_json_objects(text: str) -> List[str]:
    """
    Scan `text` and return every top-level `{...}` substring with
    correctly balanced braces. Handles nested objects and string
    literals containing `{` or `}`. This is the brace-counter the
    regex engine can't easily do on its own.
    """
    out: List[str] = []
    i = 0
    n = len(text)
    while i < n:
        if text[i] != '{':
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
                elif c == '\\':
                    esc = True
                elif c == '"':
                    in_str = False
            elif c == '"':
                in_str = True
            elif c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    out.append(text[start:i + 1])
                    i += 1
                    break
            i += 1
        else:
            break  # unbalanced, stop
    return out


def parse_python_call_args(func_name: str, args_str: str, tool_defs) -> dict:
    """
    Map a Python-style argument string such as '"lib/main.dart"' or
    'pattern="foo", path="lib/"' onto named parameters using the ordered
    property list from the tool definition.
    """
    import ast as _ast

    # Look up ordered parameter names from the tool definition.
    param_names: List[str] = []
    for td in tool_defs:
        fn = td.get("function", {})
        if fn.get("name") == func_name:
            param_names = list(fn.get("parameters", {}).get("properties", {}).keys())
            break

    params: Dict[str, Any] = {}
    args_str = args_str.strip()
    if not args_str:
        return params

    try:
        tree = _ast.parse("_f(" + args_str + ")", mode="eval")
        call = tree.body
        for i, arg in enumerate(call.args):
            key = param_names[i] if i < len(param_names) else ("arg" + str(i))
            params[key] = _ast.literal_eval(arg)
        for kw in call.keywords:
            params[kw.arg] = _ast.literal_eval(kw.value)
    except Exception:
        pass

    return params


def json_variants(raw: str):
    """Yield progressively-cleaned forms of a candidate JSON fragment."""
    yield raw
    # Strip simple trailing commas that break json.loads.
    yield re.sub(r",(\s*[}\]])", r"\1", raw)
    # Replace smart quotes with standard ones.
    yield (raw.replace("“", '"').replace("”", '"')
           .replace("‘", "'").replace("’", "'"))


def _gather_candidates(response: str, tool_defs) -> List[str]:
    """Collect all JSON-object substrings that could plausibly be a tool call."""
    candidates: List[str] = []

    # 1. Preferred: <tool>…</tool>, plus <tool_call> / <function_call>.
    for m in _TAG_RE.finditer(response):
        body = m.group(2)
        candidates.extend(extract_json_objects(body))
        repaired = repair_hybrid_tool_call(body)
        if repaired:
            candidates.append(repaired)

    # 1b. Free-text hybrid (no wrapping tag) — repair whole response.
    if "<parameters>" in response.lower():
        repaired_all = repair_hybrid_tool_call(response)
        if repaired_all:
            candidates.append(repaired_all)

    # 2. ```json { … } ``` fences (some coder models love these).
    for m in re.finditer(r"```(?:json|tool)?\s*(\{.*?\})\s*```", response, re.DOTALL):
        candidates.extend(extract_json_objects(m.group(1)))

    # 3. Any JSON-looking object in free text that mentions "tool" or "name".
    candidates.extend(
        obj for obj in extract_json_objects(response)
        if '"tool"' in obj or '"name"' in obj
    )

    # 4. Python-style call: tool_name("arg") or tool_name(param="value").
    if tool_defs:
        _known = {td["function"]["name"] for td in tool_defs if "function" in td}
        for m in re.finditer(r'\b([a-z_][a-z0-9_]*)\s*\(([^)]*)\)', response):
            if m.group(1) in _known:
                _pargs = parse_python_call_args(m.group(1), m.group(2), tool_defs)
                candidates.append(
                    json.dumps({"tool": m.group(1), "parameters": _pargs})
                )

    return candidates


def parse_all_tag_tool_calls(response: str, tool_defs=None) -> List[Tuple[str, Dict[str, Any]]]:
    """Parse ALL tool invocations out of the model reply.

    Returns a list of (name, params) tuples, deduplicated by (name,
    canonical-params-json) so the free-text JSON scan doesn't re-pick up
    objects already captured inside <tool> tags.
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
            if not isinstance(data, dict):
                continue
            name = data.get("tool") or data.get("name")
            params = (data.get("parameters") or data.get("arguments") or data.get("args") or {})
            if isinstance(params, str):
                try:
                    params = json.loads(params)
                except json.JSONDecodeError:
                    params = {}
            if isinstance(name, str) and isinstance(params, dict):
                key = (name, json.dumps(params, sort_keys=True))
                if key not in seen:
                    seen.add(key)
                    results.append((name, params))
                break
    return results


def parse_tag_tool_call(response: str, tool_defs=None) -> Optional[Tuple[str, Dict[str, Any]]]:
    """Parse a single tool invocation. Returns the first valid match or None."""
    calls = parse_all_tag_tool_calls(response, tool_defs)
    return calls[0] if calls else None
