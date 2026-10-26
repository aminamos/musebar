#!/usr/bin/env python3
"""Collect Muse usage for MuseBar.

Source: ~/.local/share/muse/sessions/**/session.jsonl `model_completed`
events (the `omp stats --json` source went silent when usage moved from
omp to Muse; omp only reports a trailing-24h window anyway).

Window: the current weekly quota window — last Sunday 19:00
America/Chicago (7pm Central) through now. When ~/.musebar/limits.json
has the provider's weekly window, its resetsAt - durationMs wins.

Cost is an ESTIMATE: Muse models are subscription-covered and publish no
per-token price, so totals use per-1M-token rates below. Override any of
them in ~/.musebar/rates.json, e.g.
  {"muse-wonder-1.0": {"input": 5.0, "output": 25.0}}
Cache reads bill at 0.1x input, cache writes at 1.25x input.

Parsing is incremental: byte offsets per session file are kept in
~/.musebar/muse-offsets.json and parsed events (trimmed to the window)
in ~/.musebar/muse-events.jsonl, so repeat runs only read appended bytes.
"""
import argparse
import json
import os
import sys
import tempfile
from datetime import datetime, time, timedelta, timezone

DEFAULT_RATES = {
    "muse-wonder-1.0": {"input": 5.0, "output": 25.0},
    "muse-wonder-full-1.0": {"input": 5.0, "output": 25.0},
    "muse-spark-1.3": {"input": 3.0, "output": 15.0},
    "*": {"input": 3.0, "output": 15.0},
}
WEEK_MS = 604_800_000


def week_window(now_s, limits_path):
    """Start (epoch s) of the weekly window containing now_s."""
    try:
        with open(limits_path) as fh:
            limits = json.load(fh).get("limits", [])
        for lim in limits:
            if lim.get("id") == "1w" and lim.get("resetsAt"):
                dur_s = (lim.get("durationMs") or WEEK_MS) / 1000.0
                start = lim["resetsAt"] / 1000.0 - dur_s
                while start + dur_s <= now_s:
                    start += dur_s
                while start > now_s:
                    start -= dur_s
                return start
    except Exception:
        pass
    # Fallback: most recent Sunday 19:00 in America/Chicago.
    try:
        from zoneinfo import ZoneInfo
        tz = ZoneInfo("America/Chicago")
    except Exception:
        tz = timezone(timedelta(hours=-5))
    local = datetime.fromtimestamp(now_s, tz)
    days_since_sunday = (local.weekday() + 1) % 7
    sunday = (local - timedelta(days=days_since_sunday)).date()
    start_local = datetime.combine(sunday, time(19, 0), tz)
    if start_local.timestamp() > now_s:
        start_local -= timedelta(days=7)
    return start_local.timestamp()


def load_rates(rates_path):
    rates = {k: dict(v) for k, v in DEFAULT_RATES.items()}
    try:
        with open(rates_path) as fh:
            for model, cfg in json.load(fh).items():
                rates.setdefault(model, {}).update(cfg)
    except Exception:
        pass
    return rates


def event_cost(rates, model, in_tok, out_tok, cache_read, cache_write):
    cfg = rates.get(model) or rates["*"]
    inp = float(cfg.get("input", rates["*"]["input"]))
    outp = float(cfg.get("output", rates["*"]["output"]))
    cr_rate = float(cfg.get("cache_read", inp * 0.1))
    cw_rate = float(cfg.get("cache_write", inp * 1.25))
    # usage.input_tokens already includes cached tokens; bill only the
    # fresh remainder at the full input rate.
    fresh = max(0, in_tok - cache_read - cache_write)
    per_m = (fresh * inp + out_tok * outp
             + cache_read * cr_rate + cache_write * cw_rate)
    return per_m / 1_000_000.0


def iter_records(obj):
    """Yield session records from one log line's parsed JSON.

    Lines are either a record directly, or a retained_frame whose
    children carry the record as a JSON string.
    """
    if not isinstance(obj, dict):
        return
    yield obj
    for child in obj.get("children") or []:
        raw = child.get("record_json") if isinstance(child, dict) else None
        if raw:
            try:
                yield json.loads(raw)
            except ValueError:
                continue


def parse_appended(path, offset):
    """Parse complete lines from offset; return (events, new_offset).

    Events: (ts_s, model, in, out, cache_read, cache_write).
    Only the bytes up to the last newline are consumed, so a line being
    written mid-run is re-read whole next time.
    """
    events = []
    try:
        with open(path, "rb") as fh:
            fh.seek(offset)
            data = fh.read()
    except OSError:
        return events, offset
    last_nl = data.rfind(b"\n")
    if last_nl < 0:
        return events, offset
    chunk = data[:last_nl + 1]
    for line in chunk.splitlines():
        if b"model_completed" not in line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        for rec in iter_records(obj):
            payload = rec.get("payload") if isinstance(rec, dict) else None
            ev = (payload or {}).get("event") or {}
            if ev.get("kind") != "model_completed":
                continue
            usage = ev.get("usage") or {}
            ts = (rec.get("recorded_at") or 0) / 1_000_000.0
            cache_read = usage.get("cache_read_tokens")
            if not cache_read:
                cache_read = usage.get("cached_tokens") or 0
            events.append((
                ts,
                ev.get("model") or "unknown",
                usage.get("input_tokens") or 0,
                usage.get("output_tokens") or 0,
                cache_read,
                usage.get("cache_write_tokens") or 0,
            ))
    return events, offset + len(chunk)


def atomic_write(path, text):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def aggregate(events, rates):
    overall = {"totalRequests": 0, "successfulRequests": 0, "failedRequests": 0,
               "totalInputTokens": 0, "totalOutputTokens": 0,
               "totalCacheReadTokens": 0, "totalCacheWriteTokens": 0,
               "totalCost": 0.0, "totalPremiumRequests": 0}
    by_model = {}
    for _ts, model, in_tok, out_tok, cache_read, cache_write in events:
        cost = event_cost(rates, model, in_tok, out_tok, cache_read, cache_write)
        m = by_model.setdefault(model, {
            "model": model, "provider": "muse", "totalRequests": 0,
            "totalInputTokens": 0, "totalOutputTokens": 0,
            "totalCacheReadTokens": 0, "totalCacheWriteTokens": 0,
            "totalCost": 0.0})
        for agg in (overall, m):
            agg["totalRequests"] += 1
            agg["totalInputTokens"] += in_tok
            agg["totalOutputTokens"] += out_tok
            agg["totalCacheReadTokens"] += cache_read
            agg["totalCacheWriteTokens"] += cache_write
            agg["totalCost"] += cost
    overall["successfulRequests"] = overall["totalRequests"]
    return overall, sorted(by_model.values(), key=lambda m: -m["totalRequests"])


MAX_WEEKS = 52


def collect(sessions_dir, state_dir, limits_path, rates_path, out_path, now_s):
    start_s = week_window(now_s, limits_path)
    week_s = WEEK_MS / 1000.0
    rates = load_rates(rates_path)
    os.makedirs(state_dir, exist_ok=True)
    events_path = os.path.join(state_dir, "muse-events.jsonl")
    offsets_path = os.path.join(state_dir, "muse-offsets.json")
    # Pre-history builds pruned muse-events.jsonl to the current week and
    # marked old session files as seen, so previous weeks are unrecoverable
    # from state alone. One full rescan of the session logs rebuilds them.
    marker_path = os.path.join(state_dir, "muse-history-v2")
    rescan = not os.path.exists(marker_path)

    events = []
    if not rescan:
        try:
            with open(events_path) as fh:
                for line in fh:
                    try:
                        row = json.loads(line)
                        if len(row) >= 6:
                            events.append(tuple(row))
                    except (ValueError, TypeError):
                        continue
        except OSError:
            pass
    offsets = {}
    if not rescan:
        try:
            with open(offsets_path) as fh:
                offsets = {k: int(v) for k, v in json.load(fh).items()}
        except Exception:
            offsets = {}

    for root, _dirs, files in os.walk(sessions_dir):
        if "session.jsonl" not in files:
            continue
        path = os.path.join(root, "session.jsonl")
        try:
            st = os.stat(path)
        except OSError:
            continue
        offset = offsets.get(path, 0)
        if st.st_size < offset:
            offset = 0  # truncated/rotated; rescan
        if st.st_size == offset:
            offsets[path] = offset
            continue
        new_events, offsets[path] = parse_appended(path, offset)
        events.extend(new_events)

    events = sorted(e for e in events if e[0] <= now_s + 60)
    atomic_write(events_path, "".join(json.dumps(list(e)) + "\n" for e in events))
    atomic_write(offsets_path, json.dumps(offsets))
    atomic_write(marker_path, "2\n")

    by_week = {}
    for e in events:
        idx = int((e[0] - start_s) // week_s)
        by_week.setdefault(idx, []).append(e)
    by_week.setdefault(0, [])  # current week exists even with no events yet
    weeks = []
    for idx in sorted(by_week, reverse=True)[:MAX_WEEKS]:
        w_start = start_s + idx * week_s
        w_overall, w_by_model = aggregate(by_week[idx], rates)
        weeks.append({
            "windowStart": datetime.fromtimestamp(w_start, timezone.utc).isoformat(),
            "windowEnd": datetime.fromtimestamp(w_start + week_s, timezone.utc).isoformat(),
            "overall": w_overall,
            "byModel": w_by_model,
        })
    overall, by_model = aggregate(by_week.get(0, []), rates)

    payload = {
        "source": "muse",
        "costEstimated": True,
        "windowStart": datetime.fromtimestamp(start_s, timezone.utc).isoformat(),
        "windowEnd": datetime.fromtimestamp(start_s + week_s, timezone.utc).isoformat(),
        "overall": overall,
        "byModel": by_model,
        "weeks": weeks,
        "byFolder": [], "byAgentType": [], "timeSeries": [],
        "modelSeries": [], "modelPerformanceSeries": [], "costSeries": [],
    }
    atomic_write(out_path, json.dumps(payload, indent=2) + "\n")
    return payload


def main(argv=None):
    home = os.path.expanduser("~")
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sessions-dir", default=os.path.join(
        home, ".local", "share", "muse", "sessions"))
    ap.add_argument("--state-dir", default=os.path.join(home, ".musebar"))
    ap.add_argument("--limits", default=os.path.join(home, ".musebar", "limits.json"))
    ap.add_argument("--rates", default=os.path.join(home, ".musebar", "rates.json"))
    ap.add_argument("--out", default=os.path.join(home, ".musebar", "latest.json"))
    ap.add_argument("--now", type=float, default=None,
                    help="epoch seconds override (tests)")
    args = ap.parse_args(argv)
    if not os.path.isdir(args.sessions_dir):
        print(f"no Muse session store at {args.sessions_dir}", file=sys.stderr)
        return 1
    payload = collect(args.sessions_dir, args.state_dir, args.limits,
                      args.rates, args.out, args.now or datetime.now(timezone.utc).timestamp())
    o = payload["overall"]
    print(f"muse weekly: {o['totalRequests']} req, "
          f"{o['totalInputTokens'] + o['totalOutputTokens']} tok, "
          f"${o['totalCost']:.2f} est. since {payload['windowStart']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
