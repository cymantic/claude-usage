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
    def test_weekdays_run_monday_first_within_the_period(self):
        db = database(("2026-11-23", "/w/a", "s1", None, 3.0), ("2026-11-13", "/w/a", "s2", None, 5.0))
        week = spend_review.by_weekday(db, 7, TODAY)
        self.assertEqual([row["day"] for row in week], list(spend_review.WEEKDAYS))
        self.assertEqual((week[0]["spend"], week[4]["spend"]), (3.0, 0.0))
        self.assertEqual(spend_review.by_weekday(db, 14, TODAY)[4]["spend"], 5.0)

    def test_projects_largest_first_with_scratch_folders_as_one(self):
        db = database(("2026-11-20", "/w/scratch-2026-11-20-ab", "s1", None, 1.0),
                      ("2026-11-21", "/w/scratch-2026-11-21-cd", "s2", None, 2.0),
                      ("2026-11-22", "/w/app", "s3", None, 9.0))
        self.assertEqual(spend_review.by_project(db, 7, TODAY),
                         [{"project": "app", "spend": 9.0}, {"project": "scratch", "spend": 3.0}])

    def test_totals_count_sessions_agents_and_spend_per_day(self):
        db = database(("2026-11-23", "/w/a", "s1", None, 7.0), ("2026-11-23", "/w/a", "s1", "x", 7.0))
        self.assertEqual(spend_review.totals(db, 7, TODAY),
                         [{"days": 7, "spend": 14.0, "per_day": 2.0, "sessions": 1, "agents": 1}])

    def test_the_pane_gets_every_period(self):
        data = spend_review.all_periods(database(), TODAY)
        self.assertEqual((data["today"], list(data["periods"])), ("2026-11-23", [30, 14, 7]))


if __name__ == "__main__":
    unittest.main()
