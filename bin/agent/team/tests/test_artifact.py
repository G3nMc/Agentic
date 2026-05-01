import sys
sys.dont_write_bytecode = True

import os
import tempfile
import unittest
from pathlib import Path

from agent.team.artifact import (
    Artifact,
    ARTIFACT_SCHEMA_VERSION,
    read_artifact,
    write_artifact,
)
from agent.team.status import Status


class ArtifactRoundTripTests(unittest.TestCase):
    def test_to_from_dict_round_trip(self):
        a = Artifact(
            group="schema",
            producer_model="sonnet-4-6",
            status=Status.DONE_CLEAN,
            summary="Added users + sessions tables.",
            decisions=[{"id": "users.pk", "what": "uuid v7", "why": "monotonic"}],
            files_touched=[{"path": "db/migrations/0042.sql", "action": "created"}],
            interfaces_exposed=[{"name": "users.id", "type": "uuid"}],
            warnings=["regenerated drift table"],
        )
        rebuilt = Artifact.from_dict(a.to_dict())
        self.assertEqual(rebuilt.group, "schema")
        self.assertEqual(rebuilt.status, Status.DONE_CLEAN)
        self.assertEqual(rebuilt.decisions, a.decisions)
        self.assertEqual(rebuilt.files_touched, a.files_touched)
        self.assertEqual(rebuilt.warnings, ["regenerated drift table"])
        self.assertEqual(rebuilt.schema_version, ARTIFACT_SCHEMA_VERSION)

    def test_to_from_json_round_trip(self):
        a = Artifact(group="g", producer_model="m", summary="hi")
        rebuilt = Artifact.from_json(a.to_json())
        self.assertEqual(rebuilt.group, "g")
        self.assertEqual(rebuilt.summary, "hi")

    def test_lenient_status_parse(self):
        rebuilt = Artifact.from_dict({
            "group": "g", "producer_model": "m", "status": "done-clean",
        })
        self.assertEqual(rebuilt.status, Status.DONE_CLEAN)


class ArtifactTrimTests(unittest.TestCase):
    def test_trim_no_op_when_under_budget(self):
        a = Artifact(group="g", producer_model="m", summary="short")
        applied = a.trim_to_budget(max_bytes=8 * 1024)
        self.assertEqual(applied, [])

    def test_trim_drops_decision_notes_first(self):
        big_note = "x" * 1000
        decisions = [
            {"id": f"d{i}", "what": "a", "why": "b", "notes": big_note}
            for i in range(20)
        ]
        a = Artifact(group="g", producer_model="m", decisions=decisions)
        self.assertGreater(a.serialized_bytes(), 8 * 1024)
        applied = a.trim_to_budget(max_bytes=8 * 1024)
        self.assertIn("dropped:decisions[].notes", applied)
        for d in a.decisions:
            self.assertNotIn("notes", d)

    def test_trim_truncates_decisions_when_still_oversized(self):
        decisions = [
            {"id": f"d{i}", "what": "x" * 200, "why": "y" * 200}
            for i in range(50)
        ]
        a = Artifact(group="g", producer_model="m",
                     summary="z" * 500, decisions=decisions)
        before = a.serialized_bytes()
        applied = a.trim_to_budget(max_bytes=2 * 1024)
        # Best-effort: each priority step ran and some shrinkage happened.
        self.assertIn("truncated:decisions", applied)
        self.assertLess(a.serialized_bytes(), before)
        self.assertLessEqual(len(a.decisions), 5)
        self.assertLessEqual(len(a.summary), 400)


class ArtifactAtomicIOTests(unittest.TestCase):
    def test_write_then_read(self):
        a = Artifact(group="g", producer_model="m", summary="ok")
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "g.json"
            write_artifact(p, a)
            self.assertTrue(p.exists())
            rebuilt = read_artifact(p)
            self.assertEqual(rebuilt.group, "g")
            self.assertEqual(rebuilt.summary, "ok")

    def test_overwrite_is_idempotent(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "g.json"
            write_artifact(p, Artifact(group="g", producer_model="m", summary="v1"))
            write_artifact(p, Artifact(group="g", producer_model="m", summary="v2"))
            self.assertEqual(read_artifact(p).summary, "v2")
            # Only the target file should remain (no .tmp leftovers)
            siblings = list(Path(d).iterdir())
            self.assertEqual(len(siblings), 1)


if __name__ == "__main__":
    unittest.main()
