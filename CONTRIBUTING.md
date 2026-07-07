# Contributing to Agentic

Thank you for your interest in contributing to Agentic! This document outlines the process for reporting bugs, suggesting features, and submitting code changes.

---

## 🐛 Reporting bugs

Before opening a bug report:

1. **Search existing issues** to avoid duplicates.
2. Check if the bug is already fixed on the `development` branch.

When opening a bug report, please include:

- **OS and version** (Windows 11, Ubuntu 22.04, macOS 14, etc.)
- **Flutter version** (`flutter --version`)
- **Python version** (`python --version`)
- **Backend used** (HuggingFace, Ollama, Groq, Gemini, OpenRouter, GitHub Models)
- **Model ID**
- **Steps to reproduce** the issue
- **Expected behavior** vs **actual behavior**
- **Relevant logs** (from the app or `logs/orchestrator_audit.log`)
- **Screenshots** if applicable

Use the [Bug Report template](.github/ISSUE_TEMPLATE/bug_report.md).

---

## ✨ Suggesting features

Feature requests are welcome! Please:

1. Search existing issues first.
2. Describe the feature and its use case clearly.
3. Explain why it would be useful to the project.

Use the [Feature Request template](.github/ISSUE_TEMPLATE/feature_request.md).

---

## 🔧 Development setup

### Prerequisites

- Flutter >= 3.19.0
- Dart >= 3.3.0
- Python >= 3.10

### Steps



---

## 📏 Coding standards

### Dart (Flutter)

- Follow the [Dart style guide](https://dart.dev/guides/language/effective-dart)
- Use `flutter analyze` — your code must pass with zero errors and zero warnings
- Prefer composition over inheritance
- Keep widgets small and focused; extract reusable widgets
- Use the existing state management pattern (`StateManager` + `MethodListener`)
- Document public APIs with `///` doc comments

### Python (Orchestrator)

- Follow [PEP 8](https://peps.python.org/pep-0008/)
- Use type hints (`from __future__ import annotations`)
- Run `ruff check` and `ruff format` before committing
- Keep functions focused and well-documented
- Prefer lazy imports for optional dependencies (see `agent/backends/__init__.py`)

### General

- **No debug prints** in committed code — use the logger utility
- **No commented-out code blocks** — delete them
- **No TODOs** without a linked issue
- Write clear commit messages (see below)
- Test your changes before opening a PR

---

## 📤 Submitting a pull request

1. **Create a branch** from `development`:
   

2. **Make your changes** following the coding standards above.

3. **Test thoroughly**:
   

4. **Commit with clear messages**:
   

   Use [conventional commits](https://www.conventionalcommits.org/):
   - `feat:` — new feature
   - `fix:` — bug fix
   - `docs:` — documentation only
   - `refactor:` — code change that neither fixes a bug nor adds a feature
   - `test:` — adding or correcting tests
   - `chore:` — build, tooling, dependencies

5. **Push and open a PR**:
   

   Open a pull request targeting the `development` branch. Fill in the [PR template](.github/PULL_REQUEST_TEMPLATE.md).

6. **Address review feedback** — be responsive to comments and make requested changes.

---

## 🔄 Git workflow

- `main` — stable release branch. Only merge from `development` after thorough testing.
- `development` — active development branch. PRs should target this branch.
- `feature/*` — feature branches, branched from `development`.
- `fix/*` — bugfix branches, branched from `development`.

---

## ✅ PR checklist

Before opening a pull request, make sure:

- [ ] Code passes `flutter analyze` with zero errors and zero warnings
- [ ] All existing tests pass (`flutter test`)
- [ ] New features have corresponding tests
- [ ] No debug prints or commented-out code
- [ ] Commit messages follow conventional commits
- [ ] PR description explains what changed and why
- [ ] PR targets the `development` branch

---

## 💬 Questions?

Open a [discussion](https://github.com/YOUR_USERNAME/agentic/discussions) or an issue with the `question` label.

---

Thank you for contributing! 🎉
