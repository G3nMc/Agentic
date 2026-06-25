// Canonical `.context.md` naming and template, shared by the Settings editor
// and the auto-generate flow so the two never drift.
//
// Mirrors `bin/common/core/project_context.py` (CONTEXT_TEMPLATE) -- keep the
// two in sync. The file lives at `<project-root>/.agentic/.context.md` and is
// organised around three natures: Operative (what the app does), Technical
// (how it is built), and Other Resources.

/// Sub-directory (under the project root) that holds the context file.
const String kAgentContextDirName = '.agentic';

/// Canonical context file name (preferred over the legacy `.agent.md`).
const String kAgentContextFileName = '.context.md';

/// Well-structured `.context.md` template, organised around three natures.
const String kAgentContextTemplate = r'''# Project Context

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
''';
