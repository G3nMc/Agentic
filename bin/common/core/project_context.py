"""Load and parse a per-project agent context file (``.context.md``).

Canonical location is ``<project-root>/.agentic/.context.md`` (the project
root is the ``--base-path`` directory). Legacy names (``.agent.md`` /
``context.md`` / ``AGENT.md``) and a root-level placement are still accepted
as fallbacks. The file is optional — when missing the system prompt stays
exactly as it is today.

Format
------
The file is Markdown. Sections are delimited by ``## Section Name`` headers.
Everything before the first ``##`` is treated as a preamble and injected as
a compact "Project Context" block. Recognised section headers are mapped to
the corresponding system-prompt sections.

Example::

    # Project Context
    This is a Flutter + Python project for electronic invoicing.

    ## Agent Identity & Role
    - **Agent Name**: backend-senior
    - **Role / Persona**: Senior Java backend engineer

    ## Project Structure & Standards
    - **Project Structure**: Multi-module Maven project
    - **Coding Standards**: Constructor injection only

    ## Behavioral Rules
    - **Must Always**: Complete classes, never partial
    - **Must Never**: No emoji in code comments

    ## Current State & Working Context
    - **Codebase Overview**: InvoiceService handles CRUD
    - **Known Issues / Tech Debt**: DB pool exhaustion under load

The merged prompt will contain a ``[PROJECT CONTEXT]`` section between the
hard-coded base prompt and the tool catalog.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Optional

# Canonical file names tried in order. First match wins. ``.context.md`` is
# the preferred name; the others are accepted for backward compatibility.
_CANDIDATE_FILES = (".context.md", ".agent.md", "context.md", "AGENT.md")

# Sub-directories searched (in order) for the context file, relative to the
# project root. ``.agentic/`` is the canonical home (the Flutter UI writes
# ``<root>/.agentic/.context.md``); the project root is kept as a fallback
# for older setups.
_CANDIDATE_DIRS = (".agentic", "")

# Markdown heading pattern: ## Heading Text
_HEADING_RE = re.compile(r"^##\s+(.+)$")

# Maximum chars of the project context file we'll read. 32 KB is generous
# for a hand-written config while guarding against accidental large files.
_MAX_FILE_BYTES = 32_768

# Canonical relative location of the context file (the Flutter UI writes here).
CONTEXT_REL_PATH = ".agentic/.context.md"

# Canonical ``.context.md`` template -- the single source of truth for the
# structure. The Flutter generator/seed mirror this. It is organised around
# three "natures":
#   * Operative Nature  -- what the app does and how it is used.
#   * Technical Nature  -- how it is built (stack, architecture, data, APIs).
#   * Other Resources   -- everything else useful to a coding agent.
# Returned by :func:`recommended_template` so callers don't import the raw
# constant name.
CONTEXT_TEMPLATE = """# Project Context

## Overview
<One or two sentences: what this project is.>

## Operative Nature
- **Purpose**: what the app does and the problem it solves
- **Primary Use Cases / User Flows**:
- **Key Features**:
- **Target Users / Domain**:

## Technical Nature
- **Tech Stack**: Backend (Python, <framework>); Frontend (Flutter)
- **Architecture & Layers**: how backend and frontend are structured and interact
- **Key Modules & Responsibilities**:
- **Data Models / Persistence**: storage, schemas, migrations
- **API / Endpoints**: routes/contracts and how the frontend consumes them
- **Build & Run**: how to start the backend and the Flutter app (commands, env)
- **Coding Standards**:
- **Testing**:

## Project Structure
- **Directory Layout**: key folders and what lives where
- **Dependencies**: notable backend and frontend packages

## Current State & Working Context
- **Codebase Overview**:
- **Recent Changes**:
- **Known Issues / Tech Debt**:
- **Immediate Focus**:

## Behavioral Rules
- **Must Always**: place temporary/helper files under `.agentic/` (create it if missing) and delete them when done; never create them in the project root
- **Must Never**:

## Other Resources
- **External Docs / Links**:
- **Config & Env Vars**:
- **Database Connections**:
- **Notes**:
"""


def recommended_template() -> str:
    """Return the canonical, well-structured ``.context.md`` template."""
    return CONTEXT_TEMPLATE


def _find_context_file(base_path: str | Path) -> Optional[Path]:
    """Return the first existing context file under *base_path*, or None.

    Search order: each candidate name inside ``.agentic/`` first, then the
    project root. ``.agentic/.context.md`` therefore wins over a legacy
    root-level ``.agent.md``.
    """
    root = Path(base_path)
    if not root.is_dir():
        return None
    for subdir in _CANDIDATE_DIRS:
        location = root / subdir if subdir else root
        for name in _CANDIDATE_FILES:
            candidate = location / name
            if candidate.is_file():
                return candidate
    return None


def _parse_sections(raw: str) -> dict[str, str]:
    """Split *raw* Markdown into ``{section_name: body}``.

    The preamble (everything before the first ``##``) is stored under the
    empty-string key ``""``.
    """
    sections: dict[str, str] = {}
    current_name = ""
    current_lines: list[str] = []

    for line in raw.splitlines():
        m = _HEADING_RE.match(line)
        if m:
            # Store previous section
            body = "\n".join(current_lines).strip()
            if body:
                sections[current_name] = body
            current_name = m.group(1).strip()
            current_lines = []
        else:
            current_lines.append(line)

    # Flush last section
    body = "\n".join(current_lines).strip()
    if body:
        sections[current_name] = body

    return sections


def load_project_context(base_path: str | Path) -> Optional[str]:
    """Read the project context file and return its parsed content.

    Returns None when no context file exists or it can't be read.
    """
    file_path = _find_context_file(base_path)
    if file_path is None:
        return None

    try:
        raw = file_path.read_text(encoding="utf-8")[:_MAX_FILE_BYTES]
    except (OSError, UnicodeDecodeError):
        return None

    if not raw.strip():
        return None

    sections = _parse_sections(raw)

    # Build a compact representation for the system prompt.
    lines: list[str] = []

    # Preamble becomes the overview.
    preamble = sections.pop("", "")
    if preamble:
        # If preamble starts with a level-1 heading, strip it — we add our own.
        preamble = re.sub(r"^#\s+.*\n?", "", preamble).strip()
        if preamble:
            lines.append(preamble)

    # Map common section names to prompt-friendly labels.
    _SECTION_LABELS: dict[str, str] = {
        "agent identity & role": "Agent Identity & Role",
        "agent identity and role": "Agent Identity & Role",
        "knowledge & skills": "Knowledge & Skills",
        "knowledge and skills": "Knowledge & Skills",
        "core competencies": "Core Competencies",
        "domain knowledge": "Domain Knowledge",
        "project structure & standards": "Project Structure & Standards",
        "project structure and standards": "Project Structure & Standards",
        "coding standards": "Coding Standards",
        "testing requirements": "Testing Requirements",
        "current state & working context": "Current State & Working Context",
        "current state and working context": "Current State & Working Context",
        "codebase overview": "Codebase Overview",
        "recent changes": "Recent Changes",
        "known issues / tech debt": "Known Issues / Tech Debt",
        "known issues": "Known Issues",
        "tech debt": "Tech Debt",
        "immediate focus": "Immediate Focus",
        "behavioral rules": "Behavioral Rules",
        "must always": "Must Always",
        "must never": "Must Never",
        "communication style": "Communication Style",
        "tools & workflow": "Tools & Workflow",
        "tools and workflow": "Tools & Workflow",
        "available tools": "Available Tools",
        "workflow notes": "Workflow Notes",
        # --- Structured ".context.md" natures ---
        "overview": "Overview",
        "operative nature": "Operative Nature",
        "technical nature": "Technical Nature",
        "architecture & layers": "Architecture & Layers",
        "architecture and layers": "Architecture & Layers",
        "architecture": "Architecture",
        "key modules & responsibilities": "Key Modules & Responsibilities",
        "key modules and responsibilities": "Key Modules & Responsibilities",
        "key modules": "Key Modules",
        "data models / persistence": "Data Models / Persistence",
        "data models": "Data Models",
        "persistence": "Persistence",
        "api / endpoints": "API / Endpoints",
        "api & endpoints": "API / Endpoints",
        "api and endpoints": "API / Endpoints",
        "endpoints": "Endpoints",
        "build & run": "Build & Run",
        "build and run": "Build & Run",
        "project structure": "Project Structure",
        "directory layout": "Directory Layout",
        "dependencies": "Dependencies",
        "other resources": "Other Resources",
        "external resources": "External Resources",
        "external docs / links": "External Docs / Links",
        "config & env vars": "Config & Env Vars",
        "database connections": "Database Connections",
    }

    for name, body in sections.items():
        key = name.lower().strip()
        label = _SECTION_LABELS.get(key, name)
        lines.append(f"{label}:")
        # Indent body lines for readability inside the prompt.
        for bline in body.splitlines():
            bline = bline.strip()
            if bline:
                lines.append(f"  {bline}")
        lines.append("")  # blank line between sections

    result = "\n".join(lines).strip()
    return result or None


def merge_context_into_prompt(base_prompt: str, project_context: Optional[str]) -> str:
    """Insert *project_context* into *base_prompt* as a ``[PROJECT CONTEXT]`` block.

    The block is placed after the hard-coded base but before the tool catalog.
    When *project_context* is None or empty, *base_prompt* is returned unchanged.
    """
    if not project_context or not project_context.strip():
        return base_prompt

    block = (
        "\n\n"
        "PROJECT CONTEXT (from .agentic/.context.md)\n"
        "===========================================\n"
        f"{project_context.strip()}\n"
    )

    # Insert before the tool catalog (which starts with "[Filesystem]" or
    # "AVAILABLE TOOLS"). If neither marker is found, append at the end.
    for marker in ("\n[Filesystem]", "\nAVAILABLE TOOLS"):
        idx = base_prompt.find(marker)
        if idx != -1:
            return base_prompt[:idx] + block + base_prompt[idx:]

    return base_prompt + block
