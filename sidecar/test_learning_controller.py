import json
import os
import tempfile
import unittest

from learning_controller import SessionLearningController, StrategyStore


class LearningControllerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.temp.name, "strategy_memory.json")
        self.store = StrategyStore(self.path)
        self.session = SessionLearningController(self.store, "test-session")
        self.context = {
            "device": "R1",
            "model": "2911",
            "ptVersion": "test",
            "layout": 3,
        }

    def tearDown(self):
        self.temp.cleanup()

    def test_failure_is_banned_for_current_session(self):
        self.session.failure("ui_coordinate", "add_button", self.context,
                             {"x": 0.4, "y": 0.5}, "table unchanged")
        choices = self.session.choose(
            "ui_coordinate", "add_button", self.context,
            [{"x": 0.4, "y": 0.5}, {"x": 0.5, "y": 0.5}],
        )
        self.assertEqual(choices, [{"x": 0.5, "y": 0.5}])

    def test_verified_success_persists_and_is_preferred(self):
        first = {"x": 0.4, "y": 0.5}
        second = {"x": 0.5, "y": 0.5}
        self.session.success("ui_coordinate", "add_button", self.context,
                             second, "table changed")
        self.session.success("ui_coordinate", "add_button", self.context,
                             second, "table changed again")
        choices = self.session.choose(
            "ui_coordinate", "add_button", self.context, [first, second]
        )
        self.assertEqual(choices[0], second)
        self.assertTrue(os.path.isfile(self.path))
        with open(self.path, encoding="utf-8") as stream:
            data = json.load(stream)
        self.assertEqual(len(data["strategies"]), 1)
        row = next(iter(data["strategies"].values()))
        self.assertEqual(row["successes"], 2)
        self.assertGreater(row["confidence"], 0.7)

    def test_repeated_failures_quarantine_strategy(self):
        candidate = ["bad command"]
        self.session.failure("cli_fallback", "command", self.context,
                             candidate, "invalid input")
        self.session.failure("cli_fallback", "command", self.context,
                             candidate, "invalid input again")
        self.assertEqual(
            self.session.choose("cli_fallback", "command", self.context,
                                [candidate]),
            [],
        )
        row = self.store.get("cli_fallback", "command", self.context,
                             candidate)
        self.assertTrue(row["quarantined"])

    def test_unsafe_learning_stays_in_session(self):
        self.session.success("network_change", "acl", self.context,
                             ["permit ip any any"], "verified", persistent=True)
        self.assertFalse(os.path.exists(self.path))
        self.assertEqual(len(self.session.events()), 1)

    def test_verified_correction_is_available_immediately(self):
        source = ["switchport mode trunk"]
        replacement = ["switchport", "switchport mode trunk"]
        self.session.remember_correction(
            "cli_fallback",
            "command",
            {**self.context, "type": "switch", "layout": 3},
            source,
            replacement,
            "fallback verified in this run",
        )
        self.assertEqual(
            self.session.immediate_correction(
                "cli_fallback",
                "command",
                {**self.context, "type": "switch", "layout": 3},
                source,
            ),
            replacement,
        )
        self.session.failure(
            "cli_fallback",
            "command",
            {**self.context, "type": "switch", "layout": 3},
            replacement,
            "correction failed on a later device",
            persistent=False,
        )
        self.assertIsNone(
            self.session.immediate_correction(
                "cli_fallback",
                "command",
                {**self.context, "type": "switch", "layout": 3},
                source,
            )
        )
        self.assertEqual(self.session.summary()["immediateCorrections"], 1)


if __name__ == "__main__":
    unittest.main()
