"""On-disk layout for a Team Mode session.

    <project>/.agent/team/
        team_board.md
        artifacts/
            <group>.json
        recovery.log         (optional, audit of leader recovery decisions)
        workers/
            <group>.stdout.log
            <group>.stderr.log
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class TeamPaths:
    """Bundle of absolute paths a host or worker needs.

    ``base_path`` is the project root (the same one the orchestrator
    confines tools to). All team artefacts live under
    ``<base_path>/.agent/team/``.
    """
    base_path: Path

    @classmethod
    def from_base(cls, base_path: str | os.PathLike[str]) -> "TeamPaths":
        return cls(base_path=Path(base_path).resolve())

    @property
    def root(self) -> Path:
        return self.base_path / ".agent" / "team"

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
