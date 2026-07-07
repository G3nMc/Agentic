# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- Initial open-source release preparation
- README, LICENSE, CONTRIBUTING, CHANGELOG
- GitHub issue templates and PR template

---

## [1.0.0] - 2024-01-01

### Added
- Multi-backend LLM chat (HuggingFace, Ollama, Groq, Gemini, OpenRouter, GitHub Models)
- Local Python orchestrator with filesystem tools (read, write, patch, search, run commands, git)
- Task-flow protocol with structured plans and progress tracking
- Conversation management with SQLite persistence
- Context summaries for long conversations
- Dark developer theme with Markdown rendering and syntax highlighting
- Desktop drag-and-drop file attachment
- Secure API key storage
- Sandbox mode for read-only code review
- Audit logging for all tool calls
- Configurable filesystem filters
- Database connections (SQLite, MariaDB, SQL Server)
- Circuit breaker and retry handler for resilient API calls
- Custom state management (StateManager + MethodListener pattern)

[Unreleased]: https://github.com/YOUR_USERNAME/agentic/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/YOUR_USERNAME/agentic/releases/tag/v1.0.0
