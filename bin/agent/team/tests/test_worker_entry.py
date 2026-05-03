"""Test ``worker_entry.main`` via in-process invocation with a fake Workflow."""
import sys
sys.dont_write_bytecode = True

import io
import os
import shutil
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Dict, List
from unittest.mock import patch

from agent.team.artifact import Artifact, write_artifact, read_artifact
from agent.team.board import BoardFile, read_board, write_board
from agent.team.paths import TeamPaths
from agent.team.status import Status
from agent.team import worker_entry


class _FakeWorkflow:
    def __init__(self, response: str = "All steps complete.",
                 tool_calls: List[Dict[str, Any]] | None = None):
        self._response = response
        self._tool_calls = tool_calls or []
        self.calls: List[str] = []

    def run(self, prompt: str) -> Dict[str, Any]:
        self.calls.append(prompt)
        return {"response": self._response, "trace": [],
                "route": "reasoning",
                "tool_calls": list(self._tool_calls)}


@contextmanager
def _argv(*args: str):
    old = sys.argv
    sys.argv = list(args)
    try:
        yield
    finally:
        sys.argv = old


@contextmanager
def _envs(**kwargs):
    snapshot = {k: os.environ.get(k) for k in kwargs}
    for k, v in kwargs.items():
        os.environ[k] = v
    try:
        yield
    finally:
        for k, v in snapshot.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def _seed_board(paths: TeamPaths, group: str, plan: List[str]):
    paths.ensure_dirs()
    bf = BoardFile(session_id="t", leader_model="L")
    bf.add_group(group, "test-model", plan=plan)
    write_board(paths.board, bf)


class WorkerEntryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.paths = TeamPaths.from_base(self.tmp)
        # Minimal agent-config to satisfy build_workflow_from_args path —
        # but we'll patch the builder anyway.
        self.cfg = Path(self.tmp) / "agents.json"
        self.cfg.write_text('{"reasoner": {"backend": "gemini",'
                            ' "model": "gemini-2.5-flash"}}',
                            encoding="utf-8")

    def _run_worker(self, *, group: str, response: str,
                    deps_csv: str = "",
                    tool_calls: List[Dict[str, Any]] | None = None) -> int:
        fake = _FakeWorkflow(response=response, tool_calls=tool_calls)
        with _argv("worker_entry.py", "--group", group,
                   "--multi-agent", "--agent-config", str(self.cfg),
                   "--base-path", self.tmp), \
             _envs(TEAM_BOARD_PATH=str(self.paths.board),
                   TEAM_ARTIFACT_DIR=str(self.paths.artifacts_dir),
                   TEAM_GROUP=group, TEAM_OWNER_MODEL="test-model",
                   TEAM_DEPS=deps_csv, TEAM_BASE_PATH=self.tmp), \
             patch("agent.team.worker_entry.build_workflow_from_args",
                   return_value=fake):
            return worker_entry.main()

    def test_clean_run_writes_artifact_and_stamps_done(self):
        _seed_board(self.paths, "alpha", plan=["one", "two"])
        rc = self._run_worker(
            group="alpha",
            response="Wrote two files. All steps done.",
            tool_calls=[
                {"tool": "write_file", "path": "lib/a.dart", "status": "success"},
                {"tool": "write_file", "path": "lib/b.dart", "status": "success"},
            ],
        )
        self.assertEqual(rc, 0)
        bf = read_board(self.paths.board)
        self.assertEqual(bf.find_row("alpha").status, Status.DONE_CLEAN)
        self.assertTrue(self.paths.artifact_path("alpha").exists())
        artifact = read_artifact(self.paths.artifact_path("alpha"))
        self.assertEqual(artifact.group, "alpha")
        self.assertEqual(artifact.status, Status.DONE_CLEAN)
        self.assertIn("Wrote two files", artifact.summary)
        # files_touched is now populated from tool_calls (real source)
        self.assertEqual(len(artifact.files_touched), 2)
        self.assertEqual(artifact.files_touched[0]["path"], "lib/a.dart")
        self.assertEqual(artifact.files_touched[0]["action"], "wrote")

    def test_prose_only_run_marks_done_with_warnings(self):
        _seed_board(self.paths, "alpha", plan=["one"])
        rc = self._run_worker(
            group="alpha",
            response="I have analyzed everything thoroughly.",
            tool_calls=[],  # the smoking gun — zero tools used
        )
        self.assertEqual(rc, 0)
        bf = read_board(self.paths.board)
        self.assertEqual(bf.find_row("alpha").status, Status.DONE_WITH_WARNINGS)
        artifact = read_artifact(self.paths.artifact_path("alpha"))
        self.assertEqual(artifact.status, Status.DONE_WITH_WARNINGS)
        self.assertEqual(artifact.files_touched, [])
        self.assertTrue(any("prose only" in w.lower() for w in artifact.warnings))

    def test_error_response_stamps_failed_and_exits_1(self):
        _seed_board(self.paths, "alpha", plan=["one"])
        rc = self._run_worker(
            group="alpha",
            response="ERROR: Repeated failing tool calls. Last error: foo",
        )
        self.assertEqual(rc, 1)
        bf = read_board(self.paths.board)
        self.assertEqual(bf.find_row("alpha").status, Status.FAILED)

    def test_dep_artifacts_get_loaded_into_prompt(self):
        _seed_board(self.paths, "beta", plan=["one"])
        # Pre-write an upstream artifact for "alpha"
        upstream = Artifact(
            group="alpha", producer_model="x",
            status=Status.DONE_CLEAN,
            summary="schema designed",
            interfaces_exposed=[{"name": "users.id", "type": "uuid"}],
        )
        self.paths.ensure_dirs()
        write_artifact(self.paths.artifact_path("alpha"), upstream)

        captured: Dict[str, str] = {}

        class _CaptureWf:
            def run(self, prompt: str):
                captured["prompt"] = prompt
                return {"response": "done", "trace": [], "route": "reasoning"}

        with _argv("worker_entry.py", "--group", "beta",
                   "--multi-agent", "--agent-config", str(self.cfg),
                   "--base-path", self.tmp), \
             _envs(TEAM_BOARD_PATH=str(self.paths.board),
                   TEAM_ARTIFACT_DIR=str(self.paths.artifacts_dir),
                   TEAM_GROUP="beta", TEAM_OWNER_MODEL="m",
                   TEAM_DEPS="alpha", TEAM_BASE_PATH=self.tmp), \
             patch("agent.team.worker_entry.build_workflow_from_args",
                   return_value=_CaptureWf()):
            rc = worker_entry.main()
        self.assertEqual(rc, 0)
        self.assertIn("Upstream artifact: alpha", captured["prompt"])
        self.assertIn("schema designed", captured["prompt"])
        self.assertIn("users.id: uuid", captured["prompt"])

    def test_workflow_crash_stamps_failed(self):
        _seed_board(self.paths, "alpha", plan=["one"])

        class _BoomWf:
            def run(self, prompt: str):
                raise RuntimeError("boom")

        with _argv("worker_entry.py", "--group", "alpha",
                   "--multi-agent", "--agent-config", str(self.cfg),
                   "--base-path", self.tmp), \
             _envs(TEAM_BOARD_PATH=str(self.paths.board),
                   TEAM_ARTIFACT_DIR=str(self.paths.artifacts_dir),
                   TEAM_GROUP="alpha", TEAM_OWNER_MODEL="m",
                   TEAM_DEPS="", TEAM_BASE_PATH=self.tmp), \
             patch("agent.team.worker_entry.build_workflow_from_args",
                   return_value=_BoomWf()):
            rc = worker_entry.main()
        self.assertEqual(rc, 1)
        bf = read_board(self.paths.board)
        self.assertEqual(bf.find_row("alpha").status, Status.FAILED)


class ClassifierTests(unittest.TestCase):
    """Worker status must reflect actual tool usage, not just whether
    the response started with ERROR."""

    def test_no_tools_called_yields_done_with_warnings(self):
        from agent.team.worker_entry import _classify_response
        st = _classify_response("I have analyzed the colors.", [])
        self.assertEqual(st, Status.DONE_WITH_WARNINGS)

    def test_error_response_overrides_tool_usage(self):
        from agent.team.worker_entry import _classify_response
        st = _classify_response(
            "ERROR: Empty model response",
            [{"tool": "write_file", "path": "x.dart", "status": "success"}],
        )
        self.assertEqual(st, Status.FAILED)

    def test_state_changing_call_yields_done_clean(self):
        from agent.team.worker_entry import _classify_response
        st = _classify_response(
            "Updated the bubble colors.",
            [{"tool": "write_file", "path": "lib/x.dart", "status": "success"}],
        )
        self.assertEqual(st, Status.DONE_CLEAN)

    def test_read_only_tools_count_as_engagement(self):
        # An audit group that only reads files still engaged with the
        # codebase — DONE_CLEAN is appropriate.
        from agent.team.worker_entry import _classify_response
        st = _classify_response(
            "I read the relevant files.",
            [{"tool": "read_file", "path": "x", "status": "success"},
             {"tool": "search_in_files", "path": "", "status": "success"}],
        )
        self.assertEqual(st, Status.DONE_CLEAN)

    def test_files_touched_extracted_only_from_state_changing_calls(self):
        from agent.team.worker_entry import _files_touched_from_tool_calls
        out = _files_touched_from_tool_calls([
            {"tool": "read_file", "path": "a", "status": "success"},
            {"tool": "write_file", "path": "b.dart", "status": "success"},
            {"tool": "patch_file", "path": "c.py", "status": "success"},
            {"tool": "write_file", "path": "d.txt", "status": "error"},  # failed
        ])
        actions = [(e["path"], e["action"]) for e in out]
        self.assertEqual(actions, [("b.dart", "wrote"), ("c.py", "patched")])


class FailedArtifactOnEarlyErrorTests(unittest.TestCase):
    """Workers must leave a FAILED artifact behind even when they die
    before the normal artifact-write step. Otherwise the host has no
    visibility into the cause."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.paths = TeamPaths.from_base(self.tmp)
        self.cfg = Path(self.tmp) / "agents.json"
        self.cfg.write_text(
            '{"reasoner": {"backend": "gemini", "model": "gemini-2.5-flash"}}',
            encoding="utf-8",
        )

    def test_workflow_build_failure_writes_failed_artifact(self):
        _seed_board(self.paths, "alpha", plan=["x"])

        def _boom(*a, **kw):
            raise RuntimeError("missing API key — Gemini auth failed")

        with _argv("worker_entry.py", "--group", "alpha",
                   "--multi-agent", "--agent-config", str(self.cfg),
                   "--base-path", self.tmp), \
             _envs(TEAM_BOARD_PATH=str(self.paths.board),
                   TEAM_ARTIFACT_DIR=str(self.paths.artifacts_dir),
                   TEAM_GROUP="alpha", TEAM_OWNER_MODEL="m",
                   TEAM_DEPS="", TEAM_BASE_PATH=self.tmp), \
             patch("agent.team.worker_entry.build_workflow_from_args",
                   side_effect=_boom):
            rc = worker_entry.main()
        self.assertEqual(rc, 1)
        # The artifact MUST exist with the failure reason embedded.
        ap = self.paths.artifact_path("alpha")
        self.assertTrue(ap.exists(),
                        "Worker must write a FAILED artifact even on early errors")
        artifact = read_artifact(ap)
        self.assertEqual(artifact.status, Status.FAILED)
        self.assertIn("missing API key", artifact.summary)

    def test_workflow_run_crash_writes_failed_artifact(self):
        _seed_board(self.paths, "alpha", plan=["x"])

        class _BoomWf:
            def run(self, prompt: str):
                raise RuntimeError("provider returned 429")

        with _argv("worker_entry.py", "--group", "alpha",
                   "--multi-agent", "--agent-config", str(self.cfg),
                   "--base-path", self.tmp), \
             _envs(TEAM_BOARD_PATH=str(self.paths.board),
                   TEAM_ARTIFACT_DIR=str(self.paths.artifacts_dir),
                   TEAM_GROUP="alpha", TEAM_OWNER_MODEL="m",
                   TEAM_DEPS="", TEAM_BASE_PATH=self.tmp), \
             patch("agent.team.worker_entry.build_workflow_from_args",
                   return_value=_BoomWf()):
            rc = worker_entry.main()
        self.assertEqual(rc, 1)
        artifact = read_artifact(self.paths.artifact_path("alpha"))
        self.assertEqual(artifact.status, Status.FAILED)
        self.assertIn("429", artifact.summary)


if __name__ == "__main__":
    unittest.main()
