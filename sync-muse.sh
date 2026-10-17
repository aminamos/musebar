#!/bin/bash
# musebar sync: aggregates Muse usage for the current weekly window
# (Sun 7pm Central -> now) into ~/.musebar/latest.json via collect-muse.py,
# fetches quota limits, and POSTs to Cloudflare if PUSH_URL secret exists.
# Falls back to `omp stats --json` if the Muse session store is missing.
set -u
# launchd fires every 60s; jitter 0-180s so effective cadence is a random 1-4 min.
# Set MUSEBAR_JITTER=0 for an immediate manual run.
[ "${MUSEBAR_JITTER:-1}" = "1" ] && sleep $((RANDOM % 181))
mkdir -p "$HOME/.musebar"
# Single-flight: a first (full-history) scan can outlast the launchd tick.
LOCK="$HOME/.musebar/sync.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  # Reap a stale lock (holder killed mid-run) after 10 minutes.
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null && mkdir "$LOCK" 2>/dev/null || { echo "sync already running; skipping" >&2; exit 0; }
  else
    echo "sync already running; skipping" >&2; exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
OUT="$HOME/.musebar/latest.json"
DIR="$(cd "$(dirname "$0")" && pwd)"

# quota limits (5h / weekly windows) via omp usage; fetched first because
# collect-muse.py derives the weekly window start from the 1w limit.
(command -v omp >/dev/null && omp usage --provider muse-code --json 2>/dev/null || "$HOME/.local/bin/omp" usage --provider muse-code --json 2>/dev/null) | python3 -c "
import sys,json,datetime
txt=sys.stdin.read(); i=txt.find('{')
limits=[]
if i>=0:
    d=json.loads(txt[i:])
    for r in d.get('reports',[]):
        for l in r.get('limits',[]):
            limits.append({'id':l.get('id'),'label':l.get('label'),
                           'usedFraction':(l.get('amount') or {}).get('usedFraction'),
                           'remainingFraction':(l.get('amount') or {}).get('remainingFraction'),
                           'resetsAt':(l.get('window') or {}).get('resetsAt'),
                           'durationMs':(l.get('window') or {}).get('durationMs')})
json.dump({'fetchedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'limits':limits},open('$HOME/.musebar/limits.json','w'),indent=2)
" 2>/dev/null || echo '{"fetchedAt":null,"limits":[]}' > "$HOME/.musebar/limits.json"

# requests / tokens / estimated cost from Muse session logs (weekly window)
if ! python3 "$DIR/collect-muse.py"; then
  echo "collect-muse.py failed; falling back to omp stats" >&2
  (command -v omp >/dev/null && omp stats --json 2>&1 || "$HOME/.local/bin/omp" stats --json 2>&1) | grep -v -e '^Syncing' -e '^Synced' > "$OUT.tmp"
  mv "$OUT.tmp" "$OUT"
fi

# push a small envelope to the musebar-sync worker (D1 + R2)
PUSH_URL="${PUSH_URL:-}"
if [ -z "$PUSH_URL" ] && [ -f "$HOME/.musebar/push_url" ]; then PUSH_URL="$(cat "$HOME/.musebar/push_url")"; fi
PUSH_URL="${PUSH_URL:-https://YOUR-WORKER.workers.dev/push}"
PUSH_SECRET="${PUSH_SECRET:-}"
if [ -z "$PUSH_SECRET" ] && [ -f "$HOME/.musebar/push_secret" ]; then PUSH_SECRET="$(cat "$HOME/.musebar/push_secret")"; fi
if [ -n "$PUSH_SECRET" ]; then
  python3 - "$OUT" "$HOME/.musebar/limits.json" <<'EOF' > "$HOME/.musebar/push.json"
import json,sys,datetime,socket
src=json.load(open(sys.argv[1]))
try: lim=json.load(open(sys.argv[2]))
except Exception: lim={}
print(json.dumps({"collectedAt":datetime.datetime.now(datetime.timezone.utc).isoformat(),
  "hostname":socket.gethostname().split(".")[0],
  "omp":{"overall":src.get("overall",{}),"byModel":src.get("byModel",[]),"limits":lim.get("limits",[]),"limitsFetchedAt":lim.get("fetchedAt")}}))
EOF
  curl -fsS -m 20 -X POST -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $PUSH_SECRET" \
    --data @"$HOME/.musebar/push.json" "$PUSH_URL" || echo "push failed" >&2
fi
echo "wrote $OUT"
