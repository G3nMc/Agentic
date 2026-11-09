"""The `{"action": "shutdown"}` control line must end the session cleanly.

The Flutter side writes this line before falling back to `kill()`, so the
process has a bounded window to flush the audit log and the per-chat log file.
A regression here means every stop becomes a SIGKILL and the last turn's log is
lost — the exact racy behaviour the graceful path exists to avoid.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
ORCHESTRATOR = REPO_ROOT / "bin" / "orchestrator.py"

# Generous but still well inside the 3 s window the Dart side allows before it
# escalates to `Process.kill()`.
STARTUP_TIMEOUT = 3.0
SHUTDOWN_TIMEOUT = 3.0


pytestmark = pytest.mark.skipif(
    not ORCHESTRATOR.exists(),
    reason="bin/orchestrator.py not present",
)


def _spawn_interactive(tmp_path: Path) -> subprocess.Popen:
    """Start the interactive loop with pipes, without real provider keys.

    `--base-path` is redirected to a throwaway directory so the audit log and
    chat log land in the test sandbox instead of the repository.

    A dummy `--hf-token` is passed because the CLI preflight only checks that
    the flag is *present* for `--backend=huggingface`; the backend object is
    built lazily and no network call happens before the `__READY__` handshake.
    Without it the process exits before the read loop even starts, which would
    make this test measure the preflight instead of the shutdown path.
    """
    return subprocess.Popen(
        [
            sys.executable,
            str(ORCHESTRATOR),
            "--interactive",
            "--base-path",
            str(tmp_path),
            "--hf-token",
            "dummy-token-for-shutdown-test",
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        cwd=str(REPO_ROOT),
    )


def _wait_ready(proc: subprocess.Popen) -> bool:
    """Consume stdout until the `__READY__` handshake (or the process dies)."""
    assert proc.stdout is not None
    for line in proc.stdout:
        if line.strip() == "__READY__":
            return True
    return False


def test_shutdown_line_exits_zero_within_the_grace_window(tmp_path):
    proc = _spawn_interactive(tmp_path)
    try:
        ready = _wait_ready(proc)
        assert ready, (
            "orchestrator never signalled __READY__; "
            f"stderr: {proc.stderr.read() if proc.stderr else ''}"
        )

        assert proc.stdin is not None
        proc.stdin.write(json.dumps({"action": "shutdown"}) + "\n")
        proc.stdin.flush()

        exit_code = proc.wait(timeout=SHUTDOWN_TIMEOUT)
        assert exit_code == 0, (
            "shutdown control line must leave the read loop cleanly; "
            f"got exit code {exit_code}"
        )
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=STARTUP_TIMEOUT)


def test_eof_still_terminates_the_loop(tmp_path):
    """Closing stdin keeps working — the shutdown line must not replace it."""
    proc = _spawn_interactive(tmp_path)
    try:
        assert _wait_ready(proc), "orchestrator never signalled __READY__"
        assert proc.stdin is not None
        proc.stdin.close()

        exit_code = proc.wait(timeout=SHUTDOWN_TIMEOUT)
        assert exit_code == 0
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=STARTUP_TIMEOUT)