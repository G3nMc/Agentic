"""The Orchestrator class — runs the iterate-call-tool-call-call loop."""
from __future__ import annotations

import json
import re
import sys
import time
from typing import Any, Dict, List, Optional

from . import history as _history
from . import tool_dispatch as _td
from ..backends.backend_base import ModelBackend
from ..policy import SecurityConfig
from ..tools.registry import ToolRegistry
from ..utils.circuit_breaker import CircuitBreaker

# Maximum characters of a tool result to keep in conversation history.
# Tool results (read_file, list_files_recursive, etc.) can be tens of KB;
# embedding them verbatim blows the model's context window after a few
# iterations.  12 000 chars ≈ 3 000 tokens — enough context for the model
# to understand the result and decide the next step, while keeping the
# total history well within typical context limits even after many turns.
_MAX_TOOL_RESULT_CHARS = 12_000


class Orchestrator:
    def __init__(
            self,
            backend: ModelBackend,
            base_path: str = ".",
            temperature: float = 0.2,
            max_tokens: int = 2048,
            security_config: Optional[SecurityConfig] = None,
            disable_tools: bool = False,
            path_filter: Optional[Any] = None,
    ):
        self.backend = backend
        # When True, every request is routed as a plain chat call — the
        # tool-decision heuristic and the tool loop are bypassed. Useful
        # for reasoning-only models (phi-4, plain Mistral, etc.) that
        # can't emit valid tool calls.
        self.disable_tools = disable_tools
        # Expose model_id for logging/diagnostics; both backends carry one.
        self.model_id = getattr(backend, "model_id", "(unknown)")
        self.tool_registry = ToolRegistry(base_path=base_path,
                                          security_config=security_config,
                                          path_filter=path_filter)
        # Model-level circuit breaker: open after 5 consecutive API failures,
        # probe again after 60 s so a temporary outage doesn't loop forever.
        self._model_circuit_breaker = CircuitBreaker(
            name=f"model:{self.model_id}", failure_threshold=5, recovery_timeout=60.0
        )
        self.conversation_history: List[Dict[str, Any]] = []
        # Generation knobs. Exposed as CLI flags so the Flutter UI can
        # let users tune them per-backend without editing Python.
        self.temperature = temperature
        self.max_tokens = max_tokens
        # Cap tool-chain length. Each iteration is potentially a 60–120 s
        # model call, so 30 bounds a single /sendPrompt at ~60 min worst case,
        # comfortably inside the Dart-side absolute timeout (120 min).
        # Dynamic scaling: starts at 30, can extend to 100+ for complex tasks.
        self.max_iterations = 100
        self._initial_max_iterations = 100
        self._max_iteration_cap = 150  # Absolute ceiling to prevent runaway costs
        self._successful_tool_count = 0  # Track progress for dynamic extension
        self._files_modified = set()  # Track unique files touched
        # Sliding-window history cap. Each "turn" = 1 user msg + 1 assistant msg.
        # 6 turns = 12 messages. Keeps total history well under 8 k-token cloud
        # limits (system prompt ~700 tok + 12 msgs * ~300 tok avg + max_tokens
        # 2048 ≈ 6300).
        self.max_history_turns = 6

    # ------------------------------------------------------------------
    # Session management
    # ------------------------------------------------------------------
    def reset(self) -> None:
        self.conversation_history = []

    def import_history(self, history: List[Dict[str, Any]]) -> None:
        self._ensure_system_prompt()
        _history.import_external_history(self.conversation_history, history)

    def _ensure_system_prompt(self) -> None:
        _history.ensure_system_prompt(
            self.conversation_history,
            self.tool_registry.get_system_prompt(),
        )

    def _trim_history(self) -> None:
        self.conversation_history = _history.trim_history(
            self.conversation_history, self.max_history_turns
        )

    # ------------------------------------------------------------------
    # Tool-intent heuristic
    # ------------------------------------------------------------------
    # Short reminder prepended to the first user turn. Many HF-router providers
    # silently drop the `system` role (Qwen via hyperbolic is a known offender)
    # so embedding the contract in the user message guarantees the model sees
    # it. Kept short so small Ollama models don't waste prompt-eval time.
    # Injected only when the request is clearly a code/file task.
    _TOOL_REMINDER = (
        "[You have filesystem tools available. "
        "If this request needs file access or a command, emit ONE tool call: "
        '<tool>{"tool":"NAME","parameters":{...}}</tool>. '
        "No explanation before or after it. Prefer dedicated tools "
        "(read_file/search_in_files/list_files/flutter_analyze/python_check/"
        "python_lint/python_test/git_*) and use run_command only as a fallback. "
        "Keep the JSON valid; prefer single quotes inside shell commands. "
        "Otherwise reply normally.]\n\n"
    )

    # Patterns that indicate file/code intent — trigger tool-enabled mode.
    _CODE_INTENT_MARKERS = (
        # file references
        "file", "folder", "director", "path", ".dart", ".py", ".js", ".ts",
        ".json", ".yaml", ".yml", ".md", "lib/", "src/", "bin/", "test/",
        # code objects
        "function", "method", "class", "widget", "screen", "model", "service",
        "import", "package", "dependency", "pubspec",
        # actions
        "fix", "edit", "modify", "change", "update", "refactor", "rename",
        "create", "delete", "remove", "add", "implement", "write",
        "run", "build", "compile", "test", "install", "deploy", "execute",
        "read", "open", "show", "list", "find", "search", "look",
        # git
        "git", "commit", "branch", "merge", "push", "pull", "diff", "status",
        # vague but file-related
        "project", "codebase", "repo", "error", "bug", "crash", "exception",
    )

    # Deterministic "must-use-tools" patterns. These are evaluated before
    # the general marker list so obvious tool tasks don't slip into chat mode.
    _TOOL_INTENT_PATTERNS = (
        r"\bflutter\s+analy[sz]e\b",
        r"\bflutter\s+test\b",
        r"\b(run|execute)\s+(a\s+)?command\b",
        r"\b(get-content|select-string|findstr|dir|ls)\b",
        r"\b(export|download|save)\b.*\b(chat|conversation|history)\b.*\bjson\b",
        r"\b(read|open|search|find|list)\b.*\b(file|folder|directory|repo|project)\b",
    )

    @classmethod
    def _needs_tools(cls, text: str) -> bool:
        """Return True when the message likely requires file/code access."""
        t = (text or "").lower()
        if any(re.search(pattern, t) for pattern in cls._TOOL_INTENT_PATTERNS):
            return True
        return any(m in t for m in cls._CODE_INTENT_MARKERS)

    def _should_escalate_chat_to_tools(self, user_input: str, model_reply: str) -> bool:
        """True when a chat-mode response should be retried in tool mode."""
        if self._needs_tools(user_input):
            return True
        if _td.parse_all_tag_tool_calls(model_reply, self.tool_registry.definitions):
            return True
        is_malformed, _ = _td.looks_like_malformed_tool_call(model_reply)
        if is_malformed:
            return True
        if _td.looks_like_refusal(model_reply):
            return True
        return False

    # ------------------------------------------------------------------
    # Main loop
    # ------------------------------------------------------------------
    def run(self, user_input: str) -> str:
        self._ensure_system_prompt()
        self._trim_history()

        use_tools = (not self.disable_tools) and self._needs_tools(user_input)

        if use_tools:
            decorated = self._TOOL_REMINDER + user_input
        else:
            decorated = user_input

        self.conversation_history.append({"role": "user", "content": decorated})

        mode = "tool-enabled" if use_tools else "chat"
        print(f"[orch] Request ({mode}): {user_input[:120]!r}", file=sys.stderr)

        # For conversational messages skip the tool loop entirely — one direct call.
        if not use_tools:
            try:
                text, _ = self.backend.chat(
                    messages=self.conversation_history,
                    max_tokens=self.max_tokens,
                    temperature=self.temperature,
                    tools=None,
                )
            except Exception as e:
                # Pop the just-added user turn so a retry doesn't end up
                # with two consecutive user messages, and so the failed
                # error string never leaks into model context on the next
                # turn (some models will parrot it back).
                if self.conversation_history and \
                        self.conversation_history[-1].get("role") == "user":
                    self.conversation_history.pop()
                return f"Model error: {e}"
            text_clean = _td.clean_history_text(text or "")
            if self._should_escalate_chat_to_tools(user_input, text_clean):
                print(
                    "[orch] Chat-mode reply looked tool-related; retrying in tool mode.",
                    file=sys.stderr,
                )
                if self.conversation_history and \
                        self.conversation_history[-1].get("role") == "user":
                    self.conversation_history[-1]["content"] = (
                            self._TOOL_REMINDER + user_input
                    )
                use_tools = True
            else:
                self.conversation_history.append({
                    "role": "assistant",
                    "content": text_clean,
                })
                return _td.clean_final_answer(text or "")

        refusal_retries = 0
        empty_retries = 0
        truncation_retries = 0
        malformed_tool_retries = 0

        # Rough character budget for the entire conversation history sent to
        # the model on each call.  When exceeded we force a trim so the next
        # _call_model() stays within the backend's context limit.  200K chars
        # ≈ 50K tokens — generous for 8K–32K context models, and still safe
        # for 1M-token models because tool results are already capped at
        # _MAX_TOOL_RESULT_CHARS per message.
        _HISTORY_CHAR_BUDGET = 200_000

        for iteration in range(self.max_iterations):
            print(f"[orch] Progress detected | iter={iteration}")
            # === DYNAMIC ITERATION LIMIT ===
            # Extend budget proactively when progress is detected, not just at the end.
            # Check every 5 iterations and when approaching the limit.
            should_check_extension = (
                    iteration % 5 == 0  # Periodic check
                    or iteration >= self.max_iterations - 3  # Approaching limit
            )
            if should_check_extension and self.max_iterations < self._max_iteration_cap:
                # Measure progress: count successful tool calls in recent history
                recent_history = "".join(
                    [m.get("content", "") for m in self.conversation_history[-8:]]
                )
                success_count = recent_history.count('"status": "success"')
                error_count = recent_history.count('"status": "error"')

                # Calculate extension multiplier based on progress rate
                if success_count > 0 and success_count > error_count:
                    # Good progress: extend by 5-15 based on success rate
                    extension = min(
                        5 + (success_count * 2),  # More successes = larger extension
                        self._max_iteration_cap - self.max_iterations  # Don't exceed cap
                    )
                    old_limit = self.max_iterations
                    self.max_iterations += extension
                    print(
                        f"[orch] Progress detected | iter={iteration} | "
                        f"successes={success_count} errors={error_count} | "
                        f"Extending max_iterations {old_limit} -> {self.max_iterations}",
                        file=sys.stderr,
                    )
                    continue

                # Detect complex multi-file operations: extend more aggressively
                files_touched = len(set(re.findall(r'\b[a-zA-Z_][\w/.-]*\.(?:dart|py|yaml|json|md)\b', recent_history)))
                if files_touched >= 3 and self._successful_tool_count >= 5:
                    extension = min(20, self._max_iteration_cap - self.max_iterations)
                    old_limit = self.max_iterations
                    self.max_iterations += extension
                    print(
                        f"[orch] Complex multi-file operation detected | "
                        f"files={files_touched} | Extending max_iterations {old_limit} -> {self.max_iterations}",
                        file=sys.stderr,
                    )
                    continue

            # Enforce the character budget: if history has grown past the
            # limit, trim older non-system messages so the next model call
            # stays within context.
            total_chars = sum(len(m.get("content", "")) for m in self.conversation_history)
            if total_chars > _HISTORY_CHAR_BUDGET:
                system = [m for m in self.conversation_history if m.get("role") == "system"]
                non_system = [m for m in self.conversation_history if m.get("role") != "system"]
                # Drop oldest non-system messages until under budget.
                while non_system and total_chars > _HISTORY_CHAR_BUDGET:
                    dropped = non_system.pop(0)
                    total_chars -= len(dropped.get("content", ""))
                self.conversation_history = system + non_system
                print(
                    f"[orch] History over char budget; trimmed to "
                    f"{len(non_system)} non-system messages.",
                    file=sys.stderr,
                )

            try:
                text, finish_reason = self._call_model()
            except Exception as e:
                return f"Model error: {e}"

            preview = (text or "").replace("\n", " ")[:800]
            print(f"[orch] Model reply (iter {iteration}, finish={finish_reason}, "
                  f"len={len(text or '')}): {preview!r}", file=sys.stderr)

            # Strip <think> blocks AND chat-template control tokens before
            # storing in history — they waste context and confuse the tool
            # parser. The raw `text` (with thinking intact) is still used
            # for the final answer so the Flutter UI can render the
            # reasoning section.
            text_clean = _td.clean_history_text(text or "")
            self.conversation_history.append({"role": "assistant", "content": text_clean})

            # Parse tool calls from the cleaned text to avoid false positives
            # when a model embeds JSON examples inside its <tool_call> block.
            tag_calls = _td.parse_all_tag_tool_calls(
                text_clean, self.tool_registry.definitions
            )
            if tag_calls:
                for name, params in tag_calls:
                    print(f"[orch] -> tool {name}({params})", file=sys.stderr)
                    result = self.tool_registry.execute(name, params)

                    # Track successful tool executions for dynamic iteration extension
                    if '"status": "success"' in result or '"status":"success"' in result:
                        self._successful_tool_count += 1
                        # Track modified files for complexity detection
                        if name in ("write_file", "patch_file", "append_file"):
                            file_path = params.get("path", "")
                            if file_path:
                                self._files_modified.add(file_path)

                    # Truncate oversized tool results before they bloat the
                    # conversation history and blow the model's context window.
                    # Head+tail strategy: keep the first and last halves so the
                    # model sees both file headers/imports AND the implementation
                    # at the bottom — the middle is usually less critical.
                    display_result = result
                    if len(display_result) > _MAX_TOOL_RESULT_CHARS:
                        half = _MAX_TOOL_RESULT_CHARS // 2
                        trunc_len = len(display_result) - _MAX_TOOL_RESULT_CHARS
                        display_result = (
                                display_result[:half]
                                + f"\n[... {trunc_len} chars truncated from middle ...]\n"
                                + display_result[-half:]
                        )

                    # On the last two iterations force a final answer — no more tools.
                    is_last_chance = iteration >= self.max_iterations - 2
                    if is_last_chance:
                        follow_up = (
                            f"Tool `{name}` returned:\n{display_result}\n\n"
                            "[INTERNAL: FINAL ANSWER REQUIRED. Do NOT call any more tools. "
                            "Write only your plain-text answer to the user now. "
                            "Do NOT echo this instruction back to the user.]"
                        )
                    else:
                        follow_up = (
                            f"Tool `{name}` returned:\n{display_result}\n\n"
                            "[INTERNAL: Continue. Either call another tool or give the final answer. "
                            "Do NOT echo this instruction back to the user.]"
                        )
                    self.conversation_history.append({"role": "user", "content": follow_up})
                continue

            is_malformed, malformed_error = _td.looks_like_malformed_tool_call(text_clean)
            if is_malformed and malformed_tool_retries < 2:
                malformed_tool_retries += 1
                print(
                    f"[orch] Malformed tool call detected (retry {malformed_tool_retries}): {malformed_error}",
                    file=sys.stderr,
                )
                print(
                    f"[orch] Unparseable reply (first 500 chars): "
                    f"{text_clean[:500]!r}",
                    file=sys.stderr,
                )
                self.conversation_history.append({
                    "role": "user",
                    "content": (
                        f"Your previous reply attempted a tool call but the "
                        f"format was invalid. {malformed_error}\n"
                        "Reply with EXACTLY ONE valid tool call on a single "
                        "line in this format:\n"
                        '<tool>{"tool":"NAME","parameters":{...}}</tool>\n'
                        "No explanation, no markdown, no backticks. Keep the "
                        "JSON valid. If a shell command contains quotes, "
                        "prefer single quotes inside the command string."
                    ),
                })
                continue

            # If malformed but retries exhausted, do NOT treat as final answer.
            # Return an error message instead of leaking broken tool-call syntax.
            if is_malformed:
                print(
                    f"[orch] Malformed tool call: retries exhausted. "
                    f"Error: {malformed_error}",
                    file=sys.stderr,
                )
                return (
                    "The model failed to emit a valid tool call after multiple "
                    "attempts. The request may be too ambiguous or the model may "
                    "not support tool-use. Try rephrasing your request or using "
                    "a different model."
                )

            # --- Truncation detection ---
            # The reply claims to start a tool call (`<tool>` or fenced JSON)
            # but was cut off by max_tokens before the matching `</tool>` /
            # closing brace arrived. Without this branch we'd dump the raw
            # half-written JSON back to the UI.
            looks_truncated = (
                    finish_reason == "length"
                    or _td.looks_like_unclosed_tool(text_clean)
            )
            if looks_truncated and truncation_retries < 2:
                truncation_retries += 1
                print(f"[orch] Truncation detected (retry {truncation_retries}).",
                      file=sys.stderr)
                self.conversation_history.append({
                    "role": "user",
                    "content": (
                        "Your previous reply was CUT OFF before the closing "
                        "</tool> tag. Do NOT include any plan, preamble, or "
                        "explanation. Emit ONLY the tool call on a single "
                        "line, e.g.:\n"
                        '<tool>{"tool":"write_file","parameters":'
                        '{"path":"...","content":"..."}}</tool>\n'
                        "If the content is very large, break the work into "
                        "smaller steps: first create the file with a short "
                        "content, then use append_file in follow-up calls."
                    ),
                })
                continue

            # No tool call. Classify the response.
            if _td.looks_like_refusal(text_clean) and refusal_retries < 2:
                refusal_retries += 1
                print(f"[orch] Refusal detected (retry {refusal_retries}).",
                      file=sys.stderr)
                self.conversation_history.append({
                    "role": "user",
                    "content": (
                        "STOP. That is a refusal and it is wrong. You DO have "
                        "filesystem access through the tools. Your entire next "
                        "message must be exactly one line, e.g.:\n"
                        '<tool>{"tool":"list_files","parameters":{"path":"."}}</tool>\n'
                        "No apology, no explanation, no markdown fences. Just "
                        "the tool call tag."
                    ),
                })
                continue

            if not text_clean and empty_retries < 1:
                empty_retries += 1
                self.conversation_history.append({
                    "role": "user",
                    "content": "Your reply was empty. Emit a single "
                               '<tool>{"tool":"...","parameters":{...}}</tool> '
                               "call or the final plain-text answer.",
                })
                continue

            # Otherwise treat as final answer.
            return _td.clean_final_answer(text or "")

        # If we reach here, we've exhausted all iterations without a final answer.
        print("[orch] Max iterations reached. Saving session to session_dump.json",
              file=sys.stderr)
        try:
            with open("session_dump.json", "w", encoding="utf-8") as f:
                json.dump(self.conversation_history, f, indent=2)
        except Exception as e:
            print(f"[orch] Failed to save session: {e}", file=sys.stderr)

        return "Max iterations reached without a final answer. Session saved to session_dump.json."

    # ------------------------------------------------------------------
    # Backend call w/ retry + circuit breaker
    # ------------------------------------------------------------------
    # Backoff schedule for 429 / transient 5xx errors, in seconds. Total
    # maximum wall time for rate-limit retries: 1+2+4+8+16 = 31 s plus 5
    # model calls. The Dart inactivity watchdog (3 min) sits well above this.
    _RETRY_BACKOFFS = (1, 2, 4, 8, 16)

    # Exception-message substrings that identify a retryable error from the
    # huggingface-hub SDK. The SDK raises `HfHubHTTPError` (subclass of
    # `requests.HTTPError`) which prints the status code into `str(e)`.
    _RETRYABLE_HINTS = (
        "429",
        "too many requests",
        "rate limit",
        "rate-limit",
        "503",
        "502",
        "504",
        "service unavailable",
        "bad gateway",
        "gateway timeout",
    )

    @classmethod
    def _is_retryable_error(cls, exc: BaseException) -> bool:
        msg = str(exc).lower()
        return any(h in msg for h in cls._RETRYABLE_HINTS)

    def _call_model(self) -> tuple:
        """
        Issue a chat-completion request using ONLY the prompt-based protocol.

        Returns `(content, finish_reason)`. `finish_reason == "length"` means
        the model hit `max_tokens` and the reply is truncated — the caller
        must handle that, because a half-written `<tool>...` JSON is worse
        than no tool call at all.

        Retries on 429 / 5xx with exponential backoff (1s, 2s, 4s, 8s, 16s).
        """
        # Model circuit breaker: fast-fail when the backend is consistently broken.
        if not self._model_circuit_breaker.allow_request():
            raise RuntimeError(
                f"Model circuit breaker is OPEN for '{self.model_id}'. "
                f"Too many consecutive failures — will auto-retry after "
                f"{self._model_circuit_breaker.recovery_timeout:.0f}s. "
                f"Check your API key, quota, or network connectivity."
            )

        last_exc: Optional[BaseException] = None
        # attempt 0 = immediate; attempts 1..N = after waiting backoffs[i-1]
        for attempt in range(len(self._RETRY_BACKOFFS) + 1):
            if attempt > 0:
                wait_s = self._RETRY_BACKOFFS[attempt - 1]
                print(
                    f"[orch] Transient error, backing off {wait_s}s "
                    f"(attempt {attempt + 1}/{len(self._RETRY_BACKOFFS) + 1}): "
                    f"{last_exc}",
                    file=sys.stderr,
                )
                time.sleep(wait_s)
            try:
                result = self.backend.chat(
                    messages=self.conversation_history,
                    max_tokens=self.max_tokens,
                    temperature=self.temperature,
                    tools=self.tool_registry.definitions,
                )
                # Successful call: reset the circuit breaker failure count.
                self._model_circuit_breaker.record_success()
                return result
            except Exception as e:  # noqa: BLE001 - broad by design
                last_exc = e
                if not self._is_retryable_error(e):
                    # Auth errors, malformed input, Ollama connection refused,
                    # etc. Don't retry — but still count as a failure.
                    self._model_circuit_breaker.record_failure()
                    raise
                # else: fall through to next backoff

        # Exhausted all retries. Record the failure and surface a clear message.
        self._model_circuit_breaker.record_failure()
        raise RuntimeError(
            f"Model backend kept returning a rate-limit / transient error "
            f"after {len(self._RETRY_BACKOFFS) + 1} attempts. "
            f"Last error: {last_exc}. "
            f"Try again in a minute, switch to a less-busy model, or check "
            f"quota / daemon health."
        )
