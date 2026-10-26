#!/usr/bin/env python3
"""Tests for collect-muse.py. Run: python3 -m unittest discover -s tests"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
COLLECT = os.path.join(HERE, "..", "collect-muse.py")

START_S = 1_792_000_000  # window start; pinned via fake limits.json below
NOW_S = START_S + 3600


def record(ts_s, model, in_tok, out_tok, cache_read=0):
    return json.dumps({
        "schema_version": 1, "recorded_at": int(ts_s * 1_000_000),
        "payload_type": "runtime.session",
        "payload": {"kind": "run", "event": {
            "kind": "model_completed", "model": model,
            "duration_ms": 100,
            "usage": {"input_tokens": in_tok, "output_tokens": out_tok,
                      "cached_tokens": 0, "cache_read_tokens": cache_read,
                      "cache_write_tokens": 0, "reasoning_tokens": 0}}}})


def nested_record(ts_s, model, in_tok, out_tok):
    return json.dumps({"retained_frame": "x", "children": [
        {"child_index": 0, "record_json": record(ts_s, model, in_tok, out_tok)}]})


class CollectTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = self.tmp.name
        self.sessions = os.path.join(root, "sessions")
        self.state = os.path.join(root, "state")
        os.makedirs(os.path.join(self.sessions, "s1"))
        os.makedirs(os.path.join(self.sessions, "s2"))
        self.out = os.path.join(root, "latest.json")
        self.limits = os.path.join(root, "limits.json")
        with open(self.limits, "w") as fh:
            json.dump({"limits": [{
                "id": "1w", "resetsAt": (START_S + 604_800) * 1000,
                "durationMs": 604_800_000}]}, fh)
        self.file_a = os.path.join(self.sessions, "s1", "session.jsonl")
        with open(self.file_a, "w") as fh:
            fh.write(record(START_S + 100, "muse-wonder-1.0", 1_000_000, 100_000) + "\n")
            fh.write(record(START_S - 10, "muse-wonder-1.0", 9_000_000, 9_000) + "\n")
            fh.write('{"unrelated": true}\n')
        with open(os.path.join(self.sessions, "s2", "session.jsonl"), "w") as fh:
            fh.write(nested_record(START_S + 200, "muse-spark-1.3", 500_000, 100_000) + "\n")

    def tearDown(self):
        self.tmp.cleanup()

    def run_collect(self, now=NOW_S):
        r = subprocess.run(
            [sys.executable, COLLECT, "--sessions-dir", self.sessions,
             "--state-dir", self.state, "--limits", self.limits,
             "--out", self.out, "--now", str(now)],
            capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(self.out) as fh:
            return json.load(fh)

    def test_weekly_aggregation_and_estimated_cost(self):
        stats = self.run_collect()
        overall = stats["overall"]
        # Pre-window event excluded; nested retained_frame event counted.
        self.assertEqual(overall["totalRequests"], 2)
        self.assertEqual(overall["totalInputTokens"], 1_500_000)
        self.assertEqual(overall["totalOutputTokens"], 200_000)
        # wonder: 1M*$5 + 0.1M*$25 = $7.50; spark: 0.5M*$3 + 0.1M*$15 = $3.00
        self.assertAlmostEqual(overall["totalCost"], 10.50, places=6)
        self.assertTrue(stats["costEstimated"])

    def test_cached_input_not_billed_at_full_rate(self):
        with open(self.file_a, "a") as fh:
            # 1M input of which 800k cache-read, plus 100k output (wonder):
            # fresh 200k*$5 + 800k*$0.50 + 0.1M*$25 = $1.00+$0.40+$2.50
            fh.write(record(START_S + 400, "muse-wonder-1.0",
                            1_000_000, 100_000, cache_read=800_000) + "\n")
        stats = self.run_collect()
        self.assertAlmostEqual(stats["overall"]["totalCost"], 10.50 + 3.90, places=6)

    def test_incremental_rerun_does_not_double_count(self):
        self.run_collect()
        with open(self.file_a, "a") as fh:
            fh.write(record(START_S + 300, "muse-wonder-1.0", 0, 100_000) + "\n")
        stats = self.run_collect()
        self.assertEqual(stats["overall"]["totalRequests"], 3)
        self.assertAlmostEqual(stats["overall"]["totalCost"], 10.50 + 2.50, places=6)
        # Third run, no appends: unchanged.
        stats = self.run_collect()
        self.assertEqual(stats["overall"]["totalRequests"], 3)

    def test_previous_week_kept_separate(self):
        stats = self.run_collect()
        self.assertEqual(len(stats["weeks"]), 2)
        current, previous = stats["weeks"]
        self.assertEqual(current["windowStart"], stats["windowStart"])
        self.assertEqual(current["overall"]["totalRequests"], 2)
        # The START_S-10 event belongs to the previous week, not the bin.
        self.assertEqual(previous["overall"]["totalRequests"], 1)
        self.assertEqual(previous["overall"]["totalInputTokens"], 9_000_000)
        self.assertEqual(previous["byModel"][0]["model"], "muse-wonder-1.0")

    def test_events_survive_window_rollover(self):
        self.run_collect()
        stats = self.run_collect(now=START_S + 604_800 + 3600)
        self.assertEqual(stats["overall"]["totalRequests"], 0)
        self.assertEqual(stats["weeks"][0]["overall"]["totalRequests"], 2)
        self.assertEqual(stats["weeks"][1]["overall"]["totalRequests"], 1)


class WeekWindowFallbackTest(unittest.TestCase):
    def test_calendar_fallback_is_sunday_7pm_central(self):
        sys.path.insert(0, os.path.join(HERE, ".."))
        import importlib.util
        spec = importlib.util.spec_from_file_location("collect_muse", COLLECT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        # Wed 2026-10-14 12:00 UTC -> window opened Sun 2026-10-11 19:00 CDT
        # = Mon 2026-10-12 00:00 UTC.
        now = datetime(2026, 10, 14, 12, 0, tzinfo=timezone.utc).timestamp()
        expected = datetime(2026, 10, 12, 0, 0, tzinfo=timezone.utc).timestamp()
        with tempfile.TemporaryDirectory() as tmp:
            missing = os.path.join(tmp, "nope.json")
            self.assertEqual(mod.week_window(now, missing), expected)


if __name__ == "__main__":
    unittest.main()
