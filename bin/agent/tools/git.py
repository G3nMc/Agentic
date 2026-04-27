"""Git tools — status, branches, log, diff, checkout, commit."""
from __future__ import annotations

import json
import subprocess


def register(registry) -> None:
    def _git(args: list, timeout: int = 15) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["git"] + args,
            capture_output=True, text=True,
            timeout=timeout, cwd=str(registry.base_path),
        )

    def git_status() -> str:
        try:
            branch_r = _git(["rev-parse", "--abbrev-ref", "HEAD"])
            branch = branch_r.stdout.strip() if branch_r.returncode == 0 else "unknown"
            status_r = _git(["status", "--short"])
            files = status_r.stdout.strip() if status_r.returncode == 0 else ""
            return json.dumps({
                "status": "success",
                "branch": branch,
                "changes": files if files else "(clean)",
            })
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def git_branches() -> str:
        try:
            r = _git(["branch", "-a", "--format=%(refname:short)"])
            if r.returncode != 0:
                return json.dumps({"status": "error", "message": r.stderr.strip()})
            branches = [b for b in r.stdout.splitlines() if b.strip()]
            current_r = _git(["rev-parse", "--abbrev-ref", "HEAD"])
            current = current_r.stdout.strip() if current_r.returncode == 0 else ""
            return json.dumps({"status": "success", "branches": branches, "current": current})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def git_log(count: int = 10) -> str:
        try:
            r = _git(["log", f"-{count}", "--oneline", "--decorate"])
            if r.returncode != 0:
                return json.dumps({"status": "error", "message": r.stderr.strip()})
            return json.dumps({"status": "success", "log": r.stdout.strip()})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def git_diff(path: str = ".") -> str:
        try:
            target = str(registry._resolve_path(path))
            r = _git(["diff", "HEAD", "--", target])
            if r.returncode != 0:
                return json.dumps({"status": "error", "message": r.stderr.strip()})
            return json.dumps({"status": "success", "diff": r.stdout or "(no changes)"})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def git_checkout(branch: str) -> str:
        try:
            r = _git(["checkout", branch])
            if r.returncode != 0:
                return json.dumps({"status": "error", "message": r.stderr.strip()})
            return json.dumps({"status": "success", "message": f"Switched to branch '{branch}'"})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def git_commit(message: str) -> str:
        """Stage all changes and commit with the given message."""
        try:
            _git(["add", "-A"])
            r = _git(["commit", "-m", message])
            if r.returncode != 0:
                return json.dumps({"status": "error",
                                   "message": r.stderr.strip() or r.stdout.strip()})
            return json.dumps({"status": "success", "message": r.stdout.strip()})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    registry.tools.update({
        "git_status": git_status,
        "git_branches": git_branches,
        "git_log": git_log,
        "git_diff": git_diff,
        "git_checkout": git_checkout,
        "git_commit": git_commit,
    })

    registry.definitions.extend([
        {
            "type": "function",
            "function": {
                "name": "git_status",
                "description": "Show the current git branch and working-tree changes (modified/untracked files).",
                "parameters": {"type": "object", "properties": {}, "required": []},
            },
        },
        {
            "type": "function",
            "function": {
                "name": "git_branches",
                "description": "List all local and remote git branches and indicate which is currently checked out.",
                "parameters": {"type": "object", "properties": {}, "required": []},
            },
        },
        {
            "type": "function",
            "function": {
                "name": "git_log",
                "description": "Show recent git commit history.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "count": {"type": "integer", "description": "Number of commits to show (default 10)"},
                    },
                    "required": [],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "git_diff",
                "description": "Show the git diff for a file or directory relative to HEAD.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "path": {"type": "string", "description": "File or directory path (default '.')"},
                    },
                    "required": [],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "git_checkout",
                "description": "Switch to a different git branch.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "branch": {"type": "string", "description": "Branch name to check out"},
                    },
                    "required": ["branch"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "git_commit",
                "description": "Stage all changes (git add -A) and commit with a message.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "message": {"type": "string", "description": "Commit message"},
                    },
                    "required": ["message"],
                },
            },
        },
    ])
