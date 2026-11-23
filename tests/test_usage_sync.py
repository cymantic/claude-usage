import importlib.util
import json
import pathlib
import sqlite3
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "usage-sync.py"
spec = importlib.util.spec_from_file_location("usage_sync", SCRIPT)
usage_sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(usage_sync)


def call(call_id, model="claude-opus-5-5", at="2026-11-23T10:00:00Z", cwd="/work/app", **usage):
    return {"timestamp": at, "cwd": cwd, "entrypoint": "claude-desktop",
            "message": {"id": call_id, "model": model, "usage": usage}}


class PricingTest(unittest.TestCase):
    def test_each_kind_of_token_has_its_own_rate(self):
        usage = {"input_tokens": 1_000_000, "output_tokens": 1_000_000, "cache_read_input_tokens": 1_000_000,
                 "cache_creation": {"ephemeral_5m_input_tokens": 1_000_000, "ephemeral_1h_input_tokens": 1_000_000}}
        self.assertAlmostEqual(usage_sync.call_cost("claude-opus-5-5", usage), 4 + 20 + 0.20 + 5 + 8)

    def test_cache_writes_without_a_breakdown_are_five_minute(self):
        self.assertAlmostEqual(usage_sync.call_cost("claude-sonnet-5-5", {"cache_creation_input_tokens": 1_000_000}),
                               2.5)

    def test_fast_mode_doubles_the_price(self):
        self.assertAlmostEqual(usage_sync.call_cost("claude-opus-5-5", {"output_tokens": 1_000_000, "speed": "fast"}),
                               40)

    def test_a_model_with_no_price_is_none(self):
        self.assertIsNone(usage_sync.call_cost("claude-future-9", {"output_tokens": 1}))


class SummaryTest(unittest.TestCase):
    def test_a_call_is_counted_once_however_often_it_appears(self):
        seen = set()
        [first] = usage_sync.summarise([call("a", output_tokens=10), call("a", output_tokens=10)], seen)
        again = usage_sync.summarise([call("a", output_tokens=10)], seen)
        self.assertEqual((first["requests"], first["output_tokens"]), (1, 10))
        self.assertEqual(again, [])

    def test_unpriced_and_synthetic_calls(self):
        [summary] = usage_sync.summarise([call("a", "claude-future-9", output_tokens=5),
                                          call("b", "<synthetic>", output_tokens=5)], set())
        self.assertEqual((summary["requests"], summary["unpriced_requests"], summary["cost"]), (1, 1, 0))

    def test_where_and_when(self):
        [summary] = usage_sync.summarise([call("a", output_tokens=1)], set())
        self.assertEqual((summary["project"], summary["entrypoint"], summary["date"]),
                         ("/work/app", "claude-desktop", "2026-11-23"))

    def test_a_session_counts_on_each_day_it_ran(self):
        days = usage_sync.summarise([call("a", at="2026-11-16T09:00:00Z", output_tokens=1),
                                     call("b", at="2026-11-23T09:00:00Z", output_tokens=2)], set())
        self.assertEqual([(d["date"], d["output_tokens"]) for d in days], [("2026-11-16", 1), ("2026-11-23", 2)])

    def test_an_agent_in_a_worktree_belongs_to_its_repository(self):
        [summary] = usage_sync.summarise([call("a", cwd="/work/app/.claude/worktrees/agent-a9", output_tokens=1)], set())
        self.assertEqual(summary["project"], "/work/app")

    def test_an_agent_transcript_names_its_session(self):
        self.assertEqual(usage_sync.identify(pathlib.Path("p/s1/subagents/agent-a9.jsonl")), ("s1", "a9"))
        self.assertEqual(usage_sync.identify(pathlib.Path("p/s1.jsonl")), ("s1", None))


class DatabaseTest(unittest.TestCase):
    def test_sync_rebuilds_the_table_and_migrates_old_sessions(self):
        with tempfile.TemporaryDirectory() as root:
            projects = pathlib.Path(root) / "projects" / "-work-app"
            (projects / "s1" / "subagents").mkdir(parents=True)
            (projects / "s1.jsonl").write_text(json.dumps(call("a", output_tokens=100)) + "\n")
            (projects / "s1" / "subagents" / "agent-x.jsonl").write_text(json.dumps(call("b", output_tokens=50)))
            db = sqlite3.connect(":memory:")
            db.execute("CREATE TABLE sessions (session_id TEXT PRIMARY KEY, tokens_in INTEGER, tokens_out INTEGER)")
            usage_sync.sync(db, pathlib.Path(root) / "projects")
            usage_sync.sync(db, pathlib.Path(root) / "projects")
            rows = db.execute("SELECT session_id, kind, output_tokens FROM transcripts ORDER BY kind").fetchall()
            self.assertEqual(rows, [("s1", "agent", 50), ("s1", "session", 100)])
            columns = [row[1] for row in db.execute("PRAGMA table_info(sessions)")]
            self.assertEqual(columns, ["session_id", "context_tokens", "branch"])


if __name__ == "__main__":
    unittest.main()
