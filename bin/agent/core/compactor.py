"""Context-window compactor for the multi-agent workflow.

Why this exists
---------------
Tool results — especially ``list_files_recursive`` and ``read_file`` on
big files — can produce blobs orders of magnitude larger than the
model's context window. When that blob is fed back to the reasoner the
next iteration, the model silently drops the prompt and emits empty
tokens (most providers don't return a clean 413). The compactor
intercepts that condition before the reasoner is called.

Strategy (cheapest first)
-------------------------
1. **Estimate**: count tokens across ``state.history`` + the
   to-be-rendered ``state.tool_results`` block + ``max_tokens`` reply
   budget, using the same chars/4 heuristic as ``rate_limit``.
2. **Skip**: if under ``context_limit * SAFETY_FACTOR``, do nothing.
   Cheap conversations pay zero overhead.
3. **Elide oversized entries**: walk the messages from biggest to
   smallest, replacing each one's content with a short stub describing
   what was elided. Stops as soon as the budget fits. No LLM call.
4. **Summarize (optional)**: if a summarizer agent is configured AND
   eliding alone leaves us over budget, re-call the summarizer on the
   elided stubs to produce a single denser system message.

The summarizer path is wired in but stays opt-in — callers pass a
``summarizer`` callable that takes a string and returns a string. The
elide-only path is always available and is enough to keep the loop
alive in the failure mode that motivated this work.
"""
from __future__ import annotations

import logging
import sys
from collections import Counter
from typing import Any, Callable, Dict, List, Optional, Tuple

from ..utils.token_estimator import (
    estimate_messages_tokens,
    estimate_tokens,
    estimate_tokens_from_chars,
)


# Same factor the rate-limiter uses: leave headroom for output tokens
# and provider-side overhead the chars/4 estimator can't see.
SAFETY_FACTOR = 0.75

# Don't bother eliding anything smaller than this — it doesn't move the
# needle and just makes the trace noisier.
MIN_ELIDE_CHARS = 2_000

# When eliding OLD tool results (those outside the protected recent
# window), we use a much lower threshold. In long tool loops the model
# accumulates 30+ small results that individually look fine but compound
# to thousands of tokens — those need to go.
MIN_ELIDE_CHARS_OLD = 200

# Threshold for fold-old-stubs (Fix F). When we have more than this many
# tool_results in a single turn AND most of the older ones are already
# stubs from prior compaction passes, we collapse the prefix into one
# synthetic summary entry. Without this, 100+ stubs at ~150 chars each
# compound to ~4000 tokens of dead breadcrumb text per iteration.
FOLD_AFTER_N_RESULTS = 30
FOLD_KEEP_RECENT = 10
FOLD_MIN_STUB_RATIO = 0.5  # at least half of the prefix must be stubs


# Number of MOST RECENT tool results that survive the first elide pass.
# These are the ones the reasoner actually needs to keep making progress
# (especially the latest read_file output). If even after eliding all
# older results we're still over budget, the protection relaxes and the
# oldest of these gets elided too — graceful degradation.
PROTECT_RECENT_DEFAULT = 3

# Stub kept after eliding a tool result, so the reasoner still knows the
# call happened and can avoid re-issuing the same one.
_ELIDED_STUB = (
    "[tool result elided: {tool}({params}) returned {orig_chars} chars; "
    "exceeded model context window. Call a narrower tool or paginate.]"
)
_ELIDED_HISTORY_STUB = (
    "[message elided: {orig_chars} chars; exceeded model context window]"
)
_COMPACTED_FLAG = "_compacted"


logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Token estimation
# ---------------------------------------------------------------------------
def _estimate_text_tokens(text: str) -> int:
    """Content-aware token estimate for code-heavy tool output."""
    return estimate_tokens(text or "", content_type="code")


def _estimate_message_tokens(msg: Dict[str, Any]) -> int:
    content = msg.get("content")
    if isinstance(content, str):
        return estimate_tokens(content, content_type="code") + 10
    elif isinstance(content, list):
        total = 0
        for part in content:
            if isinstance(part, dict):
                total += estimate_tokens(str(part.get("text", "")), content_type="code")
        return total + 10
    return 10


def _estimate_tool_results_tokens(tool_results: List[Dict[str, Any]]) -> int:
    """Mirror reasoner._compose_user_block's formatting cost."""
    if not tool_results:
        return 0
    total = 0
    for r in tool_results:
        result = r.get("result", "")
        if isinstance(result, str):
            total += estimate_tokens(result, content_type="code")
        elif isinstance(result, dict):
            total += estimate_tokens(str(result), content_type="code")
        # tool name + params + index prefix overhead
        total += 20
    return total


def estimate_total_tokens(
    *,
    history: List[Dict[str, Any]],
    tool_results: Optional[List[Dict[str, Any]]] = None,
    shaped_prompt: str = "",
    user_input: str = "",
    max_tokens: int = 0,
    system_prompt_chars: int = 0,
) -> int:
    """Best-effort estimate of what reasoner._build_messages will send.

    Includes the reply budget so we reserve room for the model's output,
    not just the prompt.
    """
    total = 0
    for m in history or []:
        total += _estimate_message_tokens(m)
    total += _estimate_tool_results_tokens(tool_results or [])
    total += _estimate_text_tokens(shaped_prompt or user_input or "")
    total += estimate_tokens_from_chars(system_prompt_chars, content_type="code")
    total += int(max_tokens or 0)
    return total


# ---------------------------------------------------------------------------
# Elide pass (no LLM)
# ---------------------------------------------------------------------------
def _result_chars(r: Dict[str, Any]) -> int:
    raw = r.get("result", "")
    if isinstance(raw, str):
        return len(raw)
    if isinstance(raw, dict):
        return len(str(raw))
    return 0


def _msg_chars(m: Dict[str, Any]) -> int:
    c = m.get("content")
    if isinstance(c, str):
        return len(c)
    if isinstance(c, list):
        return sum(len(str(p.get("text", ""))) for p in c if isinstance(p, dict))
    return 0


def _elide_one_tool_result(
    tool_results: List[Dict[str, Any]],
    idx: int,
    actions: List[str],
) -> int:
    """Replace tool_results[idx] with a stub. Returns chars saved."""
    r = tool_results[idx]
    orig_chars = _result_chars(r)
    if orig_chars == 0:
        return 0
    tool = r.get("tool", "?")
    params = r.get("parameters") or {}
    try:
        import json as _json
        params_str = _json.dumps(params, ensure_ascii=False)
        if len(params_str) > 120:
            params_str = params_str[:120] + "..."
    except Exception:
        params_str = str(params)[:120]
    stub = _ELIDED_STUB.format(
        tool=tool, params=params_str, orig_chars=orig_chars,
    )
    r["result"] = stub
    actions.append(
        f"elided tool_result[{idx}] {tool} ({orig_chars} chars -> "
        f"{len(stub)})"
    )
    return max(0, orig_chars - len(stub))


def _elide_one_history(
    history: List[Dict[str, Any]],
    idx: int,
    actions: List[str],
) -> int:
    m = history[idx]
    orig_chars = _msg_chars(m)
    if orig_chars == 0:
        return 0
    role = m.get("role", "?")
    stub = _ELIDED_HISTORY_STUB.format(orig_chars=orig_chars)
    m["content"] = stub
    m[_COMPACTED_FLAG] = True
    actions.append(
        f"elided history[{idx}] role={role} ({orig_chars} chars -> "
        f"{len(stub)})"
    )
    return max(0, orig_chars - len(stub))


def elide_oversized(
    *,
    history: List[Dict[str, Any]],
    tool_results: List[Dict[str, Any]],
    target_tokens: int,
    current_tokens: int,
    protect_recent: int = PROTECT_RECENT_DEFAULT,
) -> Tuple[int, List[str]]:
    """Replace older / bigger entries with stubs until we fit ``target_tokens``.

    Mutates ``history`` and ``tool_results`` in place. Returns the new
    estimated token count and a list of human-readable trace lines.

    Strategy (death-spiral aware):

      1. **Protect the last N tool results.** The reasoner needs the
         most recent results to make progress — especially the latest
         read_file. Without this, the model loses sight of what it
         just fetched, re-issues the same call, and we hit an infinite
         loop. ``protect_recent`` controls N.

      2. **Aggressively elide older tool results.** Use a low threshold
         (``MIN_ELIDE_CHARS_OLD``) so even small accumulated entries
         get folded — at iteration 50 of a tool loop, fifty 300-char
         results compound to ~3700 tokens of dead weight.

      3. **Elide oversized history messages** (system summaries,
         compacted prior-turn blobs) using the normal ``MIN_ELIDE_CHARS``
         threshold. Don't touch tiny ones — losing a real user message
         hurts more than the few tokens it saves.

      4. **Graceful degradation.** If after all that we're still over
         budget, start eliding from the protected window too — oldest
         protected first. Better to risk the loop than to send a
         prompt the model will silently drop.
    """
    actions: List[str] = []
    if current_tokens <= target_tokens:
        return current_tokens, actions

    n_results = len(tool_results)
    protect_from = max(0, n_results - protect_recent)

    # ── Pass 1: aggressively elide OLD tool_results (idx < protect_from)
    # Sort by size desc so we knock out the biggest old entries first
    # but DON'T skip small ones — they compound.
    old_candidates: List[Tuple[int, int]] = []
    for i in range(protect_from):
        sz = _result_chars(tool_results[i])
        if sz >= MIN_ELIDE_CHARS_OLD:
            old_candidates.append((sz, i))
    old_candidates.sort(reverse=True)

    for _sz, idx in old_candidates:
        if current_tokens <= target_tokens:
            return current_tokens, actions
        saved = _elide_one_tool_result(tool_results, idx, actions)
        current_tokens -= saved // 4

    # ── Pass 2: elide oversized history messages (system summaries etc).
    history_candidates: List[Tuple[int, int]] = []
    for i, m in enumerate(history):
        if m.get(_COMPACTED_FLAG):
            continue
        sz = _msg_chars(m)
        if sz < MIN_ELIDE_CHARS:
            continue
        priority = sz
        role = m.get("role", "")
        content_preview = (
            (m.get("content", "") or "")[:60]
            if isinstance(m.get("content"), str) else ""
        )
        if role == "system" and "Prior turn tool history" in content_preview:
            priority = sz * 2  # attack first
        history_candidates.append((priority, i))
    history_candidates.sort(reverse=True)

    for _priority, idx in history_candidates:
        if current_tokens <= target_tokens:
            return current_tokens, actions
        saved = _elide_one_history(history, idx, actions)
        current_tokens -= saved // 4

    # ── Pass 3: elide the BIG protected results too (still keeping
    # the very latest one if possible). Walk oldest-first within the
    # protected window so the freshest survives longest.
    if current_tokens > target_tokens and protect_from < n_results:
        for i in range(protect_from, n_results):
            # Always try to keep the absolute last one.
            if i == n_results - 1 and len(actions) > 0:
                # Only sacrifice the latest if we've already done
                # everything else and we're still over.
                continue
            if current_tokens <= target_tokens:
                return current_tokens, actions
            sz = _result_chars(tool_results[i])
            if sz < MIN_ELIDE_CHARS_OLD:
                continue
            saved = _elide_one_tool_result(tool_results, i, actions)
            current_tokens -= saved // 4

        # Last resort: even the freshest entry has to go.
        if current_tokens > target_tokens and n_results > 0:
            i = n_results - 1
            sz = _result_chars(tool_results[i])
            if sz >= MIN_ELIDE_CHARS_OLD:
                saved = _elide_one_tool_result(tool_results, i, actions)
                current_tokens -= saved // 4

    return current_tokens, actions


def _is_stub_result(r: Dict[str, Any]) -> bool:
    """True if this tool_result has already been replaced by an elide stub."""
    raw = r.get("result", "")
    if not isinstance(raw, str):
        return False
    return raw.startswith("[tool result elided")


def fold_old_stubs(
    tool_results: List[Dict[str, Any]],
    *,
    keep_recent: int = FOLD_KEEP_RECENT,
    min_total: int = FOLD_AFTER_N_RESULTS,
    min_stub_ratio: float = FOLD_MIN_STUB_RATIO,
    actions: Optional[List[str]] = None,
) -> int:
    """Collapse a long prefix of mostly-stub tool_results into one entry.

    Solves the "death by a thousand stubs" problem observed in long
    tool loops: by iteration ~100 every old result is already a 150-char
    stub, but 100 × 150 = 15,000 chars (~3,750 tokens) of dead
    breadcrumb that the elide pass can't shrink further. Folding gives
    the model one breadcrumb saying *what was tried* instead of N
    individual stubs.

    Mutates ``tool_results`` in place. Returns chars saved (for logging).
    No-op when:
      - there are fewer than ``min_total`` results, OR
      - fewer than ``min_stub_ratio`` of the prefix are stubs (we don't
        want to fold real, useful results just because there are many).
    """
    n = len(tool_results)
    if n < min_total or n <= keep_recent:
        return 0

    prefix = tool_results[:n - keep_recent]
    suffix = tool_results[n - keep_recent:]

    stub_count = sum(1 for r in prefix if _is_stub_result(r))
    if stub_count < int(len(prefix) * min_stub_ratio):
        return 0  # mostly real content; fold would be lossy.

    # Tally what was attempted so the model has a breadcrumb.
    tool_counts = Counter(str(r.get("tool", "?")) for r in prefix)
    paths_seen: set = set()
    patterns_seen: set = set()
    for r in prefix:
        params = r.get("parameters") or {}
        if isinstance(params, dict):
            p = params.get("path") or params.get("destination") or ""
            if p and isinstance(p, str):
                paths_seen.add(p[:60])
            pat = params.get("pattern")
            if pat and isinstance(pat, str):
                patterns_seen.add(pat[:40])

    tool_summary = ", ".join(
        f"{t}*{c}" for t, c in tool_counts.most_common(8)
    )
    paths_list = sorted(paths_seen)
    paths_str = ", ".join(paths_list[:8])
    if len(paths_list) > 8:
        paths_str += f", +{len(paths_list) - 8} more"
    patterns_list = sorted(patterns_seen)
    patterns_str = ", ".join(patterns_list[:6])
    if len(patterns_list) > 6:
        patterns_str += f", +{len(patterns_list) - 6} more"

    summary_result = (
        f"[{len(prefix)} prior tool calls this turn — already executed and "
        f"elided to fit context. Tools: {tool_summary or '(none)'}. "
        f"Files touched: {paths_str or '(none)'}. "
        f"Patterns searched: {patterns_str or '(none)'}. "
        "Do NOT repeat these calls. Use the most recent results below or "
        "produce a final answer.]"
    )

    folded_entry = {
        "tool": "_compacted_history",
        "parameters": {"folded_count": len(prefix)},
        "result": summary_result,
    }

    chars_before = sum(
        len(str(r.get("result", ""))) for r in prefix
    )
    chars_after = len(summary_result)
    chars_saved = max(0, chars_before - chars_after)

    # In-place replace.
    tool_results.clear()
    tool_results.append(folded_entry)
    tool_results.extend(suffix)

    if actions is not None:
        actions.append(
            f"folded {len(prefix)} old stubs into 1 summary entry "
            f"(saved ~{chars_saved // 4} tokens; kept latest "
            f"{len(suffix)} intact)"
        )

    return chars_saved


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------
def compact_if_needed(
    state,
    *,
    context_limit: int,
    max_tokens: int,
    system_prompt_chars: int = 0,
    summarizer: Optional[Callable[[str], str]] = None,
    safety_factor: float = SAFETY_FACTOR,
) -> Optional[Dict[str, Any]]:
    """Inspect ``state`` and shrink it in place if it would overflow.

    Returns ``None`` when no action was taken (under budget). Returns a
    dict describing what happened when compaction ran — the caller can
    record this on ``state.trace``.

    Parameters
    ----------
    state
        WorkflowState. Mutated in place: ``state.history`` and
        ``state.tool_results`` may have their large entries replaced
        with stubs.
    context_limit
        The reasoner backend's effective context window.
    max_tokens
        The reasoner's reply budget. Reserved on top of the prompt so
        the model has room to answer.
    system_prompt_chars
        Length of the agent's system prompt. Counted once.
    summarizer
        Optional callable ``(text) -> summary``. If provided AND eliding
        alone doesn't fit, the elided content gets folded into a single
        summarizer call. Skip by passing ``None`` to keep cost zero.
    safety_factor
        Fraction of ``context_limit`` we actually target. 0.75 leaves
        room for output tokens and chars/4 estimator drift.
    """
    if not context_limit or context_limit <= 0:
        return None

    target = int(context_limit * safety_factor)
    history = list(getattr(state, "history", None) or [])
    tool_results = list(getattr(state, "tool_results", None) or [])
    shaped = getattr(state, "shaped_prompt", "") or ""
    user_input = getattr(state, "user_input", "") or ""

    current = estimate_total_tokens(
        history=history,
        tool_results=tool_results,
        shaped_prompt=shaped,
        user_input=user_input,
        max_tokens=max_tokens,
        system_prompt_chars=system_prompt_chars,
    )

    # Lazy compaction: only compact if we're within 20% of the limit.
    # This avoids unnecessary overhead on every iteration when the
    # context is well under the budget.
    lazy_threshold = int(target * 0.8)
    if current <= lazy_threshold:
        return None

    actions: List[str] = []
    before = current

    # Step 0: fold a long prefix of mostly-stub tool_results into one
    # synthetic summary entry. Catches the "death by a thousand stubs"
    # pattern: by iteration ~100 every old result is already a stub
    # but they compound to thousands of tokens of dead breadcrumbs.
    # Done BEFORE eliding so the elide pass operates on a sane number
    # of entries; also re-estimates the budget afterwards because
    # folding can save thousands of tokens by itself.
    if state.tool_results:
        fold_old_stubs(state.tool_results, actions=actions)
        # Re-estimate after fold — usually drops current by a lot.
        current = estimate_total_tokens(
            history=state.history,
            tool_results=state.tool_results,
            shaped_prompt=shaped,
            user_input=user_input,
            max_tokens=max_tokens,
            system_prompt_chars=system_prompt_chars,
        )

    # Step 1: elide oversized entries in-place.
    if current > target:
        current, elide_actions = elide_oversized(
            history=state.history,
            tool_results=state.tool_results,
            target_tokens=target,
            current_tokens=current,
        )
        actions.extend(elide_actions)

    # Step 2: optional summarizer. Only fires when eliding wasn't enough
    # AND the caller actually configured one.
    if current > target and summarizer is not None:
        try:
            current = _summarize_history(
                state, summarizer=summarizer,
                target_tokens=target, current_tokens=current,
                actions=actions,
            )
        except Exception as e:  # noqa: BLE001
            logger.warning("Summarizer failed; keeping elided content: %s", e)
            actions.append(f"summarizer-error: {e}")

    summary = {
        "before_tokens": before,
        "after_tokens": current,
        "target_tokens": target,
        "context_limit": context_limit,
        "actions": actions,
    }

    # Surface to stderr so the orchestrator log shows compaction events.
    if actions:
        print(
            f"[compactor] {before}->{current} tokens (target {target}, "
            f"limit {context_limit}); {len(actions)} action(s)",
            file=sys.stderr, flush=True,
        )
        for a in actions:
            print(f"[compactor]   {a}", file=sys.stderr, flush=True)

    return summary


def _summarize_history(
    state,
    *,
    summarizer: Callable[[str], str],
    target_tokens: int,
    current_tokens: int,
    actions: List[str],
) -> int:
    """Fold older history into a single summary system message.

    Keeps the most recent user/assistant turn intact (the reasoner
    needs that verbatim) and replaces everything before it with one
    ``[Conversation summary so far]`` system message produced by the
    summarizer callable.
    """
    history = state.history
    if len(history) <= 2:
        return current_tokens

    # Find the index of the last user turn — keep that and everything
    # after intact.
    last_user_idx = None
    for i in range(len(history) - 1, -1, -1):
        if history[i].get("role") == "user":
            last_user_idx = i
            break
    if last_user_idx is None or last_user_idx == 0:
        return current_tokens

    older = history[:last_user_idx]
    keep = history[last_user_idx:]

    # Build the text to summarize.
    blocks: List[str] = []
    for m in older:
        role = m.get("role", "?")
        content = m.get("content", "")
        if isinstance(content, str) and content:
            blocks.append(f"[{role}]\n{content}")
    if not blocks:
        return current_tokens

    raw = "\n\n".join(blocks)
    summary_text = summarizer(raw).strip()
    if not summary_text:
        return current_tokens

    summary_msg = {
        "role": "system",
        "content": (
            "[Conversation summary so far — older turns compacted to fit "
            "context window]\n" + summary_text
        ),
        _COMPACTED_FLAG: True,
    }
    state.history = [summary_msg] + keep

    # Recompute.
    new_total = estimate_total_tokens(
        history=state.history,
        tool_results=getattr(state, "tool_results", None) or [],
        shaped_prompt=getattr(state, "shaped_prompt", "") or "",
        user_input=getattr(state, "user_input", "") or "",
        max_tokens=0,  # reply budget already counted upstream
    )
    saved = current_tokens - new_total
    actions.append(
        f"summarized {len(older)} older messages -> 1 system summary "
        f"(saved ~{max(0, saved)} tokens)"
    )
    return new_total
