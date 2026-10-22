from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("summarize_metrics.py")
SPEC = importlib.util.spec_from_file_location("pilot_summary", MODULE_PATH)
assert SPEC and SPEC.loader
pilot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pilot)


class PilotSummaryTest(unittest.TestCase):
    def test_rates_and_medians(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "scorecard.csv"
            path.write_text(
                "participant_id,first_topology_seconds,plan_manual_repair,"
                "crash_free,tasks_completed,blocking_issue\n"
                "p1,120,yes,yes,6,\n"
                "p2,180,no,yes,6,\n"
                "p3,240,no,no,4,installer blocked by policy\n",
                encoding="utf-8",
            )
            summary = pilot.summarize(path)
        self.assertEqual(summary["participants"], 3)
        self.assertEqual(summary["first_topology_success_rate"], 1)
        self.assertEqual(summary["durations_seconds"]["median"], 180)
        self.assertAlmostEqual(summary["manual_repair_rate"], 1 / 3)
        self.assertAlmostEqual(summary["crash_free_rate"], 2 / 3)
        self.assertEqual(summary["blocking_issues"][0]["participant_id"], "p3")

    def test_missing_metric_is_not_silently_counted_as_success(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "scorecard.csv"
            path.write_text(
                "participant_id,first_topology_seconds,plan_manual_repair,"
                "crash_free\n"
                "p1,100,,yes\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "plan_manual_repair is empty"):
                pilot.summarize(path)

    def test_duplicate_participant_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "scorecard.csv"
            path.write_text(
                "participant_id,first_topology_seconds,plan_manual_repair,"
                "crash_free\np1,100,no,yes\np1,110,no,yes\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "duplicate participant"):
                pilot.summarize(path)


if __name__ == "__main__":
    unittest.main()
