"""Sliding-window token-bucket rate limiter and prompt-size estimator.

The decorator that wraps a backend with the bucket lives in
``agent.backends.backend_base`` (RateLimitedBackend) — it depends on the
ModelBackend ABC, so it can't sit here without creating a cycle.
"""
from __future__ import annotations

import collections
import sys
import time
from typing import Tuple


def estimate_tokens(messages, max_tokens: int) -> int:
    """Cheap prompt-size estimate: chars/4 is within ~15% of the real
    tokenizer for English/code and avoids a tiktoken dependency. Adds the
    reply budget so we reserve for the response, not just the prompt."""
    total_chars = 0
    for m in messages or []:
        c = m.get("content")
        if isinstance(c, str):
            total_chars += len(c)
        elif isinstance(c, list):
            for part in c:
                if isinstance(part, dict):
                    total_chars += len(str(part.get("text", "")))
    # +10 per message as overhead for role tokens and separators.
    overhead = 10 * len(messages or [])
    return (total_chars // 4) + overhead + max_tokens


class TokenBucket:
    """Sliding 60-second window of (timestamp, tokens_used) entries."""

    WINDOW_SECONDS = 60.0
    # Use 95% of the nominal limit as the effective budget — the estimator
    # is imperfect and Groq counts a bit more than chars/4 suggests.
    SAFETY_FACTOR = 0.95

    def __init__(self, tpm_limit: int):
        self.tpm_limit = int(tpm_limit)
        self._entries: "collections.deque[Tuple[float, int]]" = collections.deque()

    def effective_limit(self) -> int:
        return int(self.tpm_limit * self.SAFETY_FACTOR)

    def expire(self, now: float) -> None:
        cutoff = now - self.WINDOW_SECONDS
        while self._entries and self._entries[0][0] < cutoff:
            self._entries.popleft()

    def used_in_window(self) -> int:
        now = time.time()
        self.expire(now)
        return sum(t for _, t in self._entries)

    def wait_for_budget(self, estimated_tokens: int) -> float:
        """Block until there is room for `estimated_tokens`. Returns the
        total seconds slept. Does NOT reserve — call `record` after the
        request actually completes."""
        if self.tpm_limit <= 0:
            return 0.0
        slept_total = 0.0
        while True:
            now = time.time()
            self.expire(now)
            used = sum(t for _, t in self._entries)
            if used + estimated_tokens <= self.effective_limit():
                return slept_total
            # Wait just past the moment the oldest entry expires.
            oldest_ts = self._entries[0][0]
            sleep_s = max(0.1, (oldest_ts + self.WINDOW_SECONDS) - now + 0.05)
            # Cap single sleep so the user gets a heartbeat line.
            sleep_s = min(sleep_s, 5.0)
            print(
                f"[orch] TPM limit: {used}/{self.effective_limit()} used, "
                f"need {estimated_tokens} — sleeping {sleep_s:.1f}s.",
                file=sys.stderr,
                flush=True,
            )
            time.sleep(sleep_s)
            slept_total += sleep_s

    def record(self, tokens_used: int) -> None:
        if self.tpm_limit <= 0 or tokens_used <= 0:
            return
        self._entries.append((time.time(), int(tokens_used)))
