"""ModelBackend abstract base + the rate-limited decorator.

The decorator sits here (rather than under utils/) because it is
backend-typed: it implements the same chat() contract as a concrete
backend and is meant to wrap one. The rate-limiter primitive itself
lives in ``agent.utils.rate_limit`` — only the wrapper depends on it.
"""

from __future__ import annotations

import re

# import sys
from typing import Any, Dict, List, Optional, Tuple

from ..utils.rate_limit import TokenBucket, estimate_tokens
from ..utils.text import sanitize_for_agent


class ModelBackend:
    """Strategy object that turns a chat self into (content, finish)."""

    def chat(
        self,
        messages: List[Dict[str, Any]],
        max_tokens: int,
        temperature: float,
        tools: Optional[List[Dict[str, Any]]] = None,
        stop: Optional[List[str]] = None,
        thinking: bool = False,
        effort: Optional[str] = None,
    ) -> Tuple[str, str]:
        # NOTE: ``stop`` is the set of strings the model should stop on
        # (the underlying API will not generate past any of them). The
        # orchestrator uses this to terminate generation right after the
        # first ``</tool>`` so models that hallucinate fake transcripts
        # in the rest of the reply cannot emit them. If you need to roll
        # back this behavior, search for ``[stop-sequence-fix]`` across
        # the codebase.
        raise NotImplementedError


class RateLimitedBackend(ModelBackend):
    """Decorator that gates calls to an inner backend with a TokenBucket.
    Also auto-trims oversize histories and retries once on 413."""

    def __init__(self, inner: ModelBackend, tpm_limit: int, label: str = ""):
        self.inner = inner
        self.bucket = TokenBucket(tpm_limit)
        self.label = label or inner.__class__.__name__
        # Expose common attributes so callers that introspect still work.
        self.model_id = getattr(inner, "model_id", "")

    def __getattr__(self, name):
        # Pass-through for health_check and any other backend-specific
        # methods the orchestrator setup calls.
        return getattr(self.inner, name)

    @property
    def context_limit(self) -> int:
        return self.inner.context_limit

    def chat(self, messages, max_tokens, temperature, tools=None, stop=None, thinking=False, effort=None):
        # [stop-sequence-fix] ``stop`` is forwarded verbatim to the inner
        # backend so callers (e.g. run_loop._call_model) can request
        # generation to stop at ``</tool>`` and similar markers.
        import sys

        # 🔥 CRITICAL FIX: sanitize BEFORE ANY logic (agent-safe, removes emoji)
        messages = sanitize_for_agent(messages)
        tools = sanitize_for_agent(tools)

        if self.bucket.tpm_limit <= 0:
            return self.inner.chat(messages, max_tokens, temperature, tools, stop=stop, thinking=thinking, effort=effort)

        # 🔥 CRITICAL FIX: safe estimation
        estimated = estimate_tokens(sanitize_for_agent(messages), max_tokens)
        limit = self.bucket.effective_limit()

        if estimated > limit:
            messages = self._trim_to_fit(messages, max_tokens, limit)

            # 🔥 sanitize AFTER trimming too (VERY IMPORTANT)
            messages = sanitize_for_agent(messages)

            estimated = estimate_tokens(messages, max_tokens)

            if estimated > limit:
                raise RuntimeError(
                    f"Single request ({estimated} est. tokens) exceeds TPM "
                    f"limit ({self.bucket.tpm_limit}) even after trimming. "
                    f"Reduce max_tokens or upgrade model quota."
                )

            print(
                f"[orch] Auto-trimmed self to fit TPM budget ({estimated}/{limit}).",
                file=sys.stderr,
                flush=True,
            )

        self.bucket.wait_for_budget(estimated)

        try:
            content, finish_reason = self.inner.chat(
                messages,
                max_tokens,
                temperature,
                tools,
                stop=stop,
                thinking=thinking,
                effort=effort,
            )

            # Note: Output content is NOT sanitized here to preserve markdown
            # formatting (emojis, icons, etc.) for the UI. Sanitization only
            # applies to inputs (messages/tools) sent to agents.

        except Exception as e:
            requested = self._parse_requested_tokens(str(e))

            if requested:
                self.bucket.record(requested)

                print(
                    f"[orch] 413 rate-limit: charged {requested} tokens.",
                    file=sys.stderr,
                    flush=True,
                )

            raise

        actual = getattr(self.inner, "last_usage_tokens", None)

        if not isinstance(actual, int) or actual <= 0:
            actual = estimated

        self.bucket.record(actual)

        return content, finish_reason

    # def chat(self, messages, max_tokens, temperature, tools=None):
    #     if self.bucket.tpm_limit <= 0:
    #         return self.inner.chat(messages, max_tokens, temperature, tools)
    #
    #     estimated = estimate_tokens(messages, max_tokens)
    #     limit = self.bucket._effective_limit()
    #
    #     # Single request bigger than the whole per-minute budget: no amount
    #     # of waiting helps. Auto-trim the oldest non-system messages and
    #     # retry. If it still won't fit after trimming to just the system
    #     # prompt + last user turn, surface a clear error.
    #     if estimated > limit:
    #         messages = self._trim_to_fit(messages, max_tokens, limit)
    #         estimated = estimate_tokens(messages, max_tokens)
    #         if estimated > limit:
    #             raise RuntimeError(
    #                 f"Single request ({estimated} est. tokens) exceeds the "
    #                 f"TPM limit of {self.bucket.tpm_limit} even after "
    #                 f"trimming self. Lower max_tokens, raise TPM in "
    #                 f"Settings, or pick a model with a larger quota."
    #             )
    #         print(
    #             f"[orch] Auto-trimmed self to fit TPM budget "
    #             f"({estimated}/{limit}).",
    #             file=sys.stderr,
    #             flush=True,
    #         )
    #
    #     self.bucket.wait_for_budget(estimated)
    #
    #     try:
    #         content, finish_reason = self.inner.chat(
    #             messages, max_tokens, temperature, tools
    #         )
    #     except Exception as e:
    #         # Groq / OpenAI-style 413: the body contains "Requested N". Use
    #         # that to bump the estimator by recording the real cost so the
    #         # next call waits the right amount, then re-raise.
    #         requested = self._parse_requested_tokens(str(e))
    #         if requested:
    #             self.bucket.record(requested)
    #             print(
    #                 f"[orch] 413 rate-limit: server reported "
    #                 f"{requested} tokens; charged the bucket.",
    #                 file=sys.stderr,
    #                 flush=True,
    #             )
    #         raise
    #
    #     # Record actual usage if the inner backend surfaced it as an
    #     # attribute (backends set `self.last_usage_tokens` when known),
    #     # otherwise fall back to the estimate.
    #     actual = getattr(self.inner, "last_usage_tokens", 0) or estimated
    #     self.bucket.record(actual)
    #     return content, finish_reason

    @staticmethod
    def _parse_requested_tokens(err_msg: str) -> int:
        m = re.search(r"Requested\s+(\d+)", err_msg)
        return int(m.group(1)) if m else 0

    @staticmethod
    def _trim_to_fit(messages, max_tokens: int, limit: int) -> List[Dict[str, Any]]:
        """Drop the oldest non-system messages until the estimate fits.
        Keeps the system prompt (index 0 if role=system) and the most
        recent user turn."""
        if not messages:
            return messages
        kept = list(messages)
        # Always keep system prompt if present at [0].
        head: List[Dict[str, Any]] = []
        if kept and kept[0].get("role") == "system":
            head = [kept.pop(0)]
        # Drop from the front (oldest) until it fits or only 1 msg left.
        while len(kept) > 1 and estimate_tokens(head + kept, max_tokens) > limit:
            kept.pop(0)
        return head + kept
