"""Configurable path filter applied to filesystem-discovery tools.

The ToolRegistry consults a :class:`PathFilter` before listing directories
or returning files from `list_files`, `list_files_recursive`, `find_files`,
and `search_in_files`. Read/write tools are intentionally NOT gated by
this filter — the user can still ask the model to read or fix a specific
file inside an "excluded" location. Filters cut noise during discovery,
they don't form a security wall.

Pattern syntax (kept deliberately small):

  Directories
    - bare basename (no separator) -> matches any directory with that
      name anywhere under base_path. e.g. ``node_modules``,
      ``__pycache__``.
    - absolute path -> matches that exact directory and everything
      under it.

  Files
    - ``*.<ext>`` glob -> matches any file with that extension anywhere
      under base_path. e.g. ``*.exe``, ``*.png``.
    - absolute path -> matches that exact file.

Decision rule (per kind: dir vs file)
    The semantics adapt to which lists the user has populated, so the
    same UI supports both common mental models:

    1. **Whitelist mode** — includes set, no user excludes for this kind.
       Only the listed paths (and their descendants for dirs) are
       visible; everything else is denied. Useful for "I only care
       about lib/ and bin/". The project root is always allowed in
       this mode so the walk can enter and filter children.

    2. **Blacklist with overrides** — both lists set, OR excludes only.
       The hardcoded baseline (.git, __pycache__, etc.) plus the user's
       excludes hide listed paths; user includes patch holes back open.
       Specificity rank for a tie-breaker:
           3 = absolute-path match
           2 = literal-name (basename or extension) match
           0 = no match
       On a tie, includes win.

    3. **Default-allow** — neither list set. Only the hardcoded baseline
       is enforced; everything else is visible.

Baseline
    The filter always also enforces a small hardcoded baseline of
    "noise" directory names (``.git``, ``__pycache__``, ``.dart_tool``,
    ``build``, ``node_modules``, ``.gradle``). The user can override any
    of them by adding the same name to ``include_dirs``.
"""
from __future__ import annotations

import sys as _sys
_sys.dont_write_bytecode = True

import os
from dataclasses import dataclass, field
from pathlib import Path, PurePath
from typing import Iterable, List, Optional, Sequence, Tuple


# Hardcoded noise baseline. Always added to the exclude side unless the
# user explicitly includes the same name. Kept tight on purpose — the
# bigger SKIP_EXT/SKIP_DIRS sets that used to live in fs_read.py are now
# the user's responsibility to add (we no longer assume what they want).
_BASELINE_EXCLUDE_DIRS: Tuple[str, ...] = (
    ".git", "__pycache__", ".dart_tool", "build", "node_modules", ".gradle",
)


def _is_absolute(entry: str) -> bool:
    """True if ``entry`` looks like an absolute path on this OS."""
    if not entry:
        return False
    p = PurePath(entry)
    return p.is_absolute() or (len(entry) >= 2 and entry[1] == ":")


def _normalize_abs(entry: str) -> str:
    """Resolve to a comparable absolute string (case-folded on Windows)."""
    norm = os.path.normpath(entry)
    if os.name == "nt":
        norm = norm.lower()
    return norm


def _is_ext_glob(entry: str) -> bool:
    """True for the ``*.ext`` shape — the only file-glob form we accept."""
    return entry.startswith("*.") and "/" not in entry and "\\" not in entry


def _looks_like_ext_glob_loose(entry: str) -> bool:
    """Same as :func:`_is_ext_glob` but also accepts the common typo ``*md``
    (missing dot). Used only by the input-cleaning pass — the actual
    matching code still requires the canonical ``*.ext`` form.
    """
    return (entry.startswith("*")
            and len(entry) > 1
            and "/" not in entry
            and "\\" not in entry)


def _normalize_user_filter_entries(entries):
    """Tolerant cleanup of user-supplied filter list values.

    Handles two real-world mistakes seen in the field:

    1. The user typed a comma-separated list as ONE entry, e.g.
       ``"*.py, *.dart, *.md"``. We split such entries IFF every
       comma-separated piece looks like an extension glob — that way we
       don't shatter a real path that happens to contain a comma.

    2. The user wrote ``*md`` instead of ``*.md``. Auto-insert the dot
       when the entry starts with ``*`` and is otherwise an alphanumeric
       extension token.
    """
    out = []
    for raw in (entries or []):
        if not isinstance(raw, str):
            continue
        s = raw.strip()
        if not s:
            continue
        # Step 1: split if it's "*.a, *.b, *.c"
        if "," in s:
            parts = [p.strip() for p in s.split(",") if p.strip()]
            if parts and all(_looks_like_ext_glob_loose(p) for p in parts):
                for p in parts:
                    out.append(_fix_missing_dot(p))
                continue
        out.append(_fix_missing_dot(s))
    return out


def _fix_missing_dot(entry: str) -> str:
    """``*md`` → ``*.md`` (and similar). Leaves canonical entries alone."""
    if entry.startswith("*") and not entry.startswith("*.") and len(entry) > 1:
        rest = entry[1:]
        if rest and rest[0].isalnum():
            return "*." + rest
    return entry


@dataclass
class PathFilter:
    """User-configurable allow/deny filter with inclusion-wins semantics."""

    base_path: Path
    exclude_dirs: List[str] = field(default_factory=list)
    include_dirs: List[str] = field(default_factory=list)
    exclude_files: List[str] = field(default_factory=list)
    include_files: List[str] = field(default_factory=list)

    @classmethod
    def from_config(
        cls,
        base_path: Path,
        config: Optional[dict],
    ) -> "PathFilter":
        """Build a filter from a JSON-like config dict (or None).

        Tolerates the two common UX mistakes covered by
        :func:`_normalize_user_filter_entries` (comma-glued lists,
        missing-dot ``*md`` typos) so a single bad entry can't render
        every discovery tool empty.
        """
        cfg = config or {}
        return cls(
            base_path=Path(base_path).resolve(),
            exclude_dirs=_normalize_user_filter_entries(cfg.get("exclude_dirs")),
            include_dirs=_normalize_user_filter_entries(cfg.get("include_dirs")),
            exclude_files=_normalize_user_filter_entries(cfg.get("exclude_files")),
            include_files=_normalize_user_filter_entries(cfg.get("include_files")),
        )

    # ------------------------------------------------------------------
    def is_dir_allowed(self, dir_path: Path) -> bool:
        """Return True if a directory should be visible to discovery tools.

        The project root is always allowed in whitelist mode so callers
        like ``list_files('.')`` can iterate it and apply per-child
        filtering. The strict variant used by the file-parent check
        skips this exception.
        """
        return self._decide(dir_path, kind="dir", allow_base_entry=True)

    def is_file_allowed(self, file_path: Path) -> bool:
        """Return True if a file should be visible to discovery tools.

        A file is visible when both:
          - the file's own pattern rules don't deny it, AND
          - the file's parent directory is itself allowed
            (strictly — root-level files in whitelist mode are denied
             unless the project root happens to be in include_dirs).
        Either rule can be overridden by an explicit include.
        """
        if not self._decide(file_path, kind="file", allow_base_entry=False):
            return False
        try:
            parent = file_path.parent
        except (ValueError, OSError):
            return True
        if parent == file_path:
            return True
        return self._decide(parent, kind="dir", allow_base_entry=False)

    # ------------------------------------------------------------------
    def _decide(self, p: Path, *, kind: str, allow_base_entry: bool = True) -> bool:
        if kind == "dir":
            includes = self.include_dirs
            user_excludes = self.exclude_dirs
        else:
            includes = self.include_files
            user_excludes = self.exclude_files

        # Whitelist mode: user has set includes for this kind but no
        # user-level excludes (the hardcoded baseline doesn't count —
        # it's system noise, not user intent). Only listed paths and
        # their descendants survive.
        if includes and not user_excludes:
            # In whitelist mode the base path is allowed only when the
            # caller is using the result for traversal entry (so the
            # walk can iterate root children). When checking whether a
            # *file* sitting at the project root should be visible, the
            # caller passes allow_base_entry=False so the file is
            # correctly hidden alongside the other unlisted siblings.
            if kind == "dir":
                if allow_base_entry and p == self.base_path:
                    return True
                if self._is_ancestor_of_any_include(p, includes):
                    return True
            inc_score = self._score(p, includes, kind)
            # Files in whitelist mode also need a baseline-dir guard:
            # don't accidentally show files inside .git/__pycache__/etc.
            if kind == "file" and inc_score > 0:
                if self._is_under_baseline(p):
                    return False
            return inc_score > 0

        # Blacklist (with overrides) mode. Includes patch holes in the
        # excludes; baseline always enforced for dirs.
        inc_score = self._score(p, includes, kind)
        exc_score = self._score(
            p,
            user_excludes + (list(_BASELINE_EXCLUDE_DIRS) if kind == "dir" else []),
            kind,
        )

        # Default-allow when nothing matches.
        if inc_score == 0 and exc_score == 0:
            return True
        # Inclusion wins on ties (explicit override) and when stricter.
        if inc_score >= exc_score:
            return True
        # Last chance for dirs: D itself doesn't match any include but
        # is on the path to one. Without this, recursive walks can't
        # descend through an excluded ancestor to reach a deeper
        # include — e.g. exclude=installer, include=installer/Out/res
        # would otherwise hide installer/Out/ and the walk never
        # reaches res. Files don't need this — there's no "walk into a
        # file" scenario.
        if kind == "dir" and self._is_ancestor_of_any_include(p, includes):
            return True
        return False

    def _is_ancestor_of_any_include(
        self, dir_path: Path, includes: list,
    ) -> bool:
        """True when dir_path is a parent of any include target.

        Two cases are handled:

          1. Absolute-path includes (e.g. ``C:\\proj\\sub\\target``):
             dir_path is an ancestor when the include path starts with
             ``<dir_path><sep>``.

          2. Multi-segment relative includes (e.g.
             ``installer/Output/resources``): dir_path is an ancestor
             when its normalised path ends with one of the include's
             leading segments (e.g. ``installer`` or
             ``installer/Output``). Bare-name single-segment and
             ``*.ext`` patterns are skipped — those could match
             anywhere, so an ancestor check is meaningless; the score
             logic handles them directly.
        """
        try:
            d_norm = _normalize_abs(str(dir_path.resolve()))
        except (OSError, RuntimeError):
            d_norm = _normalize_abs(str(dir_path))
        for raw in includes:
            entry = (raw or "").strip()
            if not entry:
                continue
            if _is_absolute(entry):
                target = _normalize_abs(entry)
                if target.startswith(d_norm + os.sep):
                    return True
                continue
            # Skip ``*.ext`` file globs — they don't denote a path.
            if _is_ext_glob(entry):
                continue
            segs = entry.replace("\\", "/").strip("/").split("/")
            if len(segs) <= 1:
                # Bare name; could match anywhere, so the score check
                # already covers it.
                continue
            normalized_segs = [
                (s.lower() if os.name == "nt" else s) for s in segs
            ]
            # Test each proper prefix (excluding the full path itself,
            # which would be a direct match — handled by _score).
            for i in range(1, len(normalized_segs)):
                prefix = os.sep.join(normalized_segs[:i])
                if d_norm.endswith(os.sep + prefix) or d_norm == prefix:
                    return True
        return False

    @staticmethod
    def _is_under_baseline(p: Path) -> bool:
        """True when any path component matches a baseline-excluded dir."""
        return any(part in _BASELINE_EXCLUDE_DIRS for part in p.parts)

    @staticmethod
    def _score(p: Path, patterns: Iterable[str], kind: str) -> int:
        """Highest specificity of any pattern in ``patterns`` matching ``p``."""
        best = 0
        try:
            p_abs_norm = _normalize_abs(str(p.resolve()))
        except (OSError, RuntimeError):
            p_abs_norm = _normalize_abs(str(p))
        name = p.name
        suffix = p.suffix.lower()

        for raw in patterns:
            entry = (raw or "").strip()
            if not entry:
                continue

            if _is_absolute(entry):
                target = _normalize_abs(entry)
                # For dirs: match if p is the dir or a descendant.
                # For files: match if p == target.
                if kind == "dir":
                    if p_abs_norm == target or p_abs_norm.startswith(target + os.sep):
                        best = max(best, 3)
                else:
                    if p_abs_norm == target:
                        best = max(best, 3)
                continue

            if kind == "dir":
                # Bare basename: matches any dir with this name anywhere
                # in the tree, AND any descendant of such a dir.
                # ``installer/Output`` written without a drive letter is
                # also accepted as a multi-segment relative match —
                # rare but useful for folder structures pinned to a
                # known relative location.
                segs = entry.replace("\\", "/").strip("/").split("/")
                if len(segs) == 1:
                    target_name = segs[0]
                    if name == target_name:
                        best = max(best, 2)
                    elif target_name in p.parts:
                        best = max(best, 2)
                else:
                    rel_target = os.path.normpath("/".join(segs))
                    if os.name == "nt":
                        rel_target = rel_target.lower()
                    if rel_target and rel_target in p_abs_norm:
                        best = max(best, 2)
            else:  # file
                if _is_ext_glob(entry):
                    target_ext = entry[1:].lower()  # ".exe"
                    if suffix == target_ext:
                        best = max(best, 2)
                else:
                    # Treat a bare name like a basename match (e.g.
                    # 'README' or 'package.json').
                    if name == entry:
                        best = max(best, 2)
        return best

    # ------------------------------------------------------------------
    def summary_for_prompt(self, top: int = 10) -> str:
        """Compact, model-facing summary for the system prompt.

        Lists at most ``top`` entries per bucket so a user with hundreds
        of rules doesn't blow up every call's token count.
        """
        def bucket(name: str, items: Sequence[str]) -> str:
            if not items:
                return f"  {name}: (none)"
            shown = list(items[:top])
            extra = len(items) - len(shown)
            tail = f" (+{extra} more)" if extra > 0 else ""
            return f"  {name}: {', '.join(shown)}{tail}"

        any_active = any((self.exclude_dirs, self.include_dirs,
                          self.exclude_files, self.include_files))
        if not any_active:
            return ""

        dir_whitelist = bool(self.include_dirs) and not bool(self.exclude_dirs)
        file_whitelist = bool(self.include_files) and not bool(self.exclude_files)

        mode_lines = []
        if dir_whitelist:
            mode_lines.append(
                "Directory mode: WHITELIST — only the directories listed "
                "in include_dirs (and their descendants) are visible to "
                "discovery tools. All other directories are hidden."
            )
        if file_whitelist:
            mode_lines.append(
                "File mode: WHITELIST — only files matching include_files "
                "are visible to discovery tools. All other files are "
                "hidden."
            )
        if not dir_whitelist and not file_whitelist:
            mode_lines.append(
                "Mode: BLACKLIST WITH OVERRIDES — entries matching "
                "exclude_* are hidden; entries matching include_* are "
                "explicitly re-shown even if an exclude would normally "
                "hide them. Inclusion always overrides exclusion."
            )
        elif dir_whitelist != file_whitelist:
            mode_lines.append(
                "(The other kind uses BLACKLIST WITH OVERRIDES: "
                "exclude_* hides, include_* re-shows.)"
            )

        lines = [
            "FILESYSTEM FILTERS (active)",
            *mode_lines,
            "read_file / write_file are NOT filtered — you can still "
            "operate on a specific path the user mentions, even one that "
            "would be hidden from discovery.",
            bucket("exclude_dirs", self.exclude_dirs),
            bucket("include_dirs", self.include_dirs),
            bucket("exclude_files", self.exclude_files),
            bucket("include_files", self.include_files),
        ]
        return "\n".join(lines)
