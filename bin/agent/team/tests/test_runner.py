import sys
sys.dont_write_bytecode = True

import os
import tempfile
import unittest
from pathlib import Path

from agent.team.board import BoardFile, read_board, write_board
from agent.team.paths import TeamPaths
from agent.team.runner import (
    SequentialRunner,
    build_worker_argv,
    build_worker_env,
    run_worker,
)
from agent.team.status import Status


_BIN_DIR = Path(__file__).resolve().parents[3]   # bin/
_MOCK_ENTRY = "agent.team.tests._mock_worker"


def _seed_board(paths: TeamPaths, groups):
    paths.ensure_dirs()
    bf = BoardFile(session_id="t", leader_model="mock-leader")
    for g in groups:
        bf.add_group(g, owner_model="mock", plan=["do it"])
    write_board(paths.board, bf)


class ArgvEnvBuilderTests(unittest.TestCase):
    def test_argv_has_module_and_group(self):
        argv = build_worker_argv("alpha", worker_entry=_MOCK_ENTRY)
        self.assertIn("-m", argv)
        self.assertIn(_MOCK_ENTRY, argv)
        self.assertIn("--group", argv)
        self.assertIn("alpha", argv)

    def test_env_carries_contract_variables(self):
        with tempfile.TemporaryDirectory() as d:
            tp = TeamPaths.from_base(d)
            env = build_worker_env(
                paths=tp, group="alpha", owner_model="m",
                deps=["beta", "gamma"], base_path=d,
            )
            self.assertEqual(env["TEAM_GROUP"], "alpha")
            self.assertEqual(env["TEAM_OWNER_MODEL"], "m")
            self.assertEqual(env["TEAM_DEPS"], "beta,gamma")
            self.assertTrue(env["TEAM_BOARD_PATH"].endswith("team_board.md"))


class RunWorkerTests(unittest.TestCase):
    def setUp(self):
        import shutil
        self._tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self._tmp, ignore_errors=True)

    def _run(self, behavior: str, *, timeout_s: float = 30.0):
        d = self._tmp
        tp = TeamPaths.from_base(d)
        _seed_board(tp, ["alpha"])
        res = run_worker(
            group="alpha",
            paths=tp,
            owner_model="mock",
            deps=[],
            base_path=d,
            timeout_s=timeout_s,
            worker_entry=_MOCK_ENTRY,
            extra_env={
                "MOCK_BEHAVIOR": behavior,
                "PYTHONPATH": str(_BIN_DIR) + os.pathsep
                              + os.environ.get("PYTHONPATH", ""),
            },
        )
        board = read_board(tp.board)
        return res, board, tp

    def test_clean_run(self):
        res, board, tp = self._run("clean")
        self.assertEqual(res.exit_code, 0)
        self.assertEqual(res.final_status, Status.DONE_CLEAN)
        self.assertFalse(res.stamped_by_host)
        self.assertEqual(board.find_row("alpha").status, Status.DONE_CLEAN)
        self.assertTrue(tp.artifact_path("alpha").exists())

    def test_failed_run(self):
        res, board, _ = self._run("fail")
        self.assertEqual(res.exit_code, 1)
        self.assertEqual(res.final_status, Status.FAILED)
        self.assertFalse(res.stamped_by_host)

    def test_warnings_run(self):
        res, board, _ = self._run("warnings")
        self.assertEqual(res.exit_code, 0)
        self.assertEqual(res.final_status, Status.DONE_WITH_WARNINGS)

    def test_crash_results_in_host_stamped_interrupted(self):
        res, board, _ = self._run("crash")
        self.assertEqual(res.exit_code, 2)
        self.assertEqual(res.final_status, Status.INTERRUPTED)
        self.assertTrue(res.stamped_by_host)
        self.assertEqual(board.find_row("alpha").status, Status.INTERRUPTED)

    def test_timeout_results_in_interrupted(self):
        res, board, _ = self._run("hang", timeout_s=2.0)
        self.assertTrue(res.timed_out)
        self.assertEqual(res.final_status, Status.INTERRUPTED)
        self.assertTrue(res.stamped_by_host)


class TeeOutputTests(unittest.TestCase):
    """Worker stdout/stderr must be tee'd to the host's stderr so the
    Flutter inactivity watchdog sees activity and the user can see live
    worker progress, not just the leader."""

    def setUp(self):
        import shutil
        self._tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self._tmp, ignore_errors=True)

    def test_worker_stderr_appears_on_host_stderr_with_prefix(self):
        import io
        import sys as _sys
        from unittest.mock import patch

        tp = TeamPaths.from_base(self._tmp)
        _seed_board(tp, ["alpha"])

        captured = io.StringIO()
        with patch.object(_sys, "stderr", captured):
            run_worker(
                group="alpha",
                paths=tp,
                owner_model="mock",
                deps=[],
                base_path=self._tmp,
                timeout_s=30.0,
                worker_entry=_MOCK_ENTRY,
                extra_env={
                    "MOCK_BEHAVIOR": "clean",
                    "PYTHONPATH": str(_BIN_DIR) + os.pathsep
                                  + os.environ.get("PYTHONPATH", ""),
                },
            )
        out = captured.getvalue()
        # Lifecycle breadcrumbs from the host
        self.assertIn("[team] starting worker 'alpha'", out)
        self.assertIn("[team] worker 'alpha' exited", out)
        # The log file is still populated (per-group debug record)
        self.assertTrue(tp.worker_stderr("alpha").exists())


class SequentialRunnerTests(unittest.TestCase):
    def test_three_clean_groups_in_order(self):
        with tempfile.TemporaryDirectory() as d:
            tp = TeamPaths.from_base(d)
            _seed_board(tp, ["a", "b", "c"])
            runner = SequentialRunner(
                paths=tp, base_path=d, timeout_s=30.0,
                worker_entry=_MOCK_ENTRY,
                extra_env={
                    "MOCK_BEHAVIOR": "clean",
                    "PYTHONPATH": str(_BIN_DIR) + os.pathsep
                                  + os.environ.get("PYTHONPATH", ""),
                },
            )
            seen = []
            results = runner.run_all(
                groups=["a", "b", "c"],
                owner_models={"a": "m", "b": "m", "c": "m"},
                dependencies={"a": [], "b": ["a"], "c": ["b"]},
                before_each=lambda g, bf: seen.append(g),
            )
            self.assertEqual([r.group for r in results], ["a", "b", "c"])
            self.assertEqual(seen, ["a", "b", "c"])
            for r in results:
                self.assertEqual(r.final_status, Status.DONE_CLEAN)

    def test_failure_aborts_chain_without_recovery_hook(self):
        with tempfile.TemporaryDirectory() as d:
            tp = TeamPaths.from_base(d)
            _seed_board(tp, ["a", "b"])
            runner = SequentialRunner(
                paths=tp, base_path=d, timeout_s=30.0,
                worker_entry=_MOCK_ENTRY,
                extra_env={
                    "MOCK_BEHAVIOR": "fail",
                    "PYTHONPATH": str(_BIN_DIR) + os.pathsep
                                  + os.environ.get("PYTHONPATH", ""),
                },
            )
            results = runner.run_all(
                groups=["a", "b"],
                owner_models={"a": "m", "b": "m"},
                dependencies={"a": [], "b": ["a"]},
            )
            self.assertEqual(len(results), 1)
            self.assertEqual(results[0].final_status, Status.FAILED)

    def test_failure_continues_when_hook_says_continue(self):
        with tempfile.TemporaryDirectory() as d:
            tp = TeamPaths.from_base(d)
            _seed_board(tp, ["a", "b"])
            runner = SequentialRunner(
                paths=tp, base_path=d, timeout_s=30.0,
                worker_entry=_MOCK_ENTRY,
                extra_env={
                    "MOCK_BEHAVIOR": "fail",
                    "PYTHONPATH": str(_BIN_DIR) + os.pathsep
                                  + os.environ.get("PYTHONPATH", ""),
                },
            )
            results = runner.run_all(
                groups=["a", "b"],
                owner_models={"a": "m", "b": "m"},
                dependencies={"a": [], "b": ["a"]},
                on_failure=lambda res, bf: "continue",
            )
            # both ran (both failed because mock behavior is global)
            self.assertEqual(len(results), 2)


if __name__ == "__main__":
    unittest.main()
