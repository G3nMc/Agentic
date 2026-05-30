"""Tests for the input-cleaning pass in PathFilter.from_config.

The pre-fix behaviour caused an empty repo from the discovery tools'
perspective when the user typed "*.py, *.dart, *md, *.json, *.yaml" as
a single include_files entry — exactly the bug seen in production. These
tests pin the now-tolerant parsing.
"""

import sys

sys.dont_write_bytecode = True

import unittest
from pathlib import Path

from agent.path_filter import (
    PathFilter,
    _fix_missing_dot,
    _normalize_user_filter_entries,
)


class NormalizeEntriesTests(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(_normalize_user_filter_entries([]), [])
        self.assertEqual(_normalize_user_filter_entries(None), [])

    def test_canonical_entries_preserved(self):
        self.assertEqual(
            _normalize_user_filter_entries(["*.py", "*.dart"]),
            ["*.py", "*.dart"],
        )

    def test_comma_glued_glob_list_is_split(self):
        self.assertEqual(
            _normalize_user_filter_entries(["*.py, *.dart, *.md"]),
            ["*.py", "*.dart", "*.md"],
        )

    def test_missing_dot_inserted(self):
        self.assertEqual(_fix_missing_dot("*md"), "*.md")
        self.assertEqual(_fix_missing_dot("*py"), "*.py")
        # Canonical entries left alone
        self.assertEqual(_fix_missing_dot("*.py"), "*.py")

    def test_mixed_real_world_input(self):
        # The exact bug we saw in production
        self.assertEqual(
            _normalize_user_filter_entries(
                ["*.py, *.dart, *md, *.json, *.yaml"],
            ),
            ["*.py", "*.dart", "*.md", "*.json", "*.yaml"],
        )

    def test_path_with_comma_not_split(self):
        # A path entry containing a comma must NOT be split — splitting
        # is only applied when every comma-separated piece looks like
        # an extension glob.
        path = "/some/weird,path/with,commas"
        self.assertEqual(_normalize_user_filter_entries([path]), [path])

    def test_drops_empty_and_whitespace(self):
        self.assertEqual(
            _normalize_user_filter_entries(["", "  ", "*.py"]),
            ["*.py"],
        )


class FromConfigEndToEndTests(unittest.TestCase):
    def test_real_world_bad_input_yields_working_filter(self):
        # Replays the production config exactly: comma-glued globs.
        cfg = {
            "include_dirs": [str(Path.cwd() / "lib"), str(Path.cwd() / "bin")],
            "include_files": ["*.py, *.dart, *md, *.json, *.yaml"],
        }
        f = PathFilter.from_config(Path.cwd(), cfg)
        self.assertEqual(
            f.include_files,
            ["*.py", "*.dart", "*.md", "*.json", "*.yaml"],
        )
        # And the matcher actually accepts a .dart file under lib/
        sample = Path.cwd() / "lib" / "ui" / "widgets" / "message_bubble.dart"
        self.assertTrue(f.is_file_allowed(sample))


if __name__ == "__main__":
    unittest.main()
