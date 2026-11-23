import datetime
import importlib.util
import pathlib
import sqlite3
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "spend-review.py"
spec = importlib.util.spec_from_file_location("spend_review", SCRIPT)
spend_review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(spend_review)

TODAY = datetime.date(2026, 11, 23)  # a Monday


def database(*rows):
    db = sqlite3.connect(":memory:")
    db.execute("CREATE TABLE transcripts (date TEXT, project TEXT, session_id TEXT, agent_id TEXT, cost REAL)")
    db.executemany("INSERT INTO transcripts VALUES (?, ?, ?, ?, ?)", rows)
    return db


class SpendReviewTest(unittest.TestCase):
    def test_weekdays_run_monday_first_and_each_period_counts_its_own_days(self):
        db = database(("2026-11-23", "/w/a", "s1", None, 3.0), ("2026-11-13", "/w/a", "s2", None, 5.0))
        rows = spend_review.by_weekday(db, TODAY)
        self.assertEqual([row["day"] for row in rows], list(spend_review.WEEKDAYS))
        self.assertEqual(rows[0], {"day": "Mon", "last_30_days": 3.0, "last_14_days": 3.0, "last_7_days": 3.0})
        self.assertEqual(rows[4], {"day": "Fri", "last_30_days": 5.0, "last_14_days": 5.0, "last_7_days": 0.0})

    def test_projects_largest_first_with_scratch_folders_as_one(self):
        db = database(("2026-11-20", "/w/scratch-2026-11-20-ab", "s1", None, 1.0),
                      ("2026-11-21", "/w/scratch-2026-11-21-cd", "s2", None, 2.0),
                      ("2026-11-22", "/w/app", "s3", None, 9.0))
        self.assertEqual([(row["project"], row["last_7_days"]) for row in spend_review.by_project(db, TODAY)],
                         [("app", 9.0), ("scratch", 3.0)])

    def test_totals_count_sessions_agents_and_spend_per_day(self):
        db = database(("2026-11-23", "/w/a", "s1", None, 7.0), ("2026-11-23", "/w/a", "s1", "x", 7.0))
        week = list(spend_review.totals(db, TODAY))[-1]
        self.assertEqual(week, {"period": "last_7_days", "spend": 14.0, "per_day": 2.0, "sessions": 1, "agents": 1})


if __name__ == "__main__":
    unittest.main()
