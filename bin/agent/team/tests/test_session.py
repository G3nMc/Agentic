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

_BIN_DIR = Path(__file__).resolve().parents[3]   # bin/
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
    return f'<tool>{json.dumps({"tool": name, "parameters": params})}</tool>'


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
        leader_backend = _ScriptedBackend([
            _wrap("create_group",
                  {"name": "a", "owner_model": "mock", "plan_steps": ["x"]}),
            _wrap("create_group",
                  {"name": "b", "owner_model": "mock", "plan_steps": ["y"],
                   "depends_on": ["a"]}),
            "plan done",
        ])
        leader = LeaderAgent(backend=leader_backend, paths=self.paths)
        session = TeamSession(
            paths=self.paths, leader=leader, base_path=self.tmp,
            timeout_s=30.0, worker_entry=_MOCK_ENTRY,
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
            _wrap("decide_recovery",
                  {"failed_group": "a", "decision": "retry", "reason": "x"})
        ]
        leader_backend = _ScriptedBackend(
            [
                _wrap("create_group",
                      {"name": "a", "owner_model": "mock",
                       "plan_steps": ["x"]}),
                "plan done",
                # review_after rounds — leader keeps asking for retry
                *retry_calls * 5,
            ]
        )
        leader = LeaderAgent(backend=leader_backend, paths=self.paths)
        session = TeamSession(
            paths=self.paths, leader=leader, base_path=self.tmp,
            timeout_s=30.0, worker_entry=_MOCK_ENTRY,
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


class CrashRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.paths = TeamPaths.from_base(self.tmp)
        self.paths.ensure_dirs()

    def test_crash_results_in_interrupted_then_leader_decides_abort(self):
        leader_backend = _ScriptedBackend([
            _wrap("create_group",
                  {"name": "a", "owner_model": "mock",
                   "plan_steps": ["x"]}),
            "plan done",
            _wrap("decide_recovery",
                  {"failed_group": "a", "decision": "abort", "reason": "fatal"}),
        ])
        leader = LeaderAgent(backend=leader_backend, paths=self.paths)
        session = TeamSession(
            paths=self.paths, leader=leader, base_path=self.tmp,
            timeout_s=30.0, worker_entry=_MOCK_ENTRY,
            worker_extra_env=_mock_env("crash"),
        )
        out = session.run("task")
        self.assertEqual(out["status"], "ok")
        self.assertEqual(len(out["results"]), 1)
        self.assertEqual(out["results"][0]["status"], "INTERRUPTED")


if __name__ == "__main__":
    unittest.main()
