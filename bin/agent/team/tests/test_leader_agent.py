"""Test ``LeaderAgent`` against a scripted fake backend (no model calls)."""

import sys

sys.dont_write_bytecode = True

import json
import shutil
import tempfile
import unittest
from typing import Any, Dict, List, Tuple
from pathlib import Path

from agent.team.board import BoardFile, read_board, write_board
from agent.team.leader import LeaderAgent
from agent.team.paths import TeamPaths
from agent.team.runner import WorkerResult
from agent.team.status import Status


class _ScriptedBackend:
    """Returns canned responses in order. ``model_id`` is required by Agent."""

    model_id = "fake-leader"

    def __init__(self, responses: List[str]):
        self._responses = list(responses)
        self.calls: List[List[Dict[str, Any]]] = []

    def chat(self, *, messages, max_tokens, temperature, tools):
        self.calls.append(list(messages))
        if not self._responses:
            return ("plan done", "stop")
        return (self._responses.pop(0), "stop")


def _wrap_tool(name: str, params: Dict[str, Any]) -> str:
    return f"<tool>{json.dumps({'tool': name, 'parameters': params})}</tool>"


class DecomposeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.paths = TeamPaths.from_base(self.tmp)
        self.paths.ensure_dirs()
        write_board(self.paths.board, BoardFile(session_id="t", leader_model="L"))

    def test_two_groups_with_dependency(self):
        backend = _ScriptedBackend(
            [
                _wrap_tool(
                    "create_group",
                    {
                        "name": "schema",
                        "owner_model": "sonnet-4-6",
                        "plan_steps": ["a", "b", "c"],
                    },
                ),
                _wrap_tool(
                    "create_group",
                    {
                        "name": "repos",
                        "owner_model": "sonnet-4-6",
                        "plan_steps": ["d", "e"],
                        "depends_on": ["schema"],
                    },
                ),
                "plan done",
            ]
        )
        leader = LeaderAgent(backend=backend, paths=self.paths)
        order = leader.decompose("Build a notes feature")
        self.assertEqual(order, ["schema", "repos"])
        bf = read_board(self.paths.board)
        self.assertIsNotNone(bf.find_row("schema"))
        self.assertIsNotNone(bf.find_row("repos"))
        self.assertEqual(dict(bf.dependencies)["repos"], ["schema"])

    def test_invalid_call_results_in_nudge_then_finish(self):
        backend = _ScriptedBackend(
            [
                "I'll plan this work now.",  # no tool call -> nudge
                _wrap_tool(
                    "create_group",
                    {
                        "name": "g",
                        "owner_model": "m",
                        "plan_steps": ["x"],
                    },
                ),
                "plan done",
            ]
        )
        leader = LeaderAgent(backend=backend, paths=self.paths)
        order = leader.decompose("task")
        self.assertEqual(order, ["g"])

    def test_failed_create_group_does_not_get_added_to_order(self):
        backend = _ScriptedBackend(
            [
                _wrap_tool(
                    "create_group",
                    {
                        "name": "g",
                        "owner_model": "m",
                        "plan_steps": ["x"],
                        "depends_on": ["unknown"],  # rejected by tool
                    },
                ),
                _wrap_tool(
                    "create_group",
                    {
                        "name": "g",
                        "owner_model": "m",
                        "plan_steps": ["x"],
                    },
                ),
                "plan done",
            ]
        )
        leader = LeaderAgent(backend=backend, paths=self.paths)
        order = leader.decompose("task")
        self.assertEqual(order, ["g"])  # only the successful one


class ReviewAfterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.paths = TeamPaths.from_base(self.tmp)
        self.paths.ensure_dirs()
        bf = BoardFile(session_id="t", leader_model="L")
        bf.add_group("a", "m", plan=["x"])
        bf.set_status("a", Status.FAILED)
        write_board(self.paths.board, bf)

    def test_clean_run_short_circuits_to_continue(self):
        backend = _ScriptedBackend([])
        leader = LeaderAgent(backend=backend, paths=self.paths)
        # Pretend the run was clean — must not consult the model.
        res = WorkerResult(
            group="a",
            exit_code=0,
            duration_s=0.1,
            timed_out=False,
            final_status=Status.DONE_CLEAN,
        )
        decision = leader.review_after(res)
        self.assertEqual(decision, "continue")
        self.assertEqual(len(backend.calls), 0)

    def test_failure_with_retry_decision_continues(self):
        backend = _ScriptedBackend(
            [
                _wrap_tool(
                    "decide_recovery",
                    {
                        "failed_group": "a",
                        "decision": "retry",
                        "reason": "transient",
                    },
                ),
            ]
        )
        leader = LeaderAgent(backend=backend, paths=self.paths)
        res = WorkerResult(
            group="a",
            exit_code=1,
            duration_s=0.1,
            timed_out=False,
            final_status=Status.FAILED,
        )
        decision = leader.review_after(res)
        self.assertEqual(decision, "continue")
        bf = read_board(self.paths.board)
        self.assertEqual(bf.find_row("a").status, Status.PENDING)

    def test_failure_with_abort_decision_aborts(self):
        backend = _ScriptedBackend(
            [
                _wrap_tool(
                    "decide_recovery",
                    {
                        "failed_group": "a",
                        "decision": "abort",
                        "reason": "fatal",
                    },
                ),
            ]
        )
        leader = LeaderAgent(backend=backend, paths=self.paths)
        res = WorkerResult(
            group="a",
            exit_code=1,
            duration_s=0.1,
            timed_out=False,
            final_status=Status.FAILED,
        )
        decision = leader.review_after(res)
        self.assertEqual(decision, "abort")


class FinalizePhaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.paths = TeamPaths.from_base(self.tmp)
        self.paths.ensure_dirs()
        bf = BoardFile(session_id="t", leader_model="L")
        bf.add_group("a", "m", plan=["x"])
        bf.set_status("a", Status.DONE_CLEAN, last_step="1/1")
        write_board(self.paths.board, bf)

    def test_finalize_summarizes(self):
        backend = _ScriptedBackend([])
        leader = LeaderAgent(backend=backend, paths=self.paths)
        summary = leader.finalize("All groups done.")
        self.assertIn("All groups done", summary)
        self.assertIn("a:", summary)

    def test_finalize_warns_when_nothing_changed(self):
        # All groups DONE_CLEAN but no artifacts have files_touched —
        # the chat reply must shout that nothing actually changed.
        backend = _ScriptedBackend([])
        leader = LeaderAgent(backend=backend, paths=self.paths)
        summary = leader.finalize("Done.")
        self.assertIn("NOTHING WAS CHANGED ON DISK", summary)
        self.assertIn("0 files modified", summary)

    def test_finalize_no_warning_when_files_were_modified(self):
        # Drop a real artifact recording a write.
        from agent.team.artifact import Artifact, write_artifact

        a = Artifact(
            group="a",
            producer_model="m",
            status=Status.DONE_CLEAN,
            summary="ok",
            files_touched=[{"path": "lib/x.dart", "action": "wrote"}],
        )
        write_artifact(self.paths.artifact_path("a"), a)
        backend = _ScriptedBackend([])
        leader = LeaderAgent(backend=backend, paths=self.paths)
        summary = leader.finalize("Done.")
        self.assertNotIn("NOTHING WAS CHANGED", summary)
        self.assertIn("1 file modified", summary)


class LeaderPromptTests(unittest.TestCase):
    """The leader's system prompt must teach concrete plan-step rules
    so models stop generating purely conceptual steps."""

    def test_prompt_lists_concrete_examples(self):
        from agent.team.leader_tools import render_leader_system_prompt

        prompt = render_leader_system_prompt()
        # Concrete tool names appear in the GOOD examples
        self.assertIn("read_file", prompt)
        self.assertIn("flutter_analyze", prompt)
        # Forbidden conceptual verbs are explicitly called out
        self.assertIn("Document hardcoded colors", prompt)
        self.assertIn("Verify accessibility", prompt)
        self.assertIn("Run visual diff tests", prompt)
        # And the rule itself is stated
        self.assertIn("MUST imply at least one of those tools", prompt)


if __name__ == "__main__":
    unittest.main()
