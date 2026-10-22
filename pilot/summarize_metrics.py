#!/usr/bin/env python3
"""Summarize a completed NetBuilder AI pilot scorecard.

The sheet is local-only: this script reads one CSV and prints a summary. It
never uploads or writes another copy of the observations.
"""

from __future__ import annotations

import argparse
import csv
import json
import statistics
import sys
from pathlib import Path

TRUE_VALUES = {"1", "yes", "true", "y"}
FALSE_VALUES = {"0", "no", "false", "n"}


def _parse_bool(value: str, field: str, row_number: int) -> bool:
    normalized = (value or "").strip().lower()
    if normalized in TRUE_VALUES:
        return True
    if normalized in FALSE_VALUES:
        return False
    if not normalized:
        raise ValueError(f"row {row_number}: {field} is empty")
    raise ValueError(f"row {row_number}: {field} must be yes/no, got {value!r}")


def _parse_seconds(value: str, row_number: int) -> float | None:
    text = (value or "").strip()
    if not text:
        return None
    try:
        seconds = float(text)
    except ValueError as error:
        raise ValueError(
            f"row {row_number}: first_topology_seconds must be numeric"
        ) from error
    if seconds < 0:
        raise ValueError(f"row {row_number}: first_topology_seconds is negative")
    return seconds


def summarize(path: Path) -> dict:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        required = {
            "participant_id",
            "first_topology_seconds",
            "plan_manual_repair",
            "crash_free",
        }
        missing = required.difference(reader.fieldnames or [])
        if missing:
            raise ValueError(
                "scorecard is missing columns: " + ", ".join(sorted(missing))
            )
        rows = list(reader)

    if not rows:
        raise ValueError("scorecard has no participant rows")

    durations: list[float] = []
    repairs: list[bool] = []
    crash_free: list[bool] = []
    completed: list[int] = []
    blockers: list[dict[str, str]] = []
    participants: set[str] = set()

    for offset, row in enumerate(rows, start=2):
        participant = (row.get("participant_id") or "").strip()
        if not participant:
            raise ValueError(f"row {offset}: participant_id is empty")
        if participant in participants:
            raise ValueError(f"row {offset}: duplicate participant {participant}")
        participants.add(participant)

        duration = _parse_seconds(row.get("first_topology_seconds", ""), offset)
        if duration is not None:
            durations.append(duration)
        repair = _parse_bool(row.get("plan_manual_repair", ""), "plan_manual_repair", offset)
        if repair is not None:
            repairs.append(repair)
        clean = _parse_bool(row.get("crash_free", ""), "crash_free", offset)
        if clean is not None:
            crash_free.append(clean)
        task_text = (row.get("tasks_completed") or "").strip()
        if task_text:
            try:
                count = int(task_text)
            except ValueError as error:
                raise ValueError(
                    f"row {offset}: tasks_completed must be an integer"
                ) from error
            if not 0 <= count <= 7:
                raise ValueError(
                    f"row {offset}: tasks_completed must be between 0 and 7"
                )
            completed.append(count)
        issue = (row.get("blocking_issue") or "").strip()
        if issue and issue.lower() not in {"none", "no", "n/a"}:
            blockers.append({"participant_id": participant, "issue": issue})

    def rate(values: list[bool]) -> float | None:
        return sum(values) / len(values) if values else None

    return {
        "participants": len(participants),
        "first_topology_success_rate": len(durations) / len(rows),
        "durations_seconds": {
            "count": len(durations),
            "mean": statistics.mean(durations) if durations else None,
            "median": statistics.median(durations) if durations else None,
            "min": min(durations) if durations else None,
            "max": max(durations) if durations else None,
        },
        "manual_repair_rate": rate(repairs),
        "crash_free_rate": rate(crash_free),
        "mean_tasks_completed": (
            statistics.mean(completed) if completed else None
        ),
        "blocking_issues": blockers,
    }


def _print_text(summary: dict) -> None:
    print("NetBuilder AI pilot summary")
    print(f"Participants: {summary['participants']}")
    durations = summary["durations_seconds"]
    print(
        "Reached a valid topology: "
        f"{summary['first_topology_success_rate'] * 100:.0f}% "
        f"({durations['count']}/{summary['participants']})"
    )
    if durations["count"]:
        print(
            "Time to first valid topology: "
            f"mean {durations['mean']:.0f}s, "
            f"median {durations['median']:.0f}s, "
            f"range {durations['min']:.0f}-{durations['max']:.0f}s "
            f"({durations['count']} sessions)"
        )
    else:
        print("Time to first valid topology: no completed observations")
    for label, key in (
        ("Plans needing manual repair", "manual_repair_rate"),
        ("Crash-free sessions", "crash_free_rate"),
    ):
        value = summary[key]
        print(f"{label}: {'no data' if value is None else f'{value * 100:.0f}%'}")
    if summary["mean_tasks_completed"] is not None:
        print(f"Mean tasks completed: {summary['mean_tasks_completed']:.1f}")
    if summary["blocking_issues"]:
        print("Blocking issues:")
        for blocker in summary["blocking_issues"]:
            print(f"- {blocker['participant_id']}: {blocker['issue']}")
    else:
        print("Blocking issues: none recorded")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scorecard", type=Path)
    parser.add_argument("--json", action="store_true", help="print JSON")
    args = parser.parse_args(argv)
    try:
        summary = summarize(args.scorecard)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        _print_text(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
