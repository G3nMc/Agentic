"""On-disk layout for a Team Mode session.

    <project>/.agent/team/<session_id>/
        team_board.md
        artifacts/
            <group>.json
        recovery.log              (optional, audit of leader recovery decisions)
        workers/
            <group>.stdout.log
            <group>.stderr.log

``session_id`` is the conversation id (UUID-shaped) coming from the
Flutter chat. Per-conversation isolation prevents one chat's Team Mode
run from clobbering another's board/artifacts when the user switches
between chats. Deleting a chat → recursively delete that subfolder.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path

# Conservative whitelist for session-id components going into a path
# segment. Conversation ids are UUIDs in practice, but we accept the
# usual safe characters to stay tolerant of future id schemes.
_SAFE_SESSION_ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
_DEFAULT_SESSION_ID = "_default"


def _sanitize_session_id(session_id: str | None) -> str:
    """Reject path-traversal / weird characters in the session id.

    Falls back to ``_default`` rather than raising — the team layer is
    a feature add, not a place to refuse to start.
    """
    if not session_id:
        return _DEFAULT_SESSION_ID
    s = str(session_id).strip()
    if not s or s in (".", "..") or "/" in s or "\\" in s:
        return _DEFAULT_SESSION_ID
    if not _SAFE_SESSION_ID_RE.match(s):
        # Keep only safe characters; if nothing remains, use default.
        s = re.sub(r"[^A-Za-z0-9._-]", "", s)
        if not s:
            return _DEFAULT_SESSION_ID
    return s


@dataclass(frozen=True)
class TeamPaths:
    """Bundle of absolute paths a host or worker needs.

    ``base_path`` is the project root (the same one the orchestrator
    confines tools to). All team artefacts live under
    ``<base_path>/.agent/team/<session_id>/``.
    """
    base_path: Path
    session_id: str = _DEFAULT_SESSION_ID

    @classmethod
    def from_base(cls, base_path: str | os.PathLike[str],
                  session_id: str | None = None) -> "TeamPaths":
        return cls(
            base_path=Path(base_path).resolve(),
            session_id=_sanitize_session_id(session_id),
        )

    @classmethod
    def for_session(cls, base_path: str | os.PathLike[str],
                    session_id: str) -> "TeamPaths":
        """Explicit constructor used by team-mode entry points."""
        return cls.from_base(base_path, session_id=session_id)

    @property
    def team_root(self) -> Path:
        """Per-project team directory (parent of all session folders)."""
        return self.base_path / ".agent" / "team"

    @property
    def root(self) -> Path:
        """Per-session directory."""
        return self.team_root / self.session_id

    @property
    def board(self) -> Path:
        return self.root / "team_board.md"

    @property
    def artifacts_dir(self) -> Path:
        return self.root / "artifacts"

    def artifact_path(self, group: str) -> Path:
        return self.artifacts_dir / f"{group}.json"

    @property
    def workers_dir(self) -> Path:
        return self.root / "workers"

    def worker_stdout(self, group: str) -> Path:
        return self.workers_dir / f"{group}.stdout.log"

    def worker_stderr(self, group: str) -> Path:
        return self.workers_dir / f"{group}.stderr.log"

    @property
    def recovery_log(self) -> Path:
        return self.root / "recovery.log"

    def ensure_dirs(self) -> None:
        """Create the directory tree if missing. Idempotent."""
        self.root.mkdir(parents=True, exist_ok=True)
        self.artifacts_dir.mkdir(parents=True, exist_ok=True)
        self.workers_dir.mkdir(parents=True, exist_ok=True)


def session_dir_for(base_path: str | os.PathLike[str],
                    session_id: str) -> Path:
    """Compute the per-session directory without instantiating TeamPaths.

    Used by the chat-delete cleanup helper.
    """
    safe = _sanitize_session_id(session_id)
    return Path(base_path).resolve() / ".agent" / "team" / safe


def delete_session(base_path: str | os.PathLike[str],
                   session_id: str) -> bool:
    """Recursively remove a session's directory.

    Returns True if the folder existed and was removed, False otherwise.
    Refuses (and returns False) when sanitisation would map ``session_id``
    to the default sentinel — protects against accidentally wiping
    legacy/shared content.
    """
    safe = _sanitize_session_id(session_id)
    if safe == _DEFAULT_SESSION_ID and session_id != _DEFAULT_SESSION_ID:
        return False
    target = session_dir_for(base_path, session_id)
    if not target.exists():
        return False
    import shutil
    shutil.rmtree(target, ignore_errors=True)
    return not target.exists()
