import sys

sys.dont_write_bytecode = True

import tempfile
import unittest
from pathlib import Path

from agent.team.board import (
    BoardFile,
    BoardSection,
    PlanStep,
    StatusRow,
    read_board,
    slice_section,
    slice_status_table,
    write_board,
)
from agent.team.status import Status


def _sample_board() -> BoardFile:
    bf = BoardFile(
        session_id="2026-05-01T14:32:11Z-test",
        leader_model="opus-4-7",
    )
    bf.add_group(
        "schema",
        "sonnet-4-6",
        plan=["enumerate", "design", "migrate", "validate", "emit"],
    )
    bf.add_group(
        "repos",
        "sonnet-4-6",
        plan=["read schema.json", "design DAOs", "implement", "emit"],
    )
    bf.dependencies = [("schema", []), ("repos", ["schema"])]
    bf.plan_lines = [
        "1. schema → defines DB tables",
        "2. repos  → builds data layer",
    ]
    bf.set_status("schema", Status.DONE_CLEAN, last_step="5/5")
    bf.sections["schema"].log = [
        "14:39 emitted artifact schema.json",
        "14:38 migration validated",
    ]
    bf.set_status("repos", Status.RUNNING, last_step="2/4")
    return bf


class BoardRenderParseRoundTripTests(unittest.TestCase):
    def test_round_trip_preserves_core_fields(self):
        bf = _sample_board()
        text = bf.render()
        rebuilt = BoardFile.parse(text)
        self.assertEqual(rebuilt.session_id, bf.session_id)
        self.assertEqual(rebuilt.leader_model, bf.leader_model)
        self.assertEqual(len(rebuilt.status_rows), 2)
        self.assertEqual(rebuilt.status_rows[0].group, "schema")
        self.assertEqual(rebuilt.status_rows[0].status, Status.DONE_CLEAN)
        self.assertEqual(rebuilt.status_rows[1].status, Status.RUNNING)
        self.assertEqual(set(rebuilt.sections.keys()), {"schema", "repos"})

    def test_section_plan_steps_round_trip(self):
        bf = _sample_board()
        # mark first plan step done
        bf.sections["schema"].plan[0].done = True
        rebuilt = BoardFile.parse(bf.render())
        self.assertTrue(rebuilt.sections["schema"].plan[0].done)
        self.assertFalse(rebuilt.sections["schema"].plan[1].done)
        self.assertEqual(rebuilt.sections["schema"].plan[0].text, "enumerate")

    def test_section_log_round_trip(self):
        bf = _sample_board()
        rebuilt = BoardFile.parse(bf.render())
        self.assertEqual(
            rebuilt.sections["schema"].log,
            ["14:39 emitted artifact schema.json", "14:38 migration validated"],
        )

    def test_dependencies_round_trip(self):
        bf = _sample_board()
        rebuilt = BoardFile.parse(bf.render())
        deps = dict(rebuilt.dependencies)
        self.assertEqual(deps["repos"], ["schema"])


class BoardMutatorTests(unittest.TestCase):
    def test_add_group_creates_row_and_section(self):
        bf = BoardFile(session_id="s", leader_model="L")
        bf.add_group("a", "m", plan=["one", "two"])
        self.assertIsNotNone(bf.find_row("a"))
        self.assertIn("a", bf.sections)
        self.assertEqual(bf.sections["a"].plan[0].text, "one")

    def test_add_group_idempotent(self):
        bf = BoardFile(session_id="s", leader_model="L")
        bf.add_group("a", "m", plan=["one"])
        bf.add_group("a", "m", plan=["two"])
        self.assertEqual(len(bf.status_rows), 1)
        self.assertEqual(bf.sections["a"].plan[0].text, "one")

    def test_set_status_syncs_row_and_section(self):
        bf = BoardFile(session_id="s", leader_model="L")
        bf.add_group("a", "m", plan=["x"])
        bf.set_status("a", Status.RUNNING, last_step="1/1")
        self.assertEqual(bf.find_row("a").status, Status.RUNNING)
        self.assertEqual(bf.sections["a"].status, Status.RUNNING)
        self.assertIsNotNone(bf.sections["a"].started_at)
        bf.set_status("a", Status.DONE_CLEAN, last_step="1/1")
        self.assertIsNotNone(bf.sections["a"].finished_at)


class SectionCompactionTests(unittest.TestCase):
    def test_compact_log_rolls_older_entries(self):
        s = BoardSection(group="a", log=[f"e{i}" for i in range(20)])
        rolled = s.compact_log(keep_last=5)
        self.assertEqual(rolled, 15)
        self.assertEqual(len(s.log), 6)
        self.assertTrue(s.log[0].startswith("(rolled"))
        self.assertEqual(s.log[-1], "e19")

    def test_compact_no_op_when_under_keep(self):
        s = BoardSection(group="a", log=["only"])
        rolled = s.compact_log(keep_last=5)
        self.assertEqual(rolled, 0)
        self.assertEqual(s.log, ["only"])

    def test_oversized_detection(self):
        s = BoardSection(group="a", log=[f"line {i}" for i in range(300)])
        self.assertTrue(s.is_oversized())


class BoardOversizedTests(unittest.TestCase):
    def test_small_board_not_oversized(self):
        bf = _sample_board()
        self.assertFalse(bf.is_oversized())

    def test_huge_log_makes_board_oversized(self):
        bf = _sample_board()
        bf.sections["schema"].log = [f"line {i} " * 5 for i in range(800)]
        self.assertTrue(bf.is_oversized())


class SlicingTests(unittest.TestCase):
    def test_slice_section_returns_only_target(self):
        text = _sample_board().render()
        chunk = slice_section(text, "schema")
        self.assertIsNotNone(chunk)
        self.assertIn("## <SECTION:schema>", chunk)
        self.assertNotIn("## <SECTION:repos>", chunk)

    def test_slice_section_missing_returns_none(self):
        text = _sample_board().render()
        self.assertIsNone(slice_section(text, "nope"))

    def test_slice_status_table(self):
        text = _sample_board().render()
        st = slice_status_table(text)
        self.assertIn("| schema |", st)
        self.assertIn("| repos |", st)
        self.assertNotIn("## <SECTION:", st)


class BoardAtomicIOTests(unittest.TestCase):
    def test_write_then_read(self):
        bf = _sample_board()
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "team_board.md"
            write_board(p, bf)
            self.assertTrue(p.exists())
            rebuilt = read_board(p)
            self.assertEqual(rebuilt.session_id, bf.session_id)
            self.assertEqual(len(rebuilt.status_rows), 2)


if __name__ == "__main__":
    unittest.main()
