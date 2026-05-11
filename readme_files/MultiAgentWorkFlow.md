# Multi-Agent Workflow — Setup Guide

This guide explains how to configure the four-role agent workflow introduced
on the `agentic_flow` branch. It covers what each role does, which backends
mix well, and concrete model recipes you can paste straight into
**Settings → Workflow Agents**.

---

## 1. The four roles at a glance

| Role | Purpose | Calls per turn | Wants… |
|------|---------|----------------|--------|
| **Router** | 3-tier triage: regex → cheap classifier → "reasoning". Picks the path *before* spending big-model quota. | 0 (regex hit) or 1 | tiny, fast, cheap, deterministic (temperature 0) |
| **Shaper** | Rewrites the raw user prompt into `Goal: / Constraints: / Success criteria:`. Runs **once per workflow**, not per turn. | 1 | small, instruction-following |
| **Reasoner** | The brain. Decides what to do, emits `<tool>{…}</tool>` calls, composes the final answer. Loops with the Executor. | 1–N (≤ `max_iterations=8`) | strong reasoning, big context window, reliable tool-call format |
| **Executor** | Runs the requested tool, summarises the result back into the state. For trivial routes it also produces a one-shot reply with no tool. | 1 per tool call | medium-sized, good at JSON / structured output |

**Routing fan-out:**
```
trivial    → Executor (no tools) → done                  [≈ 1 LLM call]
reasoning  → Shaper → Reasoner → done                    [≈ 2 LLM calls]
tool       → Shaper → Reasoner ↔ Executor (loop) → done  [3+ LLM calls]
```

---

## 2. Mixed-backend solutions (recommended)

The point of mixing is to put each role on the cheapest backend that's
*good enough* for it. The dispatcher manages chaining — you don't have to.

### A. "Free everything" — zero-dollar test rig
Best for first-time setup, kicking the tyres on a free key.

| Role | Backend      | Model | Notes                             |
|------|--------------|-------|-----------------------------------|
| Router | `openrouter` | `meta-llama/llama-3.2-3b-instruct:free` | sub-second classifier             |
| Shaper | `gemini`     | `gemma-4-31b-it` | Affidabile                        |
| Reasoner | `ollama`          | `qwen3.5:397b-cloud` | Potente come reasoner su codice   |
| Executor | `ollama`       | `glm-5.1:cloud` | Potente nella creazione di codice |

Why it works: OpenRouter `:free` has terrible latency but the Router's job is
trivial, so it doesn't matter. Groq carries Shaper + Executor (cheap, fast).
Gemini absorbs the heavy thinking on a generous free RPM.

---

### B. "Speed demon" — minimum latency
Trade some routing accuracy for raw throughput.

| Role | Backend | Model |
|------|---------|-------|
| Router | `groq` | `llama-3.1-8b-instant` |
| Shaper | `groq` | `llama-3.1-8b-instant` |
| Reasoner | `groq` | `llama-3.3-70b-versatile` |
| Executor | `groq` | `llama-3.3-70b-versatile` |

All four roles on Groq → backend cache collapses Reasoner+Executor into a
single rate-limited instance, so you really pay for two slots, not four.
Set TPM = 0 (unlimited) per role and let the per-key bucket govern.

---

### C. "Local edge + cloud brain" — privacy-leaning
Keeps every cheap call local; only the big thinker hits the cloud.

| Role | Backend | Model | `ollama_base_url` |
|------|---------|-------|-------------------|
| Router | `ollama` | `llama3.2:1b` | `http://localhost:11434` |
| Shaper | `ollama` | `llama3.2:3b` | `http://localhost:11434` |
| Reasoner | `gemini` | `gemini-2.5-pro` | — |
| Executor | `ollama` | `qwen2.5-coder:7b` | `http://localhost:11434` |

Run `ollama pull llama3.2:1b llama3.2:3b qwen2.5-coder:7b` first.
The Reasoner is the only role that ever leaves the machine.

---

### D. "Heavyweight tool use" — best for code-editing tasks
Optimises the Executor side because tool-call accuracy is the failure mode
that actually matters when the agent edits files.

| Role | Backend | Model |
|------|---------|-------|
| Router | `gemini` | `gemini-2.5-flash-lite` |
| Shaper | `gemini` | `gemini-2.5-flash` |
| Reasoner | `openrouter` | `deepseek/deepseek-r1:free` |
| Executor | `groq` | `qwen/qwen3-32b` |

Reasoner uses an R1-style thinking model for plan quality, Executor uses a
coder-tuned Qwen for clean JSON. Shaper/Router on Gemini for cheap throughput.

---

### E. "Ollama Cloud as backbone" — single Ollama account, mixed sizes
Cloud-only Ollama (set `ollama_base_url` to `https://ollama.com` and provide
`ollama_api_key`).

| Role | Backend | Model |
|------|---------|-------|
| Router | `ollama` | `gpt-oss:20b` |
| Shaper | `ollama` | `gpt-oss:20b` |
| Reasoner | `ollama` | `gpt-oss:120b` |
| Executor | `ollama` | `qwen3-coder:480b` |

The cache collapses Router + Shaper to one connection, Reasoner and Executor
each get their own. One key, four sizes — no other provider involved.

---

### F. "Anti-quota" — every role on a different free provider
Stretches free quotas the furthest by spreading load across four accounts.

| Role | Backend | Model |
|------|---------|-------|
| Router | `gemini` | `gemini-2.5-flash-lite` |
| Shaper | `groq` | `llama-3.1-8b-instant` |
| Reasoner | `openrouter` | `deepseek/deepseek-chat-v3.1:free` |
| Executor | `github` | `gpt-4o-mini` |

Four separate TPM buckets. No single provider can throttle you — you'd have
to exhaust all four free tiers in the same minute.

---

## 3. Mono-backend solutions

For when you don't want to juggle keys.

### Mono-A. "Gemini-only" (simplest — matches the built-in defaults)

| Role | Backend | Model |
|------|---------|-------|
| Router | `gemini` | `gemini-2.5-flash-lite` |
| Shaper | `gemini` | `gemini-2.5-flash` |
| Reasoner | `gemini` | `gemini-2.5-pro` |
| Executor | `gemini` | `gemini-2.5-flash` |

This is what `Reset to defaults` writes. One API key, three model tiers.
Free tier handles ~5 RPM on Pro, ~15 on Flash — fine for interactive use.

### Mono-B. "Groq-only"

| Role | Backend | Model |
|------|---------|-------|
| Router | `groq` | `llama-3.1-8b-instant` |
| Shaper | `groq` | `llama-3.1-8b-instant` |
| Reasoner | `groq` | `llama-3.3-70b-versatile` |
| Executor | `groq` | `llama-3.3-70b-versatile` |

Fastest single-vendor setup. The cache collapses to two backend instances.

### Mono-C. "OpenRouter-only" (free)

| Role | Backend | Model |
|------|---------|-------|
| Router | `openrouter` | `meta-llama/llama-3.2-3b-instruct:free` |
| Shaper | `openrouter` | `google/gemini-2.0-flash-exp:free` |
| Reasoner | `openrouter` | `deepseek/deepseek-r1:free` |
| Executor | `openrouter` | `qwen/qwen-2.5-72b-instruct:free` |

One key, four free models. Latency is the trade-off.

### Mono-D. "GitHub Models-only"

| Role | Backend | Model |
|------|---------|-------|
| Router | `github` | `Phi-3.5-mini-instruct` |
| Shaper | `github` | `gpt-4o-mini` |
| Reasoner | `github` | `gpt-4o` |
| Executor | `github` | `gpt-4o-mini` |

Free with a GitHub PAT. Daily request caps but generous for solo dev use.

### Mono-E. "Ollama-local-only" (fully offline)

| Role | Backend | Model |
|------|---------|-------|
| Router | `ollama` | `llama3.2:1b` |
| Shaper | `ollama` | `llama3.2:3b` |
| Reasoner | `ollama` | `qwen2.5:14b` |
| Executor | `ollama` | `qwen2.5-coder:7b` |

`base_url = http://localhost:11434`. Zero network dependency once models
are pulled. Reasoner quality is the limit — bump to 32B if your VRAM allows.

---

## 4. Per-role tuning recommendations

### Router
- `temperature` = **0.0** — needs to be deterministic.
- `max_tokens` = **8** — it only outputs one of three labels.
- `tpm_limit` = 0 — it's cheap and short.

### Shaper
- `temperature` = **0.2** — small creativity for rephrasing.
- `max_tokens` = **256** — one paragraph max.
- `tpm_limit` = 0 unless you're sharing the backend with the Reasoner.

### Reasoner
- `temperature` = **0.1–0.3** — too high and it hallucinates tool calls.
- `max_tokens` = **2048–8192** — bigger if you expect long final answers or
  multi-step plans.
- `tpm_limit` = match your provider's free-tier ceiling minus 20% headroom.

### Executor
- `temperature` = **0.3–0.5** — needs flexibility to summarise tool output.
- `max_tokens` = **1024** — usually enough for a tool-result digest.
- `tpm_limit` = same headroom rule as Reasoner.

---

## 5. Backend cache & rate limit interaction

Two roles that share the **same** `backend + model + tpm_limit + ollama_url +
ollama_num_ctx` end up sharing **one** rate-limited backend instance. This
means:

- **Mono-Groq with same model on Reasoner + Executor**: 1 TPM bucket, shared.
- **Mixed Groq Router + Groq Reasoner with different models**: 2 TPM buckets.
- **Mono-Gemini default**: Shaper and Executor both use `gemini-2.5-flash`
  with the same TPM → **one shared bucket**. Pro and Lite get their own.

Set `tpm_limit = 0` to disable the limiter entirely (the underlying provider
still applies its own quota).

---

## 6. Required API keys per backend

Make sure these are configured in **Settings → API Keys** (or environment
variables) before you point a role at the corresponding backend:

| Backend | Setting field | Env var fallback |
|---------|---------------|------------------|
| `gemini` | Gemini API key | `GOOGLE_API_KEY` or `GEMINI_API_KEY` |
| `groq` | Groq API key | `GROQ_API_KEY` |
| `openrouter` | OpenRouter API key | `OPENROUTER_API_KEY` |
| `github` | GitHub token | `GITHUB_TOKEN` or `GITHUB_API_KEY` |
| `huggingface` | HF token | (passed via `--hf-token`) |
| `ollama` | Ollama API key (cloud only) | (set in agent config) |

Missing a key for a referenced backend → that role crashes at first call and
the dispatcher logs `[workflow] <role> crashed:` to stderr. The workflow
falls back as best it can (router crash → "reasoning"; shaper crash → raw
input). A missing **Reasoner** key is fatal — you cannot start the workflow
without one.

---

## 7. How to switch on the workflow

1. Open the app → **Settings** (gear icon).
2. Pick the **Workflow Agents** tab in the left rail.
3. Toggle the **master switch** at the top to enable multi-agent mode.
4. Configure each role card from the recipes above.
5. Click **Reset to defaults** any time to return to Mono-A (Gemini-only).
6. Start a new chat — the trace stream now shows per-agent steps.

When the master switch is **off**, the orchestrator boots in the original
single-agent mode and ignores every per-role assignment. Toggle freely.

---

## 8. Reading the trace

Each turn now returns a structured trace alongside the answer. In the chat
UI you'll see badges next to each step:

- `router` — picked the route (`trivial` / `reasoning` / `tool`)
- `shaper` — rewrote the prompt (skipped on follow-up turns)
- `reasoner` — decided / wrote the answer / requested a tool
- `executor` — ran the tool, returned the result

If you only see `executor` and nothing else, the Router classified your
input as trivial and short-circuited — that's the design, not a bug. Try
something more substantive (e.g. "edit lib/foo.dart to …") to exercise the
full chain.

---

## 9. Failure modes and what they look like

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Trace shows only `router` then a generic answer | Router crashed (missing API key for its backend) | Check API key for the Router's backend |
| Reasoner emits raw `<tool>` tags as text | Reasoner model can't follow instructions | Swap Reasoner to a stronger model (≥8B for Llama-class, or use R1/Qwen) |
| "Reached max workflow iterations (8)" | Reasoner stuck in a tool-call loop | Lower Reasoner temperature, or pick a model with better grounding |
| Random `RateLimitExceeded` despite low usage | Two roles sharing a TPM bucket too aggressively | Give one role its own model (different cache key) or raise TPM cap |
| Workflow refuses to start: "agents.json must define reasoner" | Reasoner role unset in Settings | Open Workflow Agents → Reasoner card, fill backend + model |

---

## 10. Quick-start checklist

1. ☐ `git checkout agentic_flow`
2. ☐ `flutter pub get`
3. ☐ Run the app, open Settings → API Keys, fill keys for backends you'll use.
4. ☐ Settings → Workflow Agents → flip master switch ON.
5. ☐ Pick a recipe from §2 or §3 above. Paste model names into each role.
6. ☐ Start a new chat. Try:
   - `"hi"` → should hit the trivial path (Executor only).
   - `"explain how the auth middleware works"` → reasoning path (Shaper + Reasoner).
   - `"edit lib/main.dart and add a comment at line 1"` → tool path (full chain).
7. ☐ Watch the trace badges — each step should produce one.

If all three behave, the workflow is wired correctly and you can start
mixing in your preferred recipe.
