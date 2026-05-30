"""Handoff artifact — JSON written by each worker, read by downstream workers.

Frozen schema (v1):

    {
      "group": str,
      "schema_version": 1,
      "produced_at": ISO-8601 UTC,
      "producer_model": str,
      "status": one of Status,
      "summary": str,
      "decisions":         [ {id, what, why, notes?}, ... ],
      "files_touched":     [ {path, action}, ... ],
      "interfaces_exposed":[ {name, type, notes?}, ... ],
      "open_questions":    [ {question, context?}, ... ],
      "warnings":          [ str, ... ]
    }

Hard rules:
  - Overwrite, never append (idempotent retry).
  - ``schema_version`` lets readers tolerate older payloads; bump on
    additive changes, redesign on incompatible ones.
  - ``ARTIFACT_MAX_BYTES`` is the soft cap. ``Artifact.trim_to_budget``
    drops fields per priority list when the serialized payload is over.
"""

from __future__ import annotations

import json
import os
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

from .status import Status

ARTIFACT_SCHEMA_VERSION = 1
ARTIFACT_MAX_BYTES = 8 * 1024


def _utcnow_iso() -> str:
    """ISO-8601 UTC stamp, second precision, with trailing Z."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class Artifact:
    group: str
    producer_model: str
    status: Status = Status.DONE_CLEAN
    summary: str = ""
    decisions: List[Dict[str, Any]] = field(default_factory=list)
    files_touched: List[Dict[str, Any]] = field(default_factory=list)
    interfaces_exposed: List[Dict[str, Any]] = field(default_factory=list)
    open_questions: List[Dict[str, Any]] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)
    produced_at: str = field(default_factory=_utcnow_iso)
    schema_version: int = ARTIFACT_SCHEMA_VERSION

    # ------------------------------------------------------------------
    # Serialization
    # ------------------------------------------------------------------
    def to_dict(self) -> Dict[str, Any]:
        return {
            "group": self.group,
            "schema_version": self.schema_version,
            "produced_at": self.produced_at,
            "producer_model": self.producer_model,
            "status": self.status.value,
            "summary": self.summary,
            "decisions": list(self.decisions),
            "files_touched": list(self.files_touched),
            "interfaces_exposed": list(self.interfaces_exposed),
            "open_questions": list(self.open_questions),
            "warnings": list(self.warnings),
        }

    @classmethod
    def from_dict(cls, d: Dict[str, Any]) -> "Artifact":
        return cls(
            group=str(d.get("group") or ""),
            producer_model=str(d.get("producer_model") or ""),
            status=Status.parse(str(d.get("status") or "DONE_CLEAN")),
            summary=str(d.get("summary") or ""),
            decisions=list(d.get("decisions") or []),
            files_touched=list(d.get("files_touched") or []),
            interfaces_exposed=list(d.get("interfaces_exposed") or []),
            open_questions=list(d.get("open_questions") or []),
            warnings=[str(w) for w in (d.get("warnings") or [])],
            produced_at=str(d.get("produced_at") or _utcnow_iso()),
            schema_version=int(d.get("schema_version") or ARTIFACT_SCHEMA_VERSION),
        )

    def to_json(self, indent: Optional[int] = 2) -> str:
        return json.dumps(self.to_dict(), ensure_ascii=False, indent=indent)

    @classmethod
    def from_json(cls, raw: str) -> "Artifact":
        return cls.from_dict(json.loads(raw))

    # ------------------------------------------------------------------
    # Size enforcement (soft circuit breaker, producer side)
    # ------------------------------------------------------------------
    def serialized_bytes(self) -> int:
        return len(self.to_json().encode("utf-8"))

    def trim_to_budget(self, max_bytes: int = ARTIFACT_MAX_BYTES) -> List[str]:
        """Drop fields in priority order until the artifact fits.

        Order (least valuable first):
          1. ``decisions[].notes``
          2. ``open_questions[].context``
          3. ``interfaces_exposed[].notes``
          4. trim ``summary`` to ~400 chars
          5. drop trailing ``decisions`` entries beyond the first 5
          6. drop trailing ``files_touched`` beyond the first 20

        Returns the list of mutations applied so the caller (worker)
        can record them in ``warnings`` if that matters to it.
        """
        applied: List[str] = []

        if self.serialized_bytes() <= max_bytes:
            return applied

        for d in self.decisions:
            if "notes" in d:
                d.pop("notes", None)
        applied.append("dropped:decisions[].notes")
        if self.serialized_bytes() <= max_bytes:
            return applied

        for q in self.open_questions:
            if "context" in q:
                q.pop("context", None)
        applied.append("dropped:open_questions[].context")
        if self.serialized_bytes() <= max_bytes:
            return applied

        for i in self.interfaces_exposed:
            if "notes" in i:
                i.pop("notes", None)
        applied.append("dropped:interfaces_exposed[].notes")
        if self.serialized_bytes() <= max_bytes:
            return applied

        if len(self.summary) > 400:
            self.summary = self.summary[:397] + "..."
            applied.append("trimmed:summary")
        if self.serialized_bytes() <= max_bytes:
            return applied

        if len(self.decisions) > 5:
            self.decisions = self.decisions[:5]
            applied.append("truncated:decisions")
        if self.serialized_bytes() <= max_bytes:
            return applied

        if len(self.files_touched) > 20:
            self.files_touched = self.files_touched[:20]
            applied.append("truncated:files_touched")

        return applied


# ----------------------------------------------------------------------
# Atomic file I/O
# ----------------------------------------------------------------------
def write_artifact(path: Path, artifact: Artifact) -> None:
    """Atomically overwrite ``path`` with ``artifact``'s JSON.

    Idempotent: a retried worker should call this with the fresh
    Artifact and the previous file is replaced byte-for-byte.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = artifact.to_json()
    fd, tmp_path = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=str(path.parent),
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            f.write(payload)
            f.flush()
            try:
                os.fsync(f.fileno())
            except OSError:
                # Some filesystems (e.g. network shares) don't support fsync.
                pass
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def read_artifact(path: Path) -> Artifact:
    """Read and parse an artifact file. Raises FileNotFoundError if absent."""
    with open(path, "r", encoding="utf-8") as f:
        return Artifact.from_json(f.read())
