import sys
sys.dont_write_bytecode = True

import shutil
import tempfile
import unittest
from pathlib import Path

from agent.team.paths import TeamPaths, delete_session, session_dir_for


class TeamPathsTests(unittest.TestCase):
    def test_default_session_id_when_omitted(self):
        tp = TeamPaths.from_base("/some/project")
        self.assertEqual(tp.session_id, "_default")
        self.assertEqual(tp.root.name, "_default")

    def test_session_id_nests_under_team_root(self):
        tp = TeamPaths.for_session("/some/project", "abc123")
        # root is .../team/abc123, team_root is .../team
        self.assertEqual(tp.session_id, "abc123")
        self.assertEqual(tp.root.name, "abc123")
        self.assertEqual(tp.root.parent.name, "team")
        self.assertEqual(tp.team_root.name, "team")
        self.assertTrue(tp.board.name == "team_board.md")
        self.assertTrue(str(tp.artifact_path("g")).endswith("g.json"))

    def test_session_id_sanitization(self):
        # Path traversal attempts and weirdness collapse to _default
        for bad in ["..", "../escape", "a/b", "a\\b", "", None, "."]:
            tp = TeamPaths.from_base("/p", session_id=bad)
            self.assertEqual(tp.session_id, "_default",
                             f"Expected sanitization for {bad!r}")

    def test_uuid_session_id_is_accepted(self):
        guid = "69790e60-06fa-4c14-9729-39f7ba49c5e2"
        tp = TeamPaths.for_session("/p", guid)
        self.assertEqual(tp.session_id, guid)

    def test_ensure_dirs_creates_session_subtree(self):
        with tempfile.TemporaryDirectory() as d:
            tp = TeamPaths.for_session(d, "alpha")
            tp.ensure_dirs()
            self.assertTrue(tp.root.is_dir())
            self.assertTrue(tp.artifacts_dir.is_dir())
            self.assertTrue(tp.workers_dir.is_dir())
            # Sibling sessions are independent
            beta = TeamPaths.for_session(d, "beta")
            beta.ensure_dirs()
            self.assertNotEqual(tp.root, beta.root)
            self.assertTrue((tp.team_root / "alpha").is_dir())
            self.assertTrue((tp.team_root / "beta").is_dir())


class DeleteSessionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_delete_existing_session_returns_true(self):
        tp = TeamPaths.for_session(self.tmp, "g1")
        tp.ensure_dirs()
        (tp.board).write_text("x", encoding="utf-8")
        self.assertTrue(delete_session(self.tmp, "g1"))
        self.assertFalse(tp.root.exists())

    def test_delete_missing_session_returns_false(self):
        self.assertFalse(delete_session(self.tmp, "never-existed"))

    def test_delete_refuses_to_wipe_default_via_traversal(self):
        # Even an attempt with ".." must NOT reach _default's contents.
        tp = TeamPaths.for_session(self.tmp, "_default")
        tp.ensure_dirs()
        (tp.board).write_text("legacy", encoding="utf-8")
        # delete_session("..") sanitises to _default but the traversal
        # attempt gets refused (returns False, content untouched).
        result = delete_session(self.tmp, "..")
        self.assertFalse(result)
        self.assertTrue(tp.board.exists())

    def test_session_dir_for_helper(self):
        p = session_dir_for(self.tmp, "guid-123")
        self.assertEqual(p.name, "guid-123")
        self.assertEqual(p.parent.name, "team")


if __name__ == "__main__":
    unittest.main()
