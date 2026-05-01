import sys
sys.dont_write_bytecode = True

import unittest

from agent.team.status import Status, is_terminal, is_clean, is_failure


class StatusParseTests(unittest.TestCase):
    def test_known_values_round_trip(self):
        for s in Status:
            self.assertEqual(Status.parse(s.value), s)

    def test_lenient_normalization(self):
        self.assertEqual(Status.parse("done-clean"), Status.DONE_CLEAN)
        self.assertEqual(Status.parse(" running "), Status.RUNNING)
        self.assertEqual(Status.parse("Done With Warnings"), Status.DONE_WITH_WARNINGS)

    def test_unknown_collapses_to_pending(self):
        self.assertEqual(Status.parse(""), Status.PENDING)
        self.assertEqual(Status.parse("WHATEVER"), Status.PENDING)


class StatusPredicateTests(unittest.TestCase):
    def test_terminal_set(self):
        self.assertTrue(is_terminal(Status.DONE_CLEAN))
        self.assertTrue(is_terminal(Status.DONE_WITH_WARNINGS))
        self.assertTrue(is_terminal(Status.FAILED))
        self.assertTrue(is_terminal(Status.INTERRUPTED))
        self.assertFalse(is_terminal(Status.PENDING))
        self.assertFalse(is_terminal(Status.RUNNING))

    def test_clean_set(self):
        self.assertTrue(is_clean(Status.DONE_CLEAN))
        self.assertTrue(is_clean(Status.DONE_WITH_WARNINGS))
        self.assertFalse(is_clean(Status.FAILED))

    def test_failure_set(self):
        self.assertTrue(is_failure(Status.FAILED))
        self.assertTrue(is_failure(Status.INTERRUPTED))
        self.assertFalse(is_failure(Status.DONE_CLEAN))


if __name__ == "__main__":
    unittest.main()
