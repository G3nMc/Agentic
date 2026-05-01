import sys
sys.dont_write_bytecode = True

import tempfile
import unittest
from pathlib import Path

from agent.team.paths import TeamPaths


class TeamPathsTests(unittest.TestCase):
    def test_paths_under_dot_agent(self):
        tp = TeamPaths.from_base("/some/project")
        self.assertEqual(tp.root.name, "team")
        self.assertEqual(tp.root.parent.name, ".agent")
        self.assertTrue(tp.board.name == "team_board.md")
        self.assertTrue(str(tp.artifact_path("g")).endswith("g.json"))
        self.assertTrue(str(tp.worker_stderr("g")).endswith("g.stderr.log"))

    def test_ensure_dirs_creates_tree(self):
        with tempfile.TemporaryDirectory() as d:
            tp = TeamPaths.from_base(d)
            tp.ensure_dirs()
            self.assertTrue(tp.root.is_dir())
            self.assertTrue(tp.artifacts_dir.is_dir())
            self.assertTrue(tp.workers_dir.is_dir())
            # Idempotent
            tp.ensure_dirs()


if __name__ == "__main__":
    unittest.main()
