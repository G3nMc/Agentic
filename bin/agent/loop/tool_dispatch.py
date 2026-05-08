"""Pure helpers for parsing tool calls out of model replies.

All functions here are stateless and module-level so they can be called
from the run loop without dragging the Orchestrator class along.
"""
from __future__ import annotations

import ast
import json
import re
import sys
from typing import Any, Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Output-cleaning regexes
# ---------------------------------------------------------------------------

JUNK_TAG_PATTERN = re.compile(
    r"</?(?:plaintext|pre|code|html|body|p|span|div|tool|tool_call|function_call|function|parameter|parameters|arg_key|arg_value|arg_name)\b[^>]*>",
    re.IGNORECASE,
)

THINK_PATTERN = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)

CHAT_TEMPLATE_TOKEN_PATTERN = re.compile(r"<\|[^|>]{0,80}\|>")

STRAY_THINK_CLOSE_PATTERN = re.compile(r"^\s*</think>\s*", re.IGNORECASE)


def clean_history_text(text: str) -> str:
    """Clean assistant text before storing it in conversation history."""
    if not text:
        return text
    cleaned = THINK_PATTERN.sub("", text)
    cleaned = CHAT_TEMPLATE_TOKEN_PATTERN.sub("", cleaned)
    cleaned = STRAY_THINK_CLOSE_PATTERN.sub("", cleaned).strip()
    return cleaned


def clean_final_answer(text: str) -> str:
    """Clean the final text returned to the user.

    <think> blocks are intentionally preserved here so the UI can render
    them if desired.
    """
    if not text:
        return text

    cleaned = JUNK_TAG_PATTERN.sub("", text)
    cleaned = CHAT_TEMPLATE_TOKEN_PATTERN.sub("", cleaned)
    cleaned = STRAY_THINK_CLOSE_PATTERN.sub("", cleaned)
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned).strip()

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

def _count_exact_tag(text: str, tag: str) -> int:
    if not text:
        return 0
    return len(re.findall(rf"<\s*{re.escape(tag)}(?=[\s>/=:]|$)", text, re.IGNORECASE))


def looks_like_unclosed_tool(text: str) -> bool:
    """True if the reply opens a tool tag or tool JSON without closing it."""
    if not text:
        return False

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

    return False


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

    # Check for explicit tool tags or JSON structures
    if re.search(r"<\s*(?:tool|tool_call|function_call|function)(?=[\s>/=:]|$)", text, re.IGNORECASE):
        return True
    if re.search(r"</\s*(?:tool|tool_call|function_call|function)\s*>", text, re.IGNORECASE):
        return True

    # Require a more specific pattern for JSON-like structures
    if re.search(r'["\']tool["\']\s*:\s*["\']\w+["\']', text):
        return True

    if re.search(r"\b(?:tool_call|function_call)\s*[:=]\s*['\"]\w+['\"]", text, re.IGNORECASE):
        return True

    if re.search(r"```(?:json|tool)\b", text, re.IGNORECASE):
        return True

    return False


def looks_like_malformed_tool_call(text: str) -> Tuple[bool, str | None]:
    """Detect output that appears to be a tool call but is malformed."""
    if not text:
        return False, None

    if not _looks_like_tool_attempt(text):
        return False, None

    if parse_all_tag_tool_calls(text):
        return False, None

    correct_format = (
        'Correct format: {"tool":"tool_name","parameters":{"key":"value"}} '
        'or <tool>{"tool":"tool_name","parameters":{...}}</tool>'
    )

    if re.search(r'"\w+"\s*>', text):
        return True, (
            f"Malformed tool call: JSON syntax error. Found '\"key\">' instead of '\"key\":'. "
            f"{correct_format}"
        )

    if re.search(r'\{\s*["\']tool["\']', text) and not text.rstrip().endswith("}"):
        return True, (
            f"Malformed tool call: Unclosed JSON object. The tool call starts with '{{' but does not end with '}}'. "
            f"{correct_format}"
        )

    if re.search(r'\{[^}]*"\w+"\s*>', text):
        return True, (
            f"Malformed tool call: Invalid JSON syntax. Found '>' instead of ':' as a key-value separator. "
            f"{correct_format}"
        )

    if re.search(r'"tool"\s*"[a-zA-Z_]+"', text) and '"tool":' not in text:
        return True, (
            f"Malformed tool call: Missing colon after 'tool' key. {correct_format}"
        )

    if re.search(r"<\s*(?:tool|tool_call|function_call|function)(?=[\s>/=:]|$)", text, re.IGNORECASE) and not re.search(
            r"</\s*(?:tool|tool_call|function_call|function)\s*>", text, re.IGNORECASE
    ):
        return True, (
            f"Malformed tool call: Unclosed tool tag. Either close it properly or use JSON format. {correct_format}"
        )

    if re.search(r'["\']parameters["\']\s*>', text):
        return True, (
            f"Malformed tool call: Invalid syntax after 'parameters' key. Use ':' not '>'. {correct_format}"
        )

    return True, (
        f"Malformed tool call: The reply looks like a tool invocation but could not be parsed. "
        f"{correct_format}"
    )


# ---------------------------------------------------------------------------
# Tool-call parsing
# ---------------------------------------------------------------------------

def json_variants(raw: str):
    """Yield progressively cleaned forms of a candidate JSON fragment."""
    yield raw
    yield re.sub(r",(\s*[}\]])", r"\1", raw)
    yield (
        raw.replace("“", '"')
        .replace("”", '"')
        .replace("‘", "'")
        .replace("’", "'")
    )


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
                    out.append(text[start:i + 1])
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
    r"(?:\s*(?:=|:)\s*(?P<name>[a-zA-Z_][\w\-]*))?[^>]*>",
    re.IGNORECASE,
)

_PARAM_TAG_RE = re.compile(
    r"<(?P<tag>parameter|parameters)(?=[\s>/=:]|$)"
    r"(?:\s*(?:=|:)\s*(?P<name>[a-zA-Z_][\w\-]*))?\s*>"
    r"(?P<value>.*?)"
    r"</\s*(?P=tag)\s*>",
    re.IGNORECASE | re.DOTALL,
    )

_HYBRID_RE = re.compile(
    r'["\']?(?:tool|name)["\']?\s*["\':=]\s*["\']([a-zA-Z_][\w\-]*)["\']'
    r'[^<{]*?<\s*(?:parameters|parameter)\b[^>]*>\s*(\{.*?\})',
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

        body = text[m.end():close_m.start()]
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
    if "<arg_value>" not in low and "<arg_key>" not in low and "</arg_value>" not in low:
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


def _tool_name_and_schema(defn: Dict[str, Any]) -> Tuple[Optional[str], Optional[Dict[str, Any]]]:
    """Extract tool name and parameter schema from a tool definition."""
    if not isinstance(defn, dict):
        return None, None

    fn = defn.get("function")
    if isinstance(fn, dict):
        name = fn.get("name")
        schema = fn.get("parameters") if isinstance(fn.get("parameters"), dict) else None
        return name, schema

    name = defn.get("name")
    if isinstance(name, str):
        schema = defn.get("parameters") if isinstance(defn.get("parameters"), dict) else None
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

        if overlap < 2 and len(prop_keys) > 2 and not required:
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
    emb_params = embedded.get("arguments") or embedded.get("parameters") or embedded.get("args") or {}

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

            is_empty = (
                    v in (None, "", {}, [])
                    or (isinstance(v, str) and not v.strip())
            )

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
                    k in data for k in ("parameters", "params", "arguments", "args", "input")
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
        "tool", "type", "name", "function", "function_call",
        "parameters", "params", "arguments", "args", "input",
    }
    for key, value in data.items():
        if key not in skip_keys:
            result[key] = value

    return result


def _normalize_tool_spec(data: Dict[str, Any], tool_defs) -> Optional[Tuple[str, Dict[str, Any]]]:
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
    has_function_obj = isinstance(data.get("function"), dict) or isinstance(data.get("function"), str)
    has_params = any(k in keys for k in ("parameters", "params", "arguments", "args", "input"))
    type_value = data.get("type")
    known_type = isinstance(type_value, str) and type_value.lower() in {"function", "tool_call", "function_call"}

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
            inferred_name = opener_name or _infer_tool_name_from_params(params, tool_defs)
            if inferred_name:
                add_candidate(json.dumps({"tool": inferred_name, "parameters": params}))

    repaired_all = repair_hybrid_tool_call(response)
    if repaired_all:
        add_candidate(repaired_all)

    for m in re.finditer(
            r"```(?:json|tool)?\s*({.*?\})\s*```",
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
        call = tree.body

        for i, arg in enumerate(call.args):
            key = param_names[i] if i < len(param_names) else f"arg{i}"
            params[key] = ast.literal_eval(arg)

        for kw in call.keywords:
            params[kw.arg] = ast.literal_eval(kw.value)
    except Exception:
        pass

    return params


def parse_all_tag_tool_calls(response: str, tool_defs=None) -> List[Tuple[str, Dict[str, Any]]]:
    """Parse all tool invocations out of the model reply."""
    if not response:
        return []

    candidates = _gather_candidates(response, tool_defs)

    results: List[Tuple[str, Dict[str, Any]]] = []
    seen: set = set()

    for raw in candidates:
        for cleaned in json_variants(raw):
            parsed = _maybe_parse_jsonish(cleaned)
            if not isinstance(parsed, dict):
                continue

            normalized = _normalize_tool_spec(parsed, tool_defs)
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