#!/usr/bin/env python3
"""API-equivalent spend over the last 30, 14 or 7 days, behind the /spend-review mod.

  spend-review.py json                 every period's tables as JSON, for the mod's pane
  spend-review.py totals|weekday|project [DAYS]
                                       one table as CSV for the last DAYS days (30 if left out)

Runs usage-sync.py first, so every session and agent on this Mac, terminal and desktop app, is counted.
"""
import csv
import datetime
import json
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


def project_name(path):
    """A project by its folder; the desktop app's scratch-<date>-<id> folders count as one."""
    name = pathlib.Path(path).name if path else "?"
    return "scratch" if name.startswith("scratch-") else name


def totals(db, days, today):
    cost, sessions, agents = db.execute(
        "SELECT COALESCE(SUM(cost), 0), COUNT(DISTINCT session_id), COUNT(DISTINCT agent_id) "
        "FROM transcripts WHERE date >= ?", (since(days, today),)).fetchone()
    return [{"days": days, "spend": round(cost, 2), "per_day": round(cost / days, 2), "sessions": sessions,
             "agents": agents}]


def by_weekday(db, days, today):
    # shortcut: dates are UTC, so work after midnight in summer time counts on the day before; group by first_at in
    # local time if that matters.
    spend = dict.fromkeys(WEEKDAYS, 0.0)
    for date, cost in db.execute("SELECT date, SUM(cost) FROM transcripts WHERE date >= ? GROUP BY date",
                                 (since(days, today),)):
        spend[WEEKDAYS[datetime.date.fromisoformat(date).weekday()]] += cost
    return [{"day": day, "spend": round(cost, 2)} for day, cost in spend.items()]


def by_project(db, days, today):
    spend = {}
    for path, cost in db.execute("SELECT project, SUM(cost) FROM transcripts WHERE date >= ? GROUP BY project",
                                 (since(days, today),)):
        spend[project_name(path)] = spend.get(project_name(path), 0.0) + cost
    return [{"project": name, "spend": round(cost, 2)}
            for name, cost in sorted(spend.items(), key=lambda item: -item[1]) if round(cost, 2) > 0]


TABLES = {"totals": totals, "weekday": by_weekday, "project": by_project}


def all_periods(db, today):
    """Every period's tables, for the pane to switch between."""
    return {"today": today.isoformat(),
            "periods": {days: {"totals": totals(db, days, today)[0], "weekday": by_weekday(db, days, today),
                               "project": by_project(db, days, today)} for days in PERIODS}}


def main(argv):
    command, days = (argv + [None])[:2] if argv else (None, None)
    if command not in {*TABLES, "json"} or (days and not days.isdigit()):
        sys.exit("usage: spend-review.py json | totals|weekday|project [DAYS]")
    subprocess.run([HERE / "usage-sync.py"], check=True)
    db, today = sqlite3.connect(DATABASE), datetime.date.today()
    if command == "json":
        json.dump(all_periods(db, today), sys.stdout)
        return
    rows = TABLES[command](db, int(days or 30), today)
    out = csv.DictWriter(sys.stdout, fieldnames=list(rows[0]) if rows else ["empty"])
    out.writeheader()
    out.writerows(rows)


if __name__ == "__main__":
    main(sys.argv[1:])
