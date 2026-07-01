"""ModelBackend abstract base + the rate-limited decorator.

The decorator sits here (rather than under utils/) because it is
backend-typed: it implements the same chat() contract as a concrete
backend and is meant to wrap one. The rate-limiter primitive itself
lives in ``agent.utils.rate_limit`` — only the wrapper depends on it.
"""

from __future__ import annotations

import re

# import sys
from typing import Any, Dict, List, Optional, Tuple, Union

from ..utils.rate_limit import TokenBucket, estimate_tokens

# Forward-declared type for the conversation history. The actual class
# lives in ``agent.loop.history``; we import it lazily to avoid a
# circular dependency at module load time.
ConversationHistory = Any  # type alias — real class imported in chat()


class ModelBackend:
    """Strategy object that turns a chat self into (content, finish)."""

    def chat(
        self,
        conversation: "ConversationHistory",
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

    def chat(self, conversation, max_tokens, temperature, tools=None, stop=None, thinking=False, effort=None):
        import sys

        # Sanitize the conversation in-place before any logic.
        conversation.sanitize()

        if self.bucket.tpm_limit <= 0:
            return self.inner.chat(conversation, max_tokens, temperature, tools, stop=stop, thinking=thinking, effort=effort)

        # Token estimation from the flat message list.
        messages = conversation.to_messages()
        estimated = estimate_tokens(messages, max_tokens)
        limit = self.bucket.effective_limit()

        if estimated > limit:
            # Trim the conversation turns to fit the TPM budget.
            # ConversationHistory.trim_turns_to_budget mutates in-place.
            per_msg_tokens = max(2_500, limit // 10)
            conversation.trim_turns_to_budget(
                limit,
                content_type="code",
                max_msg_tokens=per_msg_tokens,
            )
            conversation.sanitize()

            messages = conversation.to_messages()
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
                conversation,
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

    @staticmethod
    def _parse_requested_tokens(err_msg: str) -> int:
        m = re.search(r"Requested\s+(\d+)", err_msg)
        return int(m.group(1)) if m else 0
