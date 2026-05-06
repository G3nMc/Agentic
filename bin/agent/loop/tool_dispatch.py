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
    r"</?(?:plaintext|pre|code|html|body|p|span|div|tool|tool_call|function_call|function|parameter)\b[^>]*>",
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

    # Strip a single surrounding quoted string, if the whole answer is wrapped.
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
    """True if the reply opens a tool tag or tool JSON without closing it."""
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

    if "```json" in text.lower() and text.count("```") % 2 == 1:
        if '"tool"' in text or "'tool'" in text:
            return True

    if '"tool"' in text and text.count("{") > text.count("}"):
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
    low = text.lower()

    if "<tool" in low or "<tool_call" in low or "<function_call" in low or "<function" in low:
        return True
    if '"tool"' in text or "'tool'" in text:
        return True
    if '"parameters"' in text or "'parameters'" in text:
        return True
    if "```json" in low or "```tool" in low:
        return True
    if "<parameter" in low or "<parameters" in low:
        return True
    if re.search(r"\b(tool|function|function_call|tool_call)\s*[:=]", low):
        return True
    return False


def looks_like_malformed_tool_call(text: str) -> Tuple[bool, str | None]:
    """Detect output that appears to be a tool call but is malformed."""
    if not text:
        return False, None

    if not _looks_like_tool_attempt(text):
        return False, None

    # If we can already parse a valid tool call, it is not malformed.
    if parse_all_tag_tool_calls(text):
        return False, None

    correct_format = (
        'Correct format: {"tool":"tool_name","parameters":{"key":"value"}} '
        'or <tool>{"tool":"tool_name","parameters":{...}}</tool>'
    )

    # Common syntax mistakes.
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

    if "<tool" in text and "</tool>" not in text:
        return True, (
            f"Malformed tool call: Unclosed <tool> tag. Either close it with </tool> or use JSON format. {correct_format}"
        )

    if '"parameters"' in text and '"tool"' in text and text.count("{") > text.count("}"):
        missing = text.count("{") - text.count("}")
        return True, (
            f"Malformed tool call: Missing {missing} closing brace(s). {correct_format}"
        )

    if re.search(r'"parameters"\s*>', text):
        return True, (
            f"Malformed tool call: Invalid syntax after 'parameters' key. Use ':' not '>'. {correct_format}"
        )

    # Strong tool attempt, but parser could not make sense of it.
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

    # A couple of common Python-ish fallbacks.
    lowered = s.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if lowered == "null":
        return None

    return s


_OPEN_TAG_RE = re.compile(
    r"<(?P<tag>tool|tool_call|function_call|function)"
    r"(?:\s*(?:=|:)\s*(?P<name>[a-zA-Z_][\w\-]*))?[^>]*>",
    re.IGNORECASE,
)

_PARAM_TAG_RE = re.compile(
    r"<parameter(?:\s*(?:=|:)\s*(?P<name>[a-zA-Z_][\w\-]*))\s*>"
    r"(?P<value>.*?)"
    r"</parameter>",
    re.IGNORECASE | re.DOTALL,
    )

_HYBRID_RE = re.compile(
    r'["\']?(?:tool|name)["\']?\s*["\':=]\s*["\']([a-zA-Z_][\w\-]*)["\']'
    r'[^<{]*?<\s*(?:parameters|parameter)\s*>?\s*(\{.*?\})',
    re.DOTALL | re.IGNORECASE,
    )

_WRAPPER_LEAK_KEYS = ("parameters", "arguments", "args", "tool", "name", "function")


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


def _tool_defs_iter(tool_defs):
    if not tool_defs:
        return []
    return tool_defs


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

        score = overlap * 10 + (5 if param_keys.issubset(prop_keys) else 0)
        if score > best_score:
            best_score = score
            best_name = name

    return best_name


def _decode_embedded_tool_call(name_value: Any) -> Optional[Tuple[str, Dict[str, Any]]]:
    """
    Decode malformed tool-name payloads that embed a full call object.
    """
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

    # Pass 1: unwrap the whole payload if the only useful content is nested.
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

    return cleaned


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

    # Tool name.
    tool_name = data.get("tool") or data.get("name")

    function_call = data.get("function_call")
    if isinstance(function_call, dict):
        tool_name = tool_name or function_call.get("name")
        if "arguments" in function_call and "parameters" not in data:
            data = dict(data)
            data["parameters"] = function_call.get("arguments")

    function_obj = data.get("function")
    if isinstance(function_obj, dict):
        tool_name = tool_name or function_obj.get("name")
        if "arguments" in function_obj and "parameters" not in data:
            data = dict(data)
            data["parameters"] = function_obj.get("arguments")
        if "parameters" in function_obj and "parameters" not in data:
            data = dict(data)
            data["parameters"] = function_obj.get("parameters")
    elif isinstance(function_obj, str) and function_obj:
        tool_name = tool_name or function_obj

    type_value = data.get("type")
    if isinstance(type_value, str) and type_value not in {
        "function",
        "tool_call",
        "function_call",
    }:
        tool_name = tool_name or type_value

    if isinstance(tool_name, str) and tool_name:
        result["tool"] = tool_name

    # Parameters.
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


def repair_hybrid_tool_call(text: str) -> Optional[str]:
    """
    Repair common malformed patterns where a model mixes JSON and XML.
    Returns a valid JSON string or None.
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

        # Trim params_raw to the first balanced object.
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


def _gather_candidates(response: str, tool_defs) -> List[str]:
    """Collect all candidate tool-call fragments from the model reply."""
    candidates: List[str] = []
    seen_fragments: set = set()

    def add_candidate(fragment: str):
        fragment = (fragment or "").strip()
        if fragment and fragment not in seen_fragments:
            seen_fragments.add(fragment)
            candidates.append(fragment)

    # 1. XML-ish blocks.
    for tag, opener_name, body in _iter_xmlish_blocks(response):
        repaired = repair_hybrid_tool_call(
            f"<{tag}{'=' + opener_name if opener_name else ''}>{body}</{tag}>"
        )
        if repaired:
            add_candidate(repaired)

        for obj in extract_json_objects(body):
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

    # 1b. Free-text hybrid repair over the whole response.
    repaired_all = repair_hybrid_tool_call(response)
    if repaired_all:
        add_candidate(repaired_all)

    # 2. Fenced JSON blocks.
    for m in re.finditer(
            r"```(?:json|tool)?\s*({.*?\})\s*```",
            response,
            re.DOTALL | re.IGNORECASE,
    ):
        for obj in extract_json_objects(m.group(1)):
            add_candidate(obj)

    # 3. Any JSON-looking object in free text that mentions tool/name/type.
    for obj in extract_json_objects(response):
        if '"tool"' in obj or '"name"' in obj or '"type"' in obj:
            add_candidate(obj)

    # 4. Python-style calls.
    if tool_defs:
        known = {
            name
            for td in _tool_defs_iter(tool_defs)
            for name, _schema in (_tool_name_and_schema(td),)
            if isinstance(name, str) and name
        }

        for m in re.finditer(r"\b([a-zA-Z_][a-zA-Z0-9_]*)\s*\(([^)]*)\)", response):
            func_name = m.group(1)
            if func_name in known:
                pargs = parse_python_call_args(func_name, m.group(2), tool_defs)
                add_candidate(json.dumps({"tool": func_name, "parameters": pargs}))

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