# MuseBar

A CodexBar, but just for [Muse](https://codexbar.app/)-style quota tracking of **Muse** — menu bar + draggable desktop widget on macOS, iOS widgets, and an ESP32 bus board, all fed from one Cloudflare backend so every device reads the same numbers from anywhere.

## What it shows

- **Requests / tokens / cost** — from `omp stats --json` (your local Muse session store).
- **5-hour & weekly quota windows** — `% left` + reset countdowns, from `omp usage --provider muse-code` (Muse Code Max Usage).
- **Per-model breakdown** — requests, tokens, cost per model.
- **Bus departures** — live E Line departures (Metro Transit NexTrip), stop-configurable.

## Architecture

```
Mac (launchd, every 1-4 min, jittered)
  sync-muse.sh ── omp stats --json + omp usage --json
        │  POST /push  (Bearer secret)
        ▼
musebar-sync Worker ──► D1 (snapshots + per-model rows)
                   └──► R2 (raw JSON snapshots)
        │  GET /api/usage   (public read)
        ▼
macOS MuseBar.app (menu bar + WidgetKit) · iOS widgets · ESP32 (via ghost-bus worker)
```

- `sync-muse.sh` + `codes.amos.musebar-sync.plist` — the Mac-side collector. Random 1–4 min cadence (60s launchd tick + 0–180s jitter).
- `cloudflare/` — the `musebar-sync` worker: `POST /push` (secret-guarded), `GET /api/usage`, `GET /api/history`. D1 schema in `schema.sql`.
- `native/` — Swift. `project.yml` (xcodegen) generates the Xcode project:
  - `App/` — macOS menu-bar app (`⚡ 299 · 5h 95% · wk 62%`), auto-refreshes every 60s.
  - `Widgets/` — macOS desktop WidgetKit widget (drag it anywhere).
  - `iOSApp/` + `iOSWidgets/` — iOS app + Muse/bus widgets reading the same two public endpoints.
- `esp32/bus-board/` — Arduino sketch: polls `GET /api/departures?stop=<id>&route=E` every 60s, renders next 2 departures on an SSD1306 OLED.
- Bus data comes from a `GET /api/departures` endpoint on a [ghost-bus-tracker](https://github.com/aminamos/ghost-bus-tracker) worker, proxying Metro Transit's NexTrip API.

## Setup

Prereqs: [`omp`](https://github.com/aminamos) CLI authenticated with Muse, Xcode + [xcodegen](https://github.com/yonaskolb/XcodeGen), [wrangler](https://developers.cloudflare.com/workers/wrangler/) logged in.

```bash
# 1. Cloud (one-time)
cd cloudflare
wrangler d1 create musebar-stats        # put the id in wrangler.jsonc
wrangler r2 bucket create musebar-snapshots
wrangler d1 execute musebar-stats --remote --file schema.sql
wrangler secret put PUSH_SECRET         # save the same value to ~/.musebar/push_secret (chmod 600)
wrangler deploy                          # note your *.workers.dev URL

# 2. Mac collector
mkdir -p ~/.musebar && cp codes.amos.musebar-sync.plist ~/Library/LaunchAgents/
# set PUSH_URL in sync-muse.sh to https://<your-worker>.workers.dev/push
launchctl load ~/Library/LaunchAgents/codes.amos.musebar-sync.plist

# 3. Native app + widgets
cd native && xcodegen generate && open MuseBar.xcodeproj
# set the endpoint URLs in iOSApp/Models.swift, build & run MuseBar
# right-click desktop → Edit Widgets → add "Muse Usage"
```

## Notes

- Quota percentages are Muse's own (`usedFraction` from the provider API); MuseBar never estimates them.
- The push secret lives only in `~/.musebar/push_secret` and the worker's `PUSH_SECRET` — never in this repo.
- Personal endpoints/IDs in this repo are placeholders (`YOUR-WORKER.workers.dev`, `REPLACE_WITH_YOUR_D1_ID`) — drop in your own.

## License

MIT
