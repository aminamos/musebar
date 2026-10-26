/**
 * musebar-sync worker: receives `omp stats --json` pushes from the Mac,
 * stores the raw payload in R2 plus a queryable summary in D1, and serves
 * the latest stats to the macOS / iOS widgets. Not yet deployed.
 *
 * Push:    POST /push  (Authorization: Bearer <PUSH_SECRET>)
 * Reads:   GET /api/usage, GET /api/history?limit=&host=, GET /health
 */

function json(data, status = 200, cacheMaxAge = 0) {
  const headers = { "Content-Type": "application/json" };
  if (cacheMaxAge > 0) headers["Cache-Control"] = `public, max-age=${cacheMaxAge}`;
  return new Response(JSON.stringify(data), { status, headers });
}

function unauthorized() {
  return json({ ok: false, error: "unauthorized" }, 401);
}

// Constant-time bearer comparison so the secret can't be probed byte-by-byte.
function bearerOk(request, secret) {
  const header = request.headers.get("Authorization") || "";
  const prefix = "Bearer ";
  if (!header.startsWith(prefix) || !secret) return false;
  const a = header.slice(prefix.length);
  const b = secret;
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function upsertWeeks(env, hostname, weeks) {
  if (!Array.isArray(weeks) || !weeks.length) return;
  const batch = weeks.filter((w) => w && w.windowStart).map((w) => {
    const o = w.overall || {};
    return env.STATS_DB.prepare(
      `INSERT INTO weeks (hostname, window_start, window_end, total_requests,
        total_input_tokens, total_output_tokens, total_cost, by_model_json, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))
       ON CONFLICT(hostname, window_start) DO UPDATE SET
        window_end = excluded.window_end,
        total_requests = excluded.total_requests,
        total_input_tokens = excluded.total_input_tokens,
        total_output_tokens = excluded.total_output_tokens,
        total_cost = excluded.total_cost,
        by_model_json = excluded.by_model_json,
        updated_at = excluded.updated_at`
    ).bind(
      hostname, String(w.windowStart), String(w.windowEnd || ""),
      o.totalRequests || 0, o.totalInputTokens || 0, o.totalOutputTokens || 0,
      o.totalCost ?? null, JSON.stringify(Array.isArray(w.byModel) ? w.byModel : [])
    );
  });
  if (batch.length) await env.STATS_DB.batch(batch);
}

async function handlePush(request, env) {
  if (!bearerOk(request, env.PUSH_SECRET)) return unauthorized();
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ ok: false, error: "invalid_json" }, 400);
  }
  const collectedAt = body.collectedAt || new Date().toISOString();
  const hostname = String(body.hostname || "unknown").replace(/[^a-zA-Z0-9._-]/g, "");
  const omp = body.omp || body; // accept raw `omp stats --json` too
  const overall = omp.overall || {};
  const byModel = Array.isArray(omp.byModel) ? omp.byModel : [];
  // Record weekly history even when the current week is unchanged (the
  // dedup early-return below would otherwise drop a rebuilt history).
  try { await upsertWeeks(env, hostname, omp.weeks); } catch { /* weeks table may not exist pre-migration; non-fatal */ }

  // Skip redundant writes when nothing changed since the last push.
  const prev = await env.STATS_DB.prepare(
    "SELECT total_requests, total_input_tokens, total_output_tokens FROM snapshots WHERE hostname = ? ORDER BY collected_at DESC LIMIT 1"
  ).bind(hostname).first();
  if (
    prev &&
    prev.total_requests === (overall.totalRequests || 0) &&
    prev.total_input_tokens === (overall.totalInputTokens || 0) &&
    prev.total_output_tokens === (overall.totalOutputTokens || 0)
  ) {
    // Stats unchanged, but quota windows move on their own — always record them.
    try {
      await env.STATS_DB.prepare(
        "UPDATE snapshots SET limits_json = ? WHERE id = (SELECT id FROM snapshots WHERE hostname = ? ORDER BY collected_at DESC LIMIT 1)"
      ).bind(JSON.stringify(Array.isArray(omp.limits) ? omp.limits : []), hostname).run();
    } catch { /* column may not exist pre-migration; non-fatal */ }
    return json({ ok: true, skipped: true, collectedAt });
  }

  const r2Key = `stats/${hostname}/${collectedAt}.json`;
  const stored = { collectedAt, pushedAt: new Date().toISOString(), hostname, omp: { overall, byModel, weeks: Array.isArray(omp.weeks) ? omp.weeks : [], limits: Array.isArray(omp.limits) ? omp.limits : [] } };
  try {
    await env.SNAPSHOT_BUCKET.put(r2Key, JSON.stringify(stored), {
      httpMetadata: { contentType: "application/json" },
    });
    await env.SNAPSHOT_BUCKET.put(`stats/${hostname}/latest.json`, JSON.stringify(stored), {
      httpMetadata: { contentType: "application/json" },
    });
  } catch (e) {
    return json({ ok: false, error: "r2_write_failed", detail: String(e) }, 500);
  }

  try {
    const res = await env.STATS_DB.prepare(
      `INSERT INTO snapshots (collected_at, hostname, total_requests, successful_requests,
        failed_requests, total_input_tokens, total_output_tokens, total_cache_read_tokens,
        total_cache_write_tokens, cache_rate, cache_savings, total_cost,
        total_premium_requests, avg_duration_ms, avg_ttft_ms, avg_tokens_per_sec, raw_r2_key, limits_json)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    ).bind(
      collectedAt, hostname,
      overall.totalRequests || 0, overall.successfulRequests || 0, overall.failedRequests || 0,
      overall.totalInputTokens || 0, overall.totalOutputTokens || 0,
      overall.totalCacheReadTokens || 0, overall.totalCacheWriteTokens || 0,
      overall.cacheRate ?? null, overall.cacheSavings ?? null, overall.totalCost ?? null,
      overall.totalPremiumRequests || 0,
      overall.avgDuration ?? null, overall.avgTtft ?? null, overall.avgTokensPerSecond ?? null,
      r2Key, JSON.stringify(Array.isArray(omp.limits) ? omp.limits : [])
    ).run();
    const snapshotId = res.meta.last_row_id;
    const batch = byModel.map((m) =>
      env.STATS_DB.prepare(
        `INSERT INTO by_model (snapshot_id, model, provider, total_requests,
          total_input_tokens, total_output_tokens, total_cache_read_tokens,
          total_cache_write_tokens, total_cost)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
      ).bind(
        snapshotId, String(m.model || "unknown"), String(m.provider || ""),
        m.totalRequests || 0, m.totalInputTokens || 0, m.totalOutputTokens || 0,
        m.totalCacheReadTokens || 0, m.totalCacheWriteTokens || 0, m.totalCost ?? null
      )
    );
    if (batch.length) await env.STATS_DB.batch(batch);
    return json({ ok: true, id: snapshotId, collectedAt });
  } catch (e) {
    return json({ ok: false, error: "d1_write_failed", detail: String(e) }, 500);
  }
}

async function handleUsage(request, env) {
  const row = await env.STATS_DB.prepare(
    "SELECT * FROM latest"
  ).first();
  if (!row) {
    // Fall back to R2 in case D1 was recreated but snapshots remain.
    const obj = await env.SNAPSHOT_BUCKET.get("stats/mac/latest.json");
    if (!obj) return json({ ok: false, error: "no_data" }, 404);
    return json(await obj.json(), 200, 600);
  }
  const models = await env.STATS_DB.prepare(
    "SELECT model, provider, total_requests AS requests, total_input_tokens AS inTok, total_output_tokens AS outTok, total_cost AS cost FROM by_model WHERE snapshot_id = ?"
  ).bind(row.id).all();
  return json({
    collectedAt: row.collected_at,
    pushedAt: row.pushed_at,
    hostname: row.hostname,
    overall: {
      requests: row.total_requests,
      success: row.successful_requests,
      failed: row.failed_requests,
      inTok: row.total_input_tokens,
      outTok: row.total_output_tokens,
      cacheRead: row.total_cache_read_tokens,
      cacheWrite: row.total_cache_write_tokens,
      cacheRate: row.cache_rate,
      totalCost: row.total_cost,
      premium: row.total_premium_requests,
    },
    byModel: (models.results || []),
    limits: (() => { try { return JSON.parse(row.limits_json || "[]"); } catch { return []; } })(),
    r2Key: row.raw_r2_key,
  }, 200, 600);
}

async function handleHistory(request, env) {
  const url = new URL(request.url);
  const limit = Math.min(Math.max(parseInt(url.searchParams.get("limit") || "30", 10) || 30, 1), 90);
  const host = url.searchParams.get("host");
  const rows = host
    ? await env.STATS_DB.prepare(
        "SELECT collected_at, hostname, total_requests, total_input_tokens, total_output_tokens, total_cost FROM snapshots WHERE hostname = ? ORDER BY collected_at DESC LIMIT ?"
      ).bind(host, limit).all()
    : await env.STATS_DB.prepare(
        "SELECT collected_at, hostname, total_requests, total_input_tokens, total_output_tokens, total_cost FROM snapshots ORDER BY collected_at DESC LIMIT ?"
      ).bind(limit).all();
  return json({ points: rows.results || [] }, 200, 300);
}

async function handleWeeks(request, env) {
  const url = new URL(request.url);
  const limit = Math.min(Math.max(parseInt(url.searchParams.get("limit") || "26", 10) || 26, 1), 52);
  const host = url.searchParams.get("host");
  const rows = host
    ? await env.STATS_DB.prepare(
        "SELECT * FROM weeks WHERE hostname = ? ORDER BY window_start DESC LIMIT ?"
      ).bind(host, limit).all()
    : await env.STATS_DB.prepare(
        "SELECT * FROM weeks WHERE hostname = (SELECT hostname FROM latest) ORDER BY window_start DESC LIMIT ?"
      ).bind(limit).all();
  const weeks = (rows.results || []).map((r) => ({
    windowStart: r.window_start,
    windowEnd: r.window_end,
    totalRequests: r.total_requests,
    totalInputTokens: r.total_input_tokens,
    totalOutputTokens: r.total_output_tokens,
    totalCost: r.total_cost,
    byModel: (() => { try { return JSON.parse(r.by_model_json || "[]"); } catch { return []; } })(),
  }));
  return json({ weeks }, 200, 300);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/push") return handlePush(request, env);
    if (request.method === "GET" && url.pathname === "/api/usage") return handleUsage(request, env);
    if (request.method === "GET" && url.pathname === "/api/weeks") return handleWeeks(request, env);
    if (request.method === "GET" && url.pathname === "/api/history") return handleHistory(request, env);
    if (request.method === "GET" && (url.pathname === "/health" || url.pathname === "/api/health")) {
      return json({ ok: true, worker: "musebar-sync" });
    }
    return json({ ok: false, error: "not_found" }, 404);
  },
};
