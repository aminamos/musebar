#!/bin/bash
# musebar sync: runs omp stats --json (stripping Syncing lines), writes ~/.musebar/latest.json,
# and POSTs to Cloudflare if PUSH_URL secret exists.
set -u
# launchd fires every 60s; jitter 0-180s so effective cadence is a random 1-4 min.
# Set MUSEBAR_JITTER=0 for an immediate manual run.
[ "${MUSEBAR_JITTER:-1}" = "1" ] && sleep $((RANDOM % 181))
OUT="$HOME/.musebar/latest.json"
mkdir -p "$HOME/.musebar"
(command -v omp >/dev/null && omp stats --json 2>&1 || "$HOME/.local/bin/omp" stats --json 2>&1) | grep -v -e '^Syncing' -e '^Synced' > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"

# quota limits (5h / weekly windows) via omp usage
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

# push a small envelope to the musebar-sync worker (D1 + R2)
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
