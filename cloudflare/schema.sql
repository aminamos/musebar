-- MuseBar stats store: one row per Mac push, plus per-model breakdown.
CREATE TABLE IF NOT EXISTS snapshots (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  collected_at TEXT NOT NULL,
  pushed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  hostname TEXT NOT NULL DEFAULT '',
  total_requests INTEGER NOT NULL DEFAULT 0,
  successful_requests INTEGER NOT NULL DEFAULT 0,
  failed_requests INTEGER NOT NULL DEFAULT 0,
  total_input_tokens INTEGER NOT NULL DEFAULT 0,
  total_output_tokens INTEGER NOT NULL DEFAULT 0,
  total_cache_read_tokens INTEGER NOT NULL DEFAULT 0,
  total_cache_write_tokens INTEGER NOT NULL DEFAULT 0,
  cache_rate REAL,
  cache_savings REAL,
  total_cost REAL,
  total_premium_requests INTEGER NOT NULL DEFAULT 0,
  avg_duration_ms REAL,
  avg_ttft_ms REAL,
  avg_tokens_per_sec REAL,
  raw_r2_key TEXT NOT NULL DEFAULT '',
  limits_json TEXT NOT NULL DEFAULT '[]'
);
CREATE INDEX IF NOT EXISTS idx_snapshots_host_time ON snapshots (hostname, collected_at DESC);

CREATE TABLE IF NOT EXISTS by_model (
  snapshot_id INTEGER NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
  model TEXT NOT NULL,
  provider TEXT NOT NULL DEFAULT '',
  total_requests INTEGER NOT NULL DEFAULT 0,
  total_input_tokens INTEGER NOT NULL DEFAULT 0,
  total_output_tokens INTEGER NOT NULL DEFAULT 0,
  total_cache_read_tokens INTEGER NOT NULL DEFAULT 0,
  total_cache_write_tokens INTEGER NOT NULL DEFAULT 0,
  total_cost REAL,
  PRIMARY KEY (snapshot_id, model)
);

-- One row per (host, weekly window): final totals for current + previous
-- weeks, upserted on every push so apps can page back through history.
-- Apply to an existing DB with: wrangler d1 execute musebar-stats --remote --file schema.sql
CREATE TABLE IF NOT EXISTS weeks (
  hostname TEXT NOT NULL DEFAULT '',
  window_start TEXT NOT NULL,
  window_end TEXT NOT NULL DEFAULT '',
  total_requests INTEGER NOT NULL DEFAULT 0,
  total_input_tokens INTEGER NOT NULL DEFAULT 0,
  total_output_tokens INTEGER NOT NULL DEFAULT 0,
  total_cost REAL,
  by_model_json TEXT NOT NULL DEFAULT '[]',
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  PRIMARY KEY (hostname, window_start)
);

CREATE VIEW IF NOT EXISTS latest AS
SELECT * FROM snapshots ORDER BY collected_at DESC LIMIT 1;
