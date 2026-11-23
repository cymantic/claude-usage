#!/usr/bin/env python3
"""Rebuild the transcripts table in ~/.claude/usage.db from every Claude Code transcript on this Mac.

The status line only runs in the terminal, so sessions in the desktop app never reach the sessions table. Every
session and every agent writes a transcript to ~/.claude/projects, with the tokens of each API call, so this counts
them all and prices them at API rates. It rebuilds the table from scratch each run: all transcripts take under a
second. usage-report.sh runs it first.
"""
import collections
import json
import pathlib
import sqlite3
import sys

HOME = pathlib.Path.home()
TRANSCRIPTS = HOME / ".claude" / "projects"
DATABASE = HOME / ".claude" / "usage.db"

# $ per million tokens: input, output, cache read. From the claude-api skill's price tables, November 2026; check
# them on the pricing page when a model is added. Cache writes are 1.25x input for 5 minutes and 2x for an hour.
PRICES = {
    "claude-fable-5-2": (8.00, 40.00, 0.20),
    "claude-fable-5-1": (10.00, 50.00, 0.25),
    "claude-fable-5": (10.00, 50.00, 1.00),
    "claude-opus-5-5": (4.00, 20.00, 0.20),
    "claude-opus-5": (5.00, 25.00, 0.50),
    "claude-opus-4-8": (5.00, 25.00, 0.50),
    "claude-opus-4-7": (5.00, 25.00, 0.50),
    "claude-opus-4-6": (5.00, 25.00, 0.50),
    "claude-sonnet-5-5": (2.00, 10.00, 0.10),
    "claude-sonnet-5": (2.00, 10.00, 0.20),
    "claude-sonnet-4-6": (3.00, 15.00, 0.30),
    "claude-haiku-5-5": (0.10, 0.50, 0.01),
    "claude-haiku-4-5": (1.00, 5.00, 0.10),
}
FIVE_MINUTE_WRITE = 1.25
ONE_HOUR_WRITE = 2.0
FAST_MODE = 2.0

# One row a transcript a day (UTC), so a session that runs for days counts on each of them. Derived, so it is dropped
# and rebuilt each run.
SCHEMA = """
DROP TABLE IF EXISTS transcripts;
CREATE TABLE transcripts (
  path TEXT, date TEXT, session_id TEXT, agent_id TEXT, kind TEXT, project TEXT, entrypoint TEXT, model TEXT,
  first_at TEXT, last_at TEXT, requests INTEGER, input_tokens INTEGER, cache_write_tokens INTEGER,
  cache_read_tokens INTEGER, output_tokens INTEGER, cost REAL, unpriced_requests INTEGER, PRIMARY KEY (path, date));
"""
WORKTREES = "/.claude/worktrees/"


# Pricing

def call_cost(model, usage):
    """What one API call would cost at API rates, or None for a model with no price."""
    if model not in PRICES:
        return None
    per_input, per_output, per_read = PRICES[model]
    writes = usage.get("cache_creation") or {}
    five_minute = writes.get("ephemeral_5m_input_tokens", usage.get("cache_creation_input_tokens", 0))
    one_hour = writes.get("ephemeral_1h_input_tokens", 0)
    dollars = (usage.get("input_tokens", 0) * per_input
               + usage.get("output_tokens", 0) * per_output
               + usage.get("cache_read_input_tokens", 0) * per_read
               + five_minute * per_input * FIVE_MINUTE_WRITE
               + one_hour * per_input * ONE_HOUR_WRITE) / 1_000_000
    return dollars * (FAST_MODE if usage.get("speed") == "fast" else 1)


# Reading transcripts

def api_calls(entries, seen):
    """Each API call in a transcript once, as (timestamp, model, usage), skipping calls already counted in `seen`."""
    for entry in entries:
        message = entry.get("message") or {}
        usage, call = message.get("usage"), message.get("id")
        if usage and call and call not in seen and message.get("model") != "<synthetic>":
            seen.add(call)
            yield entry.get("timestamp") or "", message.get("model"), usage


def summarise(entries, seen):
    """One transcript's totals for each day it made calls: tokens, priced cost, and where and when it ran."""
    entries = list(entries)
    first = next((e for e in entries if e.get("cwd")), {})
    where = {"project": first.get("cwd", "").split(WORKTREES)[0] or None, "entrypoint": first.get("entrypoint")}
    by_day = collections.defaultdict(list)
    for timestamp, model, usage in api_calls(entries, seen):
        by_day[timestamp[:10]].append((timestamp, model, usage))
    return [{**day_totals(calls), **where, "date": date or None} for date, calls in sorted(by_day.items())]


def day_totals(calls):
    totals = collections.Counter()
    models = collections.Counter()
    cost = 0.0
    for _, model, usage in calls:
        models[model] += 1
        totals["requests"] += 1
        totals["input_tokens"] += usage.get("input_tokens", 0)
        totals["cache_write_tokens"] += usage.get("cache_creation_input_tokens", 0)
        totals["cache_read_tokens"] += usage.get("cache_read_input_tokens", 0)
        totals["output_tokens"] += usage.get("output_tokens", 0)
        dollars = call_cost(model, usage)
        if dollars is None:
            totals["unpriced_requests"] += 1
        else:
            cost += dollars
    times = sorted(timestamp for timestamp, _, _ in calls if timestamp)
    return {
        **{k: totals[k] for k in ("requests", "input_tokens", "cache_write_tokens", "cache_read_tokens",
                                  "output_tokens", "unpriced_requests")},
        "cost": cost,
        "model": models.most_common(1)[0][0],
        "first_at": times[0] if times else None,
        "last_at": times[-1] if times else None,
    }


def read_entries(path):
    for line in path.open(errors="ignore"):
        try:
            yield json.loads(line)
        except ValueError:
            continue


def identify(path):
    """The session a transcript belongs to, and its agent if it is one: <session>.jsonl or
    <session>/subagents/agent-<id>.jsonl."""
    if path.parent.name == "subagents":
        return path.parent.parent.name, path.stem.removeprefix("agent-")
    return path.stem, None


# The database

def migrate_sessions(db):
    """Bring a sessions table from the first status line up to date: tokens_in was the context, not usage."""
    columns = {row[1] for row in db.execute("PRAGMA table_info(sessions)")}
    if "tokens_in" in columns:
        db.execute("ALTER TABLE sessions RENAME COLUMN tokens_in TO context_tokens")
    if "tokens_out" in columns:
        db.execute("ALTER TABLE sessions DROP COLUMN tokens_out")
    if columns and "branch" not in columns:
        db.execute("ALTER TABLE sessions ADD COLUMN branch TEXT")


def sync(db, transcripts):
    db.executescript(SCHEMA)
    migrate_sessions(db)
    seen = set()
    rows = []
    for path in sorted(transcripts.rglob("*.jsonl"), key=lambda p: p.stat().st_mtime):
        session_id, agent_id = identify(path)
        for day in summarise(read_entries(path), seen):
            rows.append({"path": str(path), "session_id": session_id, "agent_id": agent_id,
                         "kind": "agent" if agent_id else "session", **day})
    columns = ["path", "session_id", "agent_id", "kind", "project", "entrypoint", "model", "first_at", "last_at", "date",
               "requests", "input_tokens", "cache_write_tokens", "cache_read_tokens", "output_tokens", "cost",
               "unpriced_requests"]
    with db:
        db.execute("DELETE FROM transcripts")
        db.executemany(f"INSERT INTO transcripts ({', '.join(columns)}) VALUES ({', '.join(':' + c for c in columns)})",
                       rows)
    return rows


def main():
    db = sqlite3.connect(DATABASE)
    rows = sync(db, TRANSCRIPTS)
    unpriced = sum(r["unpriced_requests"] for r in rows)
    if unpriced:
        models = sorted({r["model"] for r in rows if r["unpriced_requests"]} - {None})
        print(f"usage-sync: {unpriced} calls have no price ({', '.join(models)}): add them to PRICES", file=sys.stderr)


if __name__ == "__main__":
    main()
