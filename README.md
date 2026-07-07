# 🤖 Agentic

**Multi-backend LLM chat and orchestrator workbench.**

Agentic is a Flutter desktop application that lets you chat with multiple LLM providers (HuggingFace, Ollama, Groq, Gemini, OpenRouter, GitHub Models) through a unified interface. It includes a local Python orchestrator that gives the model filesystem tools — read/write files, run commands, search code, validate builds — so it can act as a real coding assistant on your machine.

---

## ✨ Features

- **Multi-backend support** — HuggingFace Inference, Ollama (local & cloud), Groq Cloud, Google Gemini, OpenRouter, GitHub Models
- **Local orchestrator** — a Python subprocess gives the model real filesystem tools (read, write, patch, search, run commands, git operations)
- **Task-flow protocol** — structured plan → execute → report workflow with progress tracking
- **Conversation management** — persistent chat history with SQLite, conversation grouping, context summaries
- **Code-aware UI** — Markdown rendering with syntax highlighting, dark developer theme
- **Desktop drag & drop** — attach files to prompts by dragging from the OS
- **Secure storage** — API keys stored via platform secure storage
- **Sandbox mode** — restrict the orchestrator to read-only operations for safe code review
- **Audit logging** — every tool call logged with timestamp and parameters
- **Configurable filesystem filters** — exclude/include directories and files from orchestrator discovery
- **Database connections** — connect to SQLite/MariaDB/SQL Server and let the model query them

---

## 🏗️ Architecture



### Project structure



---

## 🚀 Getting started

### Prerequisites

- **Flutter** >= 3.19.0 ([install guide](https://docs.flutter.dev/get-started/install))
- **Dart** >= 3.3.0 (bundled with Flutter)
- **Python** >= 3.10 ([install guide](https://www.python.org/downloads/))
- At least one LLM backend:
  - A HuggingFace API token ([get one](https://huggingface.co/settings/tokens)), or
  - Ollama installed locally ([download](https://ollama.com)), or
  - A Groq API key ([get one](https://console.groq.com/keys)), or
  - A Google AI Studio API key ([get one](https://aistudio.google.com/app/apikey)), or
  - An OpenRouter API key ([get one](https://openrouter.ai/keys)), or
  - A GitHub PAT with `models:read` scope

### Install & run



### Configure your backend

1. Launch the app
2. Open **Settings** (gear icon)
3. Choose your backend (HuggingFace, Ollama, Groq, Gemini, OpenRouter, or GitHub Models)
4. Enter your API key / configure the local server
5. Select a model
6. Start chatting!

---

## 🔧 Configuration

### Backends

| Backend | API Key Required | Local/Cloud | Notes |
|---------|:---:|:---:|-------|
| HuggingFace | ✅ | Cloud | Default. Uses HF Inference router |
| Ollama | ❌ (local) / ✅ (cloud) | Both | Run models locally or via Ollama Cloud |
| Groq | ✅ | Cloud | Ultra-fast LPU inference |
| Gemini | ✅ | Cloud | Google AI Studio |
| OpenRouter | ✅ | Cloud | Routes to 100+ models |
| GitHub Models | ✅ (PAT) | Cloud | GitHub Models endpoint |

### Orchestrator CLI

The Python orchestrator can also be used standalone:



### Filesystem filters

Create a JSON config to restrict which directories the orchestrator can see:



Pass it with `--filters-config path/to/config.json`.

---

## 📦 Build

### Desktop builds



Build artifacts are placed in `build/`.

---

## 🧪 Testing



---

## 📝 License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.

---

## 🤝 Contributing

Contributions are welcome! Please read the [contributing guidelines](CONTRIBUTING.md) before opening a pull request.

---

## 📋 Changelog

See [CHANGELOG.md](CHANGELOG.md) for release history.

---

## ⚠️ Disclaimer

Agentic gives the LLM filesystem access on your machine through the Python orchestrator. **Use sandbox mode** (`--sandbox`) if you want read-only access. Always review what the model is doing — the audit log (`logs/orchestrator_audit.log`) records every tool call.

The software is provided "as is", without warranty of any kind. See the [LICENSE](LICENSE) for full terms.
