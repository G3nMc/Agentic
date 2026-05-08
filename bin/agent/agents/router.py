"""Router — gatekeeper that classifies a request as trivial / reasoning / tool.

Tiered evaluation:
  1. Cheap regex rules catch greetings, thanks, tiny arithmetic (zero LLM call).
  2. Otherwise the configured cheap model emits ONE word: trivial|reasoning|tool.

The Router must never be the expensive model — that's the whole point of
having it. Pair it with Ollama, Haiku-tier, or Groq-llama-8b in the UI.
"""
from __future__ import annotations

import re
import sys
from typing import Optional

from ..core.state import (ALL_ROUTES, ROUTE_REASONING, ROUTE_TOOL,
                           ROUTE_TRIVIAL, WorkflowState)
from .base import Agent


_ROUTER_SYSTEM_PROMPT = (
    "You are a request router. Classify the user's message into ONE of these "
    "labels:\n"
    "  - trivial: greetings, thanks, small talk, single-line factual recall, "
    "    tiny math (e.g. '2+2'), questions about yourself.\n"
    "  - reasoning: explaining a concept, comparing options, planning, "
    "    answering an open-ended question that does NOT require touching the "
    "    user's filesystem.\n"
    "  - tool: anything that needs to read, write, search, or run something "
    "    in the project — file paths, code edits, builds, tests, git, shell.\n"
    "\n"
    "Respond with EXACTLY one word: trivial, reasoning, or tool. "
    "No punctuation, no explanation."
)

# Free-tier rules: no LLM call needed. Order matters — first match wins.
#
# Each pattern must match the WHOLE message (anchored ^…$), not just a
# leading word. Otherwise sentences like "Ok take a try - flutter analyze -"
# get classified as small talk because they happen to start with "Ok",
# bypassing the tool path entirely. A trailing punctuation/emoji tail is
# tolerated, but anything that looks like a real request after the greeting
# falls through to Tier 2 (tool markers) or Tier 3 (LLM classifier).
_TRIVIAL_PATTERNS = [
    re.compile(r"^\s*(hi|hello|hey|yo|salve|ciao)[\s!.?]*$", re.IGNORECASE),
    re.compile(
        r"^\s*(thanks|thank\s+you|grazie|ok|okay|cool|nice|great)[\s!.?]*$",
        re.IGNORECASE,
    ),
    re.compile(r"^\s*(bye|goodbye|see\s*ya|ciao)[\s!.?]*$", re.IGNORECASE),
    re.compile(r"^\s*\d{1,4}\s*[\+\-\*\/x]\s*\d{1,4}\s*=?\s*$"),
    re.compile(r"^\s*who\s+are\s+you\??\s*$", re.IGNORECASE),
]

# Continuation phrases — short replies that mean "keep going with whatever
# we were doing". They have no standalone intent, so we skip the LLM call
# and route to ``reasoning`` directly; the shaper's history-aware re-shape
# (see Workflow.run) will substitute a real spec from the prior turn.
_CONTINUATION_PATTERNS = [
    re.compile(
        r"^\s*(?:"
        r"ok(?:ay)?(?:\s+(?:proceed|go|do\s+it|continue|good))?"
        r"|yes(?:\s+(?:proceed|go|do\s+it|continue|please))?"
        r"|sure(?:\s+(?:do\s+it|go|proceed))?"
        r"|proceed|continue|go\s+ahead|do\s+it|fix\s+it|please\s+continue"
        r")[\s!.?]*$",
        re.IGNORECASE,
    ),
]

# Strong tool-intent markers — if any are present we skip the LLM and route
# straight to ``tool``. Mirrors the heuristic in run_loop.Orchestrator but
# trimmed to the markers that genuinely cannot be answered without tools.
_TOOL_MARKERS = (
    ".dart", ".py", ".js", ".ts", ".json", ".yaml", ".yml", ".md",
    "lib/", "src/", "bin/", "test/", "pubspec",
    "git ", "commit", "branch", "merge", "diff",
    "run command", "shell", "build", "compile",
    "flutter analyze", "flutter test", "get-content", "select-string",
    "export chat", "download chat", "chat history", "conversation history",
)

# Knowledge-domain markers — questions about external protocols, standards,
# libraries, or generic programming concepts. These never need the
# filesystem and should bypass the LLM-classifier (the cheap router model
# tends to mis-label "explain X" as `tool` because of the imperative verb).
_KNOWLEDGE_PHRASES = (
    "explain ", "what is ", "what are ", "what's ", "whats ",
    "how does ", "how do ", "why does ", "why do ",
    "difference between ", "compare ", "vs ",
    "tell me about ", "describe ",
)
_KNOWLEDGE_TOPICS = (
    "mcp", "model context protocol", "oauth", "openid", "saml", "jwt",
    "http", "https", "tcp", "udp", "websocket", "grpc", "rest", "graphql",
    "json-rpc", "rpc", "tls", "ssl",
    "kubernetes", "k8s", "docker",
    "react", "angular", "vue",
    "transformer", "llm", "embedding", "rag",
)

# Hard cap on the user message we hand to the LLM classifier. Anything
# longer is almost certainly a paste; classify it cheaply on the truncated
# prefix instead of letting the cheap-tier model 413 on the full payload.
_ROUTER_MAX_INPUT_CHARS = 2000


class RouterAgent(Agent):
    name = "router"

    def __init__(self, backend, *, system_prompt: Optional[str] = None,
                 temperature: float = 0.0, max_tokens: int = 8):
        super().__init__(backend,
                         system_prompt or _ROUTER_SYSTEM_PROMPT,
                         temperature=temperature,
                         max_tokens=max_tokens)

    # ------------------------------------------------------------------
    def run(self, state: WorkflowState) -> WorkflowState:
        text = state.user_input or ""
        # Tier 1: free rules.
        # Enhanced trivial pattern matching for direct routing
        if any(p.search(text) for p in _TRIVIAL_PATTERNS):
            state.route = ROUTE_TRIVIAL
            state.add_trace(self.name, output=ROUTE_TRIVIAL,
                            detail="rule-match (no LLM call)")
            return state
        # Tier 1b: continuation phrases like "Ok proceed", "yes do it" — go
        # straight to reasoning so the (history-aware) shaper can re-shape.
        # Without this we burn an LLM call on a router model that often
        # produces conversational chatter for these inputs.
        if any(p.match(text) for p in _CONTINUATION_PATTERNS):
            state.route = ROUTE_REASONING
            state.add_trace(self.name, output=ROUTE_REASONING,
                            detail="continuation-match (no LLM call)")
            return state
        lowered = text.lower()
        # Deterministic shortcut for obvious tool requests.
        if any(marker in lowered for marker in _TOOL_MARKERS):
            state.route = ROUTE_TOOL
            state.add_trace(
                self.name,
                output=ROUTE_TOOL,
                detail="marker-match (no LLM call)",
            )
            return state

        # Knowledge-domain shortcut: "explain MCP", "how does OAuth work" etc.
        # Route to reasoning without an LLM call so the reasoner answers from
        # its own knowledge (its system prompt now forbids grep'ing the repo
        # for these). Requires BOTH a knowledge phrase AND a known topic to
        # avoid stealing genuine in-repo questions like "explain bin/agent".
        if (any(p in lowered for p in _KNOWLEDGE_PHRASES)
                and any(t in lowered for t in _KNOWLEDGE_TOPICS)):
            state.route = ROUTE_REASONING
            state.add_trace(
                self.name,
                output=ROUTE_REASONING,
                detail="knowledge-topic-match (no LLM call)",
            )
            return state

        # Tier 2: cheap classifier. Cap input so a long paste can't 413 the
        # cheap-tier endpoint — only the prefix is needed to classify.
        classifier_input = text if len(text) <= _ROUTER_MAX_INPUT_CHARS \
            else text[:_ROUTER_MAX_INPUT_CHARS]
        try:
            messages = self._build_messages(classifier_input)
            label_text, _ = self._chat(messages)
        except Exception as e:  # noqa: BLE001 — broad on purpose
            print(f"[router] classification failed ({e}); defaulting to reasoning.",
                  file=sys.stderr)
            state.route = ROUTE_REASONING
            state.add_trace(self.name, output=ROUTE_REASONING,
                            detail=f"fallback after error: {e}")
            return state

        label = self._parse_label(label_text)
        state.route = label
        state.add_trace(self.name, output=label,
                        detail=f"raw={label_text!r}")
        return state

    # ------------------------------------------------------------------
    @staticmethod
    def _parse_label(text: str) -> str:
        """Extract the first known label from arbitrary model output."""
        if not text:
            return ROUTE_REASONING
        lowered = text.strip().lower()
        for label in ALL_ROUTES:
            if label in lowered:
                return label
        return ROUTE_REASONING
