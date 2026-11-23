#!/usr/bin/env python3
"""The tables behind /spend-review: API-equivalent spend over the last 30, 14 and 7 days.

  spend-review.py totals     spend, sessions and agents in each period
  spend-review.py weekday    spend on each day of the week, Monday first
  spend-review.py project    spend in each project

Runs usage-sync.py first, so every session and agent on this Mac, terminal and desktop app, is counted.
"""
import csv
import datetime
import pathlib
import sqlite3
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
DATABASE = pathlib.Path.home() / ".claude" / "usage.db"
PERIODS = (30, 14, 7)
WEEKDAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")


def since(days, today):
    """The first date in a period of `days` ending today."""
    return (today - datetime.timedelta(days=days - 1)).isoformat()


def period(days):
    return f"last_{days}_days"


def project_name(path):
    """A project by its folder; the desktop app's scratch-<date>-<id> folders count as one."""
    name = pathlib.Path(path).name if path else "?"
    return "scratch" if name.startswith("scratch-") else name


def totals(db, today):
    for days in PERIODS:
        cost, sessions, agents = db.execute(
            "SELECT COALESCE(SUM(cost), 0), COUNT(DISTINCT session_id), COUNT(DISTINCT agent_id) "
            "FROM transcripts WHERE date >= ?", (since(days, today),)).fetchone()
        yield {"period": period(days), "spend": round(cost, 2), "per_day": round(cost / days, 2),
               "sessions": sessions, "agents": agents}


def spend_by(db, today, label, column, name):
    """One row a label, with its spend in each period."""
    spend = {}
    for days in PERIODS:
        for value, cost in db.execute(f"SELECT {column}, SUM(cost) FROM transcripts WHERE date >= ? GROUP BY {column}",
                                      (since(days, today),)):
            row = spend.setdefault(name(value), {label: name(value), **dict.fromkeys(map(period, PERIODS), 0.0)})
            row[period(days)] += cost
    return [{k: round(v, 2) if isinstance(v, float) else v for k, v in row.items()} for row in spend.values()]


def by_weekday(db, today):
    # shortcut: dates are UTC, so work after midnight in summer time counts on the day before; group by first_at in
    # local time if that matters.
    rows = {row["day"]: row for row in
            spend_by(db, today, "day", "date", lambda date: WEEKDAYS[datetime.date.fromisoformat(date).weekday()])}
    return [rows.get(day, {"day": day, **dict.fromkeys(map(period, PERIODS), 0.0)}) for day in WEEKDAYS]


def by_project(db, today):
    return sorted(spend_by(db, today, "project", "project", project_name), key=lambda row: -row[period(PERIODS[0])])


TABLES = {"totals": totals, "weekday": by_weekday, "project": by_project}


def main(argv):
    if len(argv) != 1 or argv[0] not in TABLES:
        sys.exit(f"usage: spend-review.py {'|'.join(TABLES)}")
    subprocess.run([HERE / "usage-sync.py"], check=True)
    rows = list(TABLES[argv[0]](sqlite3.connect(DATABASE), datetime.date.today()))
    out = csv.DictWriter(sys.stdout, fieldnames=list(rows[0]))
    out.writeheader()
    out.writerows(rows)


if __name__ == "__main__":
    main(sys.argv[1:])
