import sys

sys.dont_write_bytecode = True

import shutil
import tempfile
import unittest

from agent.team.board import BoardFile, read_board, write_board
from agent.team.paths import TeamPaths
from agent.team.soft_breaker import maybe_compact_section


class SoftBreakerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.paths = TeamPaths.from_base(self.tmp)
        self.paths.ensure_dirs()
        bf = BoardFile(session_id="t", leader_model="L")
        bf.add_group("g", "m", plan=["x", "y"])
        write_board(self.paths.board, bf)

    def test_no_op_when_under_budget(self):
        compacted, rolled = maybe_compact_section(self.paths, "g")
        self.assertFalse(compacted)
        self.assertEqual(rolled, 0)

    def test_compacts_when_over_line_budget(self):
        bf = read_board(self.paths.board)
        bf.sections["g"].log = [f"entry {i}" for i in range(200)]
        write_board(self.paths.board, bf)
        compacted, rolled = maybe_compact_section(self.paths, "g")
        self.assertTrue(compacted)
        self.assertGreater(rolled, 0)
        bf = read_board(self.paths.board)
        # 5 most recent + 1 summary line
        self.assertLessEqual(len(bf.sections["g"].log), 6)
        self.assertTrue(bf.sections["g"].log[0].startswith("(rolled"))

    def test_idempotent_after_first_pass(self):
        bf = read_board(self.paths.board)
        bf.sections["g"].log = [f"entry {i}" for i in range(200)]
        write_board(self.paths.board, bf)
        maybe_compact_section(self.paths, "g")
        compacted, rolled = maybe_compact_section(self.paths, "g")
        self.assertFalse(compacted)
        self.assertEqual(rolled, 0)

    def test_unknown_group_no_op(self):
        compacted, rolled = maybe_compact_section(self.paths, "missing")
        self.assertFalse(compacted)
        self.assertEqual(rolled, 0)


if __name__ == "__main__":
    unittest.main()
