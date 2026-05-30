"""End-to-end TeamSession tests using the mock worker."""

import sys

sys.dont_write_bytecode = True

import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from typing import Any, Dict, List

from agent.team.board import BoardFile, read_board, write_board
from agent.team.leader import LeaderAgent
from agent.team.paths import TeamPaths
from agent.team.session import TeamSession
from agent.team.status import Status

_BIN_DIR = Path(__file__).resolve().parents[3]  # bin/
_MOCK_ENTRY = "agent.team.tests._mock_worker"


class _ScriptedBackend:
    model_id = "fake"

    def __init__(self, responses: List[str]):
        self._responses = list(responses)

    def chat(self, *, messages, max_tokens, temperature, tools):
        if not self._responses:
            return ("plan done", "stop")
        return (self._responses.pop(0), "stop")


def _wrap(name: str, params: Dict[str, Any]) -> str:
    return f"<tool>{json.dumps({'tool': name, 'parameters': params})}</tool>"


def _mock_env(behavior: str) -> Dict[str, str]:
    return {
        "MOCK_BEHAVIOR": behavior,
        "PYTHONPATH": str(_BIN_DIR) + os.pathsep + os.environ.get("PYTHONPATH", ""),
    }


class HappyPathSessionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.paths = TeamPaths.from_base(self.tmp)
        self.paths.ensure_dirs()

    def test_two_clean_groups_finish(self):
        leader_backend = _ScriptedBackend(
            [
                _wrap(
                    "create_group",
                    {"name": "a", "owner_model": "mock", "plan_steps": ["x"]},
                ),
                _wrap(
                    "create_group",
                    {
                        "name": "b",
                        "owner_model": "mock",
                        "plan_steps": ["y"],
                        "depends_on": ["a"],
                    },
                ),
                "plan done",
            ]
        )
        leader = LeaderAgent(backend=leader_backend, paths=self.paths)
        session = TeamSession(
            paths=self.paths,
            leader=leader,
            base_path=self.tmp,
            timeout_s=30.0,
            worker_entry=_MOCK_ENTRY,
            worker_extra_env=_mock_env("clean"),
        )
        out = session.run("Build a thing")
        self.assertEqual(out["status"], "ok")
        statuses = [r["status"] for r in out["results"]]
        self.assertEqual(statuses, ["DONE_CLEAN", "DONE_CLEAN"])
        bf = read_board(self.paths.board)
        for r in bf.status_rows:
            self.assertEqual(r.status, Status.DONE_CLEAN)


class RetryAndSkipTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.paths = TeamPaths.from_base(self.tmp)
        self.paths.ensure_dirs()

    def test_retry_cap_forces_skip(self):
        # Leader: plans 1 group; on every failure, asks for retry.
        # The session's MAX_RETRIES cap should eventually skip it.
        retry_calls = [
            _wrap(
                "decide_recovery",
                {"failed_group": "a", "decision": "retry", "reason": "x"},
            )
        ]
        leader_backend = _ScriptedBackend(
            [
                _wrap(
                    "create_group",
                    {"name": "a", "owner_model": "mock", "plan_steps": ["x"]},
                ),
                "plan done",
                # review_after rounds — leader keeps asking for retry
                *retry_calls * 5,
            ]
        )
        leader = LeaderAgent(backend=leader_backend, paths=self.paths)
        session = TeamSession(
            paths=self.paths,
            leader=leader,
            base_path=self.tmp,
            timeout_s=30.0,
            worker_entry=_MOCK_ENTRY,
            worker_extra_env=_mock_env("fail"),
            max_retries=2,
        )
        out = session.run("task")
        # 1 original + 2 retries = 3 results
        self.assertEqual(out["status"], "ok")
        self.assertEqual(len(out["results"]), 3)
        # All should be FAILED
        for r in out["results"]:
            self.assertEqual(r["status"], "FAILED")
        # Check at least one decision was 'skip_with_partial' (the cap)
        decisions = leader.tools.recovery_decisions()
        decision_kinds = [d.decision for d in decisions]
        self.assertIn("skip_with_partial", decision_kinds)


class PreFlightAbortTests(unittest.TestCase):
    """The board must be reset before each session AND the runner must
    refuse to start when the leader fails to produce any groups."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.paths = TeamPaths.from_base(self.tmp)
        self.paths.ensure_dirs()

    def test_previous_session_content_is_wiped_at_start(self):
        # Seed the board with stale content from a "prior session".
        from agent.team.board import BoardFile, write_board
        from agent.team.status import Status

        stale = BoardFile(session_id="OLD", leader_model="OLD")
        stale.add_group("legacy", "old-model", plan=["leftover step"])
        stale.set_status("legacy", Status.DONE_CLEAN, last_step="1/1")
        write_board(self.paths.board, stale)

        # Leader produces ONE clean group for the new session.
        leader_backend = _ScriptedBackend(
            [
                _wrap(
                    "create_group",
                    {"name": "fresh", "owner_model": "mock", "plan_steps": ["x"]},
                ),
                "plan done",
            ]
        )
        leader = LeaderAgent(backend=leader_backend, paths=self.paths)
        session = TeamSession(
            paths=self.paths,
            leader=leader,
            base_path=self.tmp,
            timeout_s=30.0,
            worker_entry=_MOCK_ENTRY,
            worker_extra_env=_mock_env("clean"),
        )
        out = session.run("a fresh task")
        self.assertEqual(out["status"], "ok")

        from agent.team.board import read_board

        bf = read_board(self.paths.board)
        # The stale group must be gone; only the new group remains.
        groups = [r.group for r in bf.status_rows]
        self.assertNotIn("legacy", groups)
        self.assertEqual(groups, ["fresh"])
        self.assertNotEqual(bf.session_id, "OLD")

    def test_leader_produces_no_groups_aborts_without_workers(self):
        # Leader replies 'plan done' without calling create_group at all.
        leader_backend = _ScriptedBackend(["plan done"])
        leader = LeaderAgent(backend=leader_backend, paths=self.paths)
        session = TeamSession(
            paths=self.paths,
            leader=leader,
            base_path=self.tmp,
            timeout_s=30.0,
            worker_entry=_MOCK_ENTRY,
            worker_extra_env=_mock_env("clean"),
        )
        out = session.run("vague task")
        self.assertEqual(out["status"], "error")
        self.assertIn("no groups", out["message"])
        # No worker artifacts written — chain didn't start.
        self.assertEqual(list(self.paths.artifacts_dir.glob("*.json")), [])

    def test_leader_decompose_crash_aborts_cleanly(self):
        class _BoomBackend:
            model_id = "fake"

            def chat(self, *, messages, max_tokens, temperature, tools):
                raise RuntimeError("provider down")

        leader = LeaderAgent(backend=_BoomBackend(), paths=self.paths)
        session = TeamSession(
            paths=self.paths,
            leader=leader,
            base_path=self.tmp,
            timeout_s=30.0,
            worker_entry=_MOCK_ENTRY,
            worker_extra_env=_mock_env("clean"),
        )
        out = session.run("any task")
        self.assertEqual(out["status"], "error")
        self.assertIn("leader reasoning failed", out["message"])
        self.assertEqual(list(self.paths.artifacts_dir.glob("*.json")), [])


class SessionIsolationTests(unittest.TestCase):
    """Two conversations running Team Mode must not clobber each other."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_two_conversations_get_independent_subfolders(self):
        # Build two TeamSessions with different session_ids, run a clean
        # group in each, verify they each have their own board + artifact
        # and don't see each other's content.
        from agent.team.paths import TeamPaths

        guid_a = "69790e60-06fa-4c14-9729-39f7ba49c5e2"
        guid_b = "c0ffee00-1234-5678-90ab-cdef00ba5e11"
        for guid in (guid_a, guid_b):
            paths = TeamPaths.for_session(self.tmp, guid)
            paths.ensure_dirs()
            backend = _ScriptedBackend(
                [
                    _wrap(
                        "create_group",
                        {"name": guid[:6], "owner_model": "mock", "plan_steps": ["x"]},
                    ),
                    "plan done",
                ]
            )
            leader = LeaderAgent(backend=backend, paths=paths)
            session = TeamSession(
                paths=paths,
                leader=leader,
                base_path=self.tmp,
                timeout_s=30.0,
                worker_entry=_MOCK_ENTRY,
                worker_extra_env=_mock_env("clean"),
            )
            out = session.run(f"task for {guid}")
            self.assertEqual(out["status"], "ok")

        # Both folders exist and contain only their own group.
        from agent.team.board import read_board

        for guid in (guid_a, guid_b):
            paths = TeamPaths.for_session(self.tmp, guid)
            self.assertTrue(paths.board.exists())
            bf = read_board(paths.board)
            self.assertEqual([r.group for r in bf.status_rows], [guid[:6]])
            self.assertTrue(paths.artifact_path(guid[:6]).exists())

        # And: deleting one session leaves the other intact.
        from agent.team.paths import delete_session

        self.assertTrue(delete_session(self.tmp, guid_a))
        self.assertFalse(TeamPaths.for_session(self.tmp, guid_a).board.exists())
        self.assertTrue(TeamPaths.for_session(self.tmp, guid_b).board.exists())


class CrashRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.paths = TeamPaths.from_base(self.tmp)
        self.paths.ensure_dirs()

    def test_crash_results_in_interrupted_then_leader_decides_abort(self):
        leader_backend = _ScriptedBackend(
            [
                _wrap(
                    "create_group",
                    {"name": "a", "owner_model": "mock", "plan_steps": ["x"]},
                ),
                "plan done",
                _wrap(
                    "decide_recovery",
                    {"failed_group": "a", "decision": "abort", "reason": "fatal"},
                ),
            ]
        )
        leader = LeaderAgent(backend=leader_backend, paths=self.paths)
        session = TeamSession(
            paths=self.paths,
            leader=leader,
            base_path=self.tmp,
            timeout_s=30.0,
            worker_entry=_MOCK_ENTRY,
            worker_extra_env=_mock_env("crash"),
        )
        out = session.run("task")
        self.assertEqual(out["status"], "ok")
        self.assertEqual(len(out["results"]), 1)
        self.assertEqual(out["results"][0]["status"], "INTERRUPTED")


if __name__ == "__main__":
    unittest.main()
