#!/usr/bin/env bash
# Health check of Ghost's self-hosted web analytics (Tinybird Local). Read-only.
#
#   scripts/analytics-check.sh        from the repo root (needs .env)
#   make analytics-check
#
# Answers "Ghost Admin → Analytics shows 0 visitors — is that real?":
#   1. ClickHouse inside tinybird-local: memory tracked vs its budget
#      (max_server_memory_usage), parts, error counters, running merges. Over
#      budget = every query and every merge fails with MEMORY_LIMIT_EXCEEDED,
#      Tinybird answers HTTP 429 and Ghost shows zeros (docs/analytics-tinybird.md).
#   2. the api_kpis pipe queried exactly like Ghost does: through the public URL
#      (Caddy) with a JWT signed in the ghost container — prints the last 7 days.
#
# Env: SKIP_PROBE=1 (no ghost container), SITE_UUID=<uuid> (private site: the
# tracker tag cannot be read from the HTML), PROBE_ENDPOINT=<url> (default: the
# ghost container's tinybird__stats__endpoint, or http://caddy/.ghost/tinybird
# when GHOST_URL is localhost), COMPOSE="docker compose -f ...", ENV_FILE=path
# Exit 1 when ClickHouse is over budget / unqueryable or the pipe probe fails.
set -euo pipefail

cd "$(dirname "$0")/.."
COMPOSE=${COMPOSE:-docker compose}
ENV_FILE=${ENV_FILE:-.env}
[[ -f $ENV_FILE ]] || { echo "error: $ENV_FILE missing" >&2; exit 1; }
GHOST_URL=$(grep -E '^GHOST_URL=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)

log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*"; }
ch()   { $COMPOSE exec -T tinybird-local clickhouse-client --format TSV -q "$1" 2>&1 || true; }   # errors land in the output, never abort the check
human() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1 B"; }

ok=1
running=$($COMPOSE ps --status running --services 2>/dev/null || true)
grep -qx tinybird-local <<<"$running" || { echo "error: tinybird-local is not running ($COMPOSE ps)" >&2; exit 1; }

# ---------------------------------------------------------------- 1. ClickHouse
log "ClickHouse (inside tinybird-local)"
limit=$(ch "SELECT value FROM system.server_settings WHERE name = 'max_server_memory_usage'")
tracked=$(ch "SELECT value FROM system.metrics WHERE metric = 'MemoryTracking'")
resident=$(ch "SELECT toUInt64(value) FROM system.asynchronous_metrics WHERE metric = 'MemoryResident'")
if ! [[ $limit =~ ^[0-9]+$ && $tracked =~ ^[0-9]+$ ]]; then
  echo "  cannot query ClickHouse: $limit $tracked"; ok=0
else
  pct=$(( tracked * 100 / limit ))
  printf '  memory tracked  %-12s of budget %-10s (%d%%)   resident %s\n' "$(human "$tracked")" "$(human "$limit")" "$pct" "$(human "${resident:-0}")"
  if (( tracked >= limit )); then
    echo "  OVER BUDGET: queries and merges fail with MEMORY_LIMIT_EXCEEDED -> run scripts/analytics-recover-prod.sh"; ok=0
  elif (( pct >= 85 )); then
    warn "memory tracked is at ${pct}% of the budget — heading for MEMORY_LIMIT_EXCEEDED"
  fi
fi
printf '  parts active %s, outdated %s, merges running %s\n' \
  "$(ch "SELECT value FROM system.metrics WHERE metric = 'PartsActive'")" \
  "$(ch "SELECT value FROM system.metrics WHERE metric = 'PartsOutdated'")" \
  "$(ch "SELECT value FROM system.metrics WHERE metric = 'Merge'")"
# An aggregation over system.parts is the canary: it is the first thing to die
# when the budget is exhausted (the scalar reads above still work then).
top=$(ch "SELECT database || '.' || table AS table, count() AS parts, formatReadableSize(sum(bytes_on_disk)) AS on_disk FROM system.parts WHERE active GROUP BY table ORDER BY parts DESC LIMIT 5 FORMAT PrettyCompactNoEscapes")
if grep -q 'MEMORY_LIMIT_EXCEEDED' <<<"$top"; then
  echo "  system.parts aggregation FAILED: $(grep -oE '\(total\) memory limit exceeded.*maximum: [0-9.]+ [A-Za-z]+' <<<"$top" | head -1)"; ok=0
else
  echo "  tables with most parts (system.* are ClickHouse's own logs, public.* Tinybird data):"
  sed 's/^/    /' <<<"$top"
fi
errs=$(ch "SELECT name, value, last_error_time FROM system.errors WHERE name IN ('MEMORY_LIMIT_EXCEEDED','TOO_MANY_PARTS') ORDER BY name FORMAT PrettyCompactNoEscapes")
[[ -n $errs ]] && { echo "  error counters since ClickHouse start:"; sed 's/^/    /' <<<"$errs"; }
leftovers=$(ch "SELECT name FROM system.tables WHERE database = 'system' AND match(name, '^(query_log|part_log|query_views_log)_[0-9]+\$')")
[[ -n $leftovers ]] && warn "renamed system log copies to drop (DROP TABLE system.<name> SYNC): $(tr '\n' ' ' <<<"$leftovers")"

# ---------------------------------------------------------------- 2. pipe probe
if [[ ${SKIP_PROBE:-0} == 1 ]]; then
  log "pipe probe skipped (SKIP_PROBE=1)"
elif ! grep -qx ghost <<<"$running"; then
  warn "ghost is not running — pipe probe skipped"
else
  log "api_kpis through Caddy, as Ghost queries it (last 7 days)"
  probe_endpoint=${PROBE_ENDPOINT:-}
  if [[ -z $probe_endpoint && $GHOST_URL =~ ^https?://(localhost|127\.0\.0\.1)(:[0-9]+)?/?$ ]]; then
    probe_endpoint=http://caddy/.ghost/tinybird   # the public URL is not reachable from inside the ghost container locally
  fi
  if ! $COMPOSE exec -T -e PROBE_ENDPOINT="$probe_endpoint" -e SITE_UUID="${SITE_UUID:-}" -e PROBE_TZ="${PROBE_TZ:-Europe/Paris}" ghost node - <<'JS'
const jwt = require('/var/lib/ghost/current/node_modules/jsonwebtoken');
const ws = process.env.tinybird__workspaceId;
const adminToken = process.env.tinybird__adminToken;
const endpoint = process.env.PROBE_ENDPOINT || process.env.tinybird__stats__endpoint;
const fail = (msg) => { console.log('  FAIL: ' + msg); process.exit(1); };
if (!ws || !adminToken || !endpoint) fail('tinybird__workspaceId / tinybird__adminToken / tinybird__stats__endpoint not set on the ghost container (run scripts/analytics-init.sh)');
(async () => {
    let siteUuid = process.env.SITE_UUID;
    if (!siteUuid) {
        // Ghost answers plain HTTP on 2368 with a 301 to its https url unless the
        // request looks like it came through the TLS proxy.
        const proto = new URL(process.env.url || 'http://localhost').protocol.replace(':', '');
        const page = await fetch('http://127.0.0.1:2368/', {redirect: 'manual', headers: {'User-Agent': 'analytics-check', 'X-Forwarded-Proto': proto}});
        const html = await page.text();
        const m = html.match(/tb_site_uuid="([^"]+)"/);
        if (!m) fail(`no ghost-stats tracker tag in the site HTML (HTTP ${page.status}; Settings → Analytics → Web analytics off? private site? then pass SITE_UUID=...)`);
        siteUuid = m[1];
    }
    const token = jwt.sign({
        workspace_id: ws, name: 'analytics-check', exp: Math.floor(Date.now() / 1000) + 300,
        scopes: [{type: 'PIPES:READ', resource: 'api_kpis', fixed_params: {site_uuid: siteUuid}}]
    }, adminToken, {noTimestamp: true});
    const day = (d) => d.toISOString().slice(0, 10);
    const url = `${endpoint}/v0/pipes/api_kpis.json?site_uuid=${siteUuid}&date_from=${day(new Date(Date.now() - 6 * 864e5))}&date_to=${day(new Date())}&timezone=${encodeURIComponent(process.env.PROBE_TZ)}`;
    const t0 = Date.now();
    const r = await fetch(url, {headers: {Authorization: `Bearer ${token}`}});
    const body = await r.text();
    console.log(`  GET ${url.replace(/site_uuid=[^&]+/, 'site_uuid=…')}\n  -> HTTP ${r.status} in ${Date.now() - t0} ms`);
    if (r.status !== 200) fail(body.slice(0, 500));
    let data;
    try { data = JSON.parse(body).data; } catch (e) { fail('not JSON: ' + body.slice(0, 200)); }
    if (!Array.isArray(data)) fail('no data array: ' + body.slice(0, 200));
    if (!data.length) { console.log('  200 OK, no rows for the period (no visits recorded)'); return; }
    const cols = Object.keys(data[0]);
    console.log('  ' + cols.map(c => c.padStart(14)).join(''));
    for (const row of data) console.log('  ' + cols.map(c => String(row[c] ?? '').padStart(14)).join(''));
})().catch(e => fail(e.message));
JS
  then ok=0; fi
fi

echo
if (( ok )); then log "analytics OK"; else warn "analytics NOT healthy — see above (runbook: docs/analytics-tinybird.md)"; exit 1; fi
