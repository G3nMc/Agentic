"""Shared core utilities (project context loading, etc.).

Mode-specific state objects live elsewhere:
  - :mod:`agent.core.state` — single-agent trace/route state
  - :mod:`multi_mode.core.state` — multi-agent task/message state

This package only hosts code that's actually reused across both modes.
"""
