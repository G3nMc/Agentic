"""Shared REST/HTTP helpers for every model backend.

All backends in :mod:`agent.backends`, :mod:`common.backends` and
:mod:`multi_mode.backends` use this module to POST JSON to the
provider's API. No provider-specific SDK is imported here -- only the
``requests`` library, which is the single HTTP dependency for the
whole codebase.

Two streaming wire formats are supported because every provider uses
one or the other:

  - **SSE** (``text/event-stream``): OpenAI, Anthropic, OpenRouter,
    Groq, GitHub Models, HuggingFace Inference, Gemini (when called
    with ``?alt=sse``). Each event is a ``data: <json>`` line; the
    final marker is ``data: [DONE]`` for OpenAI-family and an empty
    line / connection close for others.

  - **NDJSON** (``application/x-ndjson``): Ollama's ``/api/generate``
    and ``/api/chat``. One JSON object per line.

The helpers always print a one-line ``[orch] heartbeat`` entry every
~5 seconds so the Flutter side's inactivity watchdog does not trip
during slow generations. Anything emitted to stderr that contains the
substring ``streaming`` resets the watchdog clock.
"""

from __future__ import annotations

import json
import sys
import time
from typing import Any, Dict, Iterable, Iterator, List, Optional, Tuple

import requests


# ---------------------------------------------------------------------------
# Custom exceptions
# ---------------------------------------------------------------------------


class HttpError(RuntimeError):
    """Generic non-retryable HTTP failure (4xx other than 429)."""


class RateLimitError(RuntimeError):
    """429 from upstream. ``retry_after`` is seconds; 0 means unknown."""

    def __init__(self, message: str, retry_after: float = 0.0) -> None:
        super().__init__(message)
        self.retry_after = retry_after


class ServerError(RuntimeError):
    """5xx from upstream. Retryable."""


# ---------------------------------------------------------------------------
# Logging helper
# ---------------------------------------------------------------------------


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# Core POST with retries
# ---------------------------------------------------------------------------


_DEFAULT_TIMEOUT = (15.0, 300.0)  # (connect, read) seconds
_DEFAULT_RETRIES = 4
_BACKOFFS = (1.0, 2.0, 4.0, 8.0)


def _raise_for_status(resp: requests.Response, label: str) -> None:
    """Convert HTTP error codes into our typed exceptions."""
    code = resp.status_code
    if code < 400:
        return
    body_preview = ""
    try:
        body_preview = resp.text[:500]
    except Exception:  # noqa: BLE001
        pass
    if code == 429:
        retry_after = 0.0
        ra = resp.headers.get("Retry-After")
        if ra:
            try:
                retry_after = float(ra)
            except ValueError:
                retry_after = 0.0
        raise RateLimitError(f"[{label}] 429 rate limit: {body_preview}", retry_after)
    if 500 <= code < 600:
        raise ServerError(f"[{label}] {code}: {body_preview}")
    raise HttpError(f"[{label}] {code}: {body_preview}")


def post_json(
    url: str,
    payload: Dict[str, Any],
    *,
    headers: Optional[Dict[str, str]] = None,
    label: str = "http",
    timeout: Tuple[float, float] = _DEFAULT_TIMEOUT,
    max_retries: int = _DEFAULT_RETRIES,
) -> Dict[str, Any]:
    """POST ``payload`` as JSON, parse the response as JSON.

    Retries on 429 (honors Retry-After) and 5xx with exponential
    backoff. Other 4xx fail immediately.
    """
    h = {"Content-Type": "application/json", "Accept": "application/json"}
    if headers:
        h.update(headers)
    last_exc: Optional[BaseException] = None
    for attempt in range(max_retries + 1):
        if attempt > 0:
            wait = _BACKOFFS[min(attempt - 1, len(_BACKOFFS) - 1)]
            if isinstance(last_exc, RateLimitError) and last_exc.retry_after > 0:
                wait = max(wait, last_exc.retry_after)
            _log(f"[{label}:retry] attempt={attempt + 1} backoff={wait:.1f}s err={last_exc}")
            time.sleep(wait)
        try:
            resp = requests.post(url, json=payload, headers=h, timeout=timeout)
            _raise_for_status(resp, label)
            return resp.json()
        except (RateLimitError, ServerError) as e:
            last_exc = e
            continue
        except requests.RequestException as e:
            last_exc = e
            continue
        except HttpError:
            raise
    raise RuntimeError(f"[{label}] retries exhausted: {last_exc}")


# ---------------------------------------------------------------------------
# Streaming iterators
# ---------------------------------------------------------------------------


def stream_sse(
    url: str,
    payload: Dict[str, Any],
    *,
    headers: Optional[Dict[str, str]] = None,
    label: str = "sse",
    timeout: Tuple[float, float] = _DEFAULT_TIMEOUT,
    max_retries: int = _DEFAULT_RETRIES,
) -> Iterator[Dict[str, Any]]:
    """POST and yield parsed JSON objects from a Server-Sent-Events stream.

    Stops on ``data: [DONE]`` (OpenAI sentinel) or when the connection
    closes. Lines that aren't valid SSE ``data:`` payloads are ignored.
    Retries on transient errors (same policy as :func:`post_json`).
    """
    h = {
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
    }
    if headers:
        h.update(headers)
    last_exc: Optional[BaseException] = None
    for attempt in range(max_retries + 1):
        if attempt > 0:
            wait = _BACKOFFS[min(attempt - 1, len(_BACKOFFS) - 1)]
            if isinstance(last_exc, RateLimitError) and last_exc.retry_after > 0:
                wait = max(wait, last_exc.retry_after)
            _log(f"[{label}:retry] attempt={attempt + 1} backoff={wait:.1f}s err={last_exc}")
            time.sleep(wait)
        try:
            with requests.post(
                url, json=payload, headers=h, timeout=timeout, stream=True
            ) as resp:
                _raise_for_status(resp, label)
                for raw in resp.iter_lines(decode_unicode=True):
                    if not raw:
                        continue
                    line = raw.strip()
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        return
                    if not data:
                        continue
                    try:
                        yield json.loads(data)
                    except json.JSONDecodeError:
                        continue
                return
        except (RateLimitError, ServerError) as e:
            last_exc = e
            continue
        except requests.RequestException as e:
            last_exc = e
            continue
        except HttpError:
            raise
    raise RuntimeError(f"[{label}] retries exhausted: {last_exc}")


def stream_ndjson(
    url: str,
    payload: Dict[str, Any],
    *,
    headers: Optional[Dict[str, str]] = None,
    label: str = "ndjson",
    timeout: Tuple[float, float] = _DEFAULT_TIMEOUT,
    max_retries: int = _DEFAULT_RETRIES,
) -> Iterator[Dict[str, Any]]:
    """POST and yield parsed JSON objects, one per line (Ollama format)."""
    h = {"Content-Type": "application/json", "Accept": "application/x-ndjson"}
    if headers:
        h.update(headers)
    last_exc: Optional[BaseException] = None
    for attempt in range(max_retries + 1):
        if attempt > 0:
            wait = _BACKOFFS[min(attempt - 1, len(_BACKOFFS) - 1)]
            if isinstance(last_exc, RateLimitError) and last_exc.retry_after > 0:
                wait = max(wait, last_exc.retry_after)
            _log(f"[{label}:retry] attempt={attempt + 1} backoff={wait:.1f}s err={last_exc}")
            time.sleep(wait)
        try:
            with requests.post(
                url, json=payload, headers=h, timeout=timeout, stream=True
            ) as resp:
                _raise_for_status(resp, label)
                for raw in resp.iter_lines(decode_unicode=True):
                    if not raw:
                        continue
                    try:
                        yield json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                return
        except (RateLimitError, ServerError) as e:
            last_exc = e
            continue
        except requests.RequestException as e:
            last_exc = e
            continue
        except HttpError:
            raise
    raise RuntimeError(f"[{label}] retries exhausted: {last_exc}")


# ---------------------------------------------------------------------------
# Helpers for assembling streamed OpenAI-style chat completions
# ---------------------------------------------------------------------------


def assemble_openai_chat_stream(
    chunks: Iterable[Dict[str, Any]],
    label: str = "stream",
    on_thinking=None,
) -> Tuple[str, str]:
    """Collect content deltas from an OpenAI-style SSE stream.

    Returns ``(content, finish_reason)``. The ``content`` is the
    concatenation of every ``choices[0].delta.content`` chunk; the
    ``finish_reason`` is whatever the last chunk reports, falling back
    to ``"stop"`` when the stream ends without one.

    Heartbeat lines are printed every ~5 seconds so the Flutter
    inactivity watchdog stays armed.
    """
    parts: List[str] = []
    finish_reason = ""
    last_heartbeat = time.time()
    chunk_count = 0
    for chunk in chunks:
        chunk_count += 1
        choices = chunk.get("choices") or []
        if choices:
            delta = (choices[0] or {}).get("delta") or {}
            piece = delta.get("content")
            if piece:
                parts.append(piece)
            reasoning = delta.get("reasoning_content") or delta.get("reasoning")
            if reasoning and on_thinking is not None:
                on_thinking(reasoning)
            fr = choices[0].get("finish_reason")
            if fr:
                finish_reason = fr
        now = time.time()
        if now - last_heartbeat >= 5.0:
            chars_so_far = sum(len(p) for p in parts)
            _log(f"[{label}:streaming] chunks={chunk_count} chars={chars_so_far}")
            last_heartbeat = now
    return "".join(parts), (finish_reason or "stop")
