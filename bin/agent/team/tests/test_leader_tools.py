import sys
sys.dont_write_bytecode = True

import shutil
import tempfile
import unittest
from pathlib import Path

from agent.team.board import BoardFile, read_board, write_board
from agent.team.leader_tools import (
    LEADER_TOOL_NAMES,
    LeaderTools,
    render_leader_system_prompt,
)
from agent.team.paths import TeamPaths
from agent.team.status import Status


def _seed(paths: TeamPaths) -> None:
    paths.ensure_dirs()
    bf = BoardFile(session_id="t", leader_model="L")
    write_board(paths.board, bf)


class LeaderToolBasicsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.paths = TeamPaths.from_base(self.tmp)
        _seed(self.paths)
        self.tools = LeaderTools(self.paths)

    def test_seven_tools_defined(self):
        expected = {
            "create_group", "assign_dependency", "check_previous",
            "decide_recovery", "mark_done", "compact_board", "finalize",
        }
        self.assertEqual(LEADER_TOOL_NAMES, expected)

    def test_unknown_tool_returns_error(self):
        result = self.tools.execute("nope", {})
        self.assertEqual(result["status"], "error")

    def test_create_group_happy_path(self):
        result = self.tools.execute("create_group", {
            "name": "schema", "owner_model": "sonnet-4-6",
            "plan_steps": ["enumerate", "design"],
        })
        self.assertEqual(result["status"], "success")
        bf = read_board(self.paths.board)
        self.assertIsNotNone(bf.find_row("schema"))
        self.assertEqual(bf.sections["schema"].plan[0].text, "enumerate")

    def test_create_group_rejects_unknown_dep(self):
        result = self.tools.execute("create_group", {
            "name": "g1", "owner_model": "m", "plan_steps": ["x"],
            "depends_on": ["does_not_exist"],
        })
        self.assertEqual(result["status"], "error")

    def test_create_group_duplicate_rejected(self):
        self.tools.execute("create_group", {
            "name": "g", "owner_model": "m", "plan_steps": ["x"],
        })
        result = self.tools.execute("create_group", {
            "name": "g", "owner_model": "m", "plan_steps": ["y"],
        })
        self.assertEqual(result["status"], "error")

    def test_create_group_validates_required_fields(self):
        self.assertEqual(self.tools.execute("create_group", {})["status"], "error")
        self.assertEqual(self.tools.execute(
            "create_group",
            {"name": "g", "owner_model": "", "plan_steps": ["x"]},
        )["status"], "error")
        self.assertEqual(self.tools.execute(
            "create_group",
            {"name": "g", "owner_model": "m", "plan_steps": []},
        )["status"], "error")

    def test_assign_dependency(self):
        self.tools.execute("create_group", {
            "name": "a", "owner_model": "m", "plan_steps": ["x"],
        })
        self.tools.execute("create_group", {
            "name": "b", "owner_model": "m", "plan_steps": ["x"],
        })
        result = self.tools.execute("assign_dependency", {
            "group": "b", "depends_on": ["a"],
        })
        self.assertEqual(result["status"], "success")
        bf = read_board(self.paths.board)
        self.assertEqual(dict(bf.dependencies)["b"], ["a"])

    def test_check_previous_returns_status(self):
        self.tools.execute("create_group", {
            "name": "a", "owner_model": "m", "plan_steps": ["x"],
        })
        self.tools.execute("create_group", {
            "name": "b", "owner_model": "m", "plan_steps": ["x"],
            "depends_on": ["a"],
        })
        # Mark a as DONE_CLEAN
        bf = read_board(self.paths.board)
        bf.set_status("a", Status.DONE_CLEAN, last_step="1/1")
        write_board(self.paths.board, bf)

        result = self.tools.execute("check_previous", {"group": "b"})
        self.assertEqual(result["status"], "success")
        self.assertEqual(len(result["deps"]), 1)
        self.assertEqual(result["deps"][0]["prev_group"], "a")
        self.assertEqual(result["deps"][0]["status"], "DONE_CLEAN")


class RecoveryDecisionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.paths = TeamPaths.from_base(self.tmp)
        _seed(self.paths)
        self.tools = LeaderTools(self.paths)
        self.tools.execute("create_group", {
            "name": "g", "owner_model": "m", "plan_steps": ["x", "y"],
        })

    def _set_failed(self):
        bf = read_board(self.paths.board)
        bf.set_status("g", Status.FAILED, last_step="1/2")
        bf.sections["g"].log.append("oops")
        write_board(self.paths.board, bf)

    def test_decide_retry_resets_to_pending(self):
        self._set_failed()
        result = self.tools.execute("decide_recovery", {
            "failed_group": "g", "decision": "retry", "reason": "transient",
        })
        self.assertEqual(result["status"], "success")
        bf = read_board(self.paths.board)
        self.assertEqual(bf.find_row("g").status, Status.PENDING)
        self.assertEqual(bf.sections["g"].status, Status.PENDING)
        # Retry note appended
        self.assertTrue(any("reset for retry" in ln for ln in bf.sections["g"].log))

    def test_decide_skip_keeps_status(self):
        self._set_failed()
        result = self.tools.execute("decide_recovery", {
            "failed_group": "g", "decision": "skip_with_partial",
            "reason": "non-blocking",
        })
        self.assertEqual(result["status"], "success")
        bf = read_board(self.paths.board)
        self.assertEqual(bf.find_row("g").status, Status.FAILED)
        self.assertTrue(any("skipped after failure" in ln for ln in bf.sections["g"].log))

    def test_decide_abort_leaves_board(self):
        self._set_failed()
        result = self.tools.execute("decide_recovery", {
            "failed_group": "g", "decision": "abort", "reason": "blocker",
        })
        self.assertEqual(result["status"], "success")
        bf = read_board(self.paths.board)
        self.assertEqual(bf.find_row("g").status, Status.FAILED)

    def test_decide_rejects_invalid_decision(self):
        self._set_failed()
        self.assertEqual(self.tools.execute("decide_recovery", {
            "failed_group": "g", "decision": "magic",
        })["status"], "error")

    def test_decide_rejects_non_failed_group(self):
        # Group is still PENDING — recovery shouldn't apply
        self.assertEqual(self.tools.execute("decide_recovery", {
            "failed_group": "g", "decision": "retry",
        })["status"], "error")

    def test_recovery_log_persisted(self):
        self._set_failed()
        self.tools.execute("decide_recovery", {
            "failed_group": "g", "decision": "retry", "reason": "x",
        })
        log = self.paths.recovery_log
        self.assertTrue(log.exists())
        self.assertIn("retry", log.read_text(encoding="utf-8"))


class MarkDoneAndCompactTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.paths = TeamPaths.from_base(self.tmp)
        _seed(self.paths)
        self.tools = LeaderTools(self.paths)

    def test_mark_done_lists_pending(self):
        self.tools.execute("create_group", {
            "name": "a", "owner_model": "m", "plan_steps": ["x"],
        })
        result = self.tools.execute("mark_done", {})
        self.assertFalse(result["ok"])
        self.assertEqual(result["pending"], ["a"])

    def test_mark_done_ok_when_all_terminal(self):
        self.tools.execute("create_group", {
            "name": "a", "owner_model": "m", "plan_steps": ["x"],
        })
        bf = read_board(self.paths.board)
        bf.set_status("a", Status.DONE_CLEAN)
        write_board(self.paths.board, bf)
        result = self.tools.execute("mark_done", {})
        self.assertTrue(result["ok"])

    def test_compact_board_collapses_clean_sections(self):
        self.tools.execute("create_group", {
            "name": "a", "owner_model": "m", "plan_steps": ["x", "y", "z"],
        })
        bf = read_board(self.paths.board)
        bf.set_status("a", Status.DONE_CLEAN, last_step="3/3")
        bf.sections["a"].log = [f"line {i}" for i in range(40)]
        write_board(self.paths.board, bf)
        result = self.tools.execute("compact_board", {})
        self.assertEqual(result["status"], "success")
        self.assertIn("a", result["compacted"])
        bf = read_board(self.paths.board)
        # Compacted section keeps a single rolled-up log line
        self.assertEqual(len(bf.sections["a"].log), 1)
        self.assertTrue(bf.sections["a"].log[0].startswith("compacted:"))


class FinalizeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.paths = TeamPaths.from_base(self.tmp)
        _seed(self.paths)
        self.tools = LeaderTools(self.paths)

    def test_finalize_writes_summary(self):
        result = self.tools.execute("finalize", {"summary": "all good"})
        self.assertEqual(result["status"], "success")
        bf = read_board(self.paths.board)
        self.assertTrue(any("all good" in ln for ln in bf.plan_lines))

    def test_finalize_double_call_errors(self):
        self.tools.execute("finalize", {"summary": "first"})
        result = self.tools.execute("finalize", {"summary": "second"})
        self.assertEqual(result["status"], "error")


class SystemPromptTests(unittest.TestCase):
    def test_system_prompt_lists_all_seven_tools(self):
        prompt = render_leader_system_prompt()
        for name in LEADER_TOOL_NAMES:
            self.assertIn(name, prompt)


if __name__ == "__main__":
    unittest.main()
