#!/usr/bin/env bash
# Rescue Tinybird Local when ClickHouse is wedged above its memory budget:
# Ghost Admin → Analytics shows 0 visitors, Ghost logs "Error in Tinybird API
# request … Response code 429", Tinybird's body says MEMORY_LIMIT_EXCEEDED.
# Background + gotchas: docs/analytics-tinybird.md ("Incident 2026-10-29").
#
# Runs ON THE PROD SERVER as `ubuntu`, after `git pull` (the new memory budget +
# system-log TTLs must be in tinybird-local/clickhouse-lowmem.xml):
#   cd ~/lfi && git pull && bash scripts/analytics-recover-prod.sh
#   YES=1          skip the confirmation prompt (no TTY: YES=1 bash … 2>&1 | tee ~/analytics-recover.log)
#   LFI=<dir>      stack checkout (default: the checkout this script lives in)
#   SKIP_PROBE=1   skip the Ghost-side pipe probe in the final check (no ghost container)
#   RESCUE_LIMIT=<bytes>  temporary ClickHouse budget for step 1 (default: tracked + 1 GiB)
#
# What it does (idempotent — re-run if it stops half-way; snapshot in ~/analytics-recover-backup-<ts>/):
#   1. in the RUNNING container: SYSTEM STOP MERGES, hot-raise ClickHouse's
#      max_server_memory_usage (reloadable) so DDL can run again, drop the mark /
#      uncompressed caches, then DROP ClickHouse's own system log tables
#      (system.query_log / query_views_log / part_log — tens of thousands of tiny
#      parts, ~100 KB RAM each; ClickHouse recreates them empty). Ghost's analytics
#      data lives in the `public` database and is not touched.
#   2. rebuild tinybird-local with the repo config and recreate it (stop grace
#      120 s). Only the analytics container restarts: Ghost / MySQL / Caddy stay
#      up; page hits during the ~1-3 min restart are lost (traffic-analytics
#      cannot reach Tinybird), Ghost Admin shows 429 errors meanwhile.
#   3. drop the <log>_0 copies ClickHouse makes at startup when a system log's
#      TTL changed, then verify with scripts/analytics-check.sh
set -euo pipefail

LFI=${LFI:-$(cd "$(dirname "$0")/.." && pwd)}
TS=$(date +%Y%m%d-%H%M)
BK=$HOME/analytics-recover-backup-$TS
COMPOSE=${COMPOSE:-docker compose}
CONF_IN_CONTAINER=/etc/clickhouse-server/config.d/lfi-lowmem.xml
LOG_TABLES="query_views_log query_log part_log"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
ch()   { $COMPOSE exec -T tinybird-local clickhouse-client --format TSV -q "$1"; }
human() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1 B"; }
state() {  # one line: tracked / limit / parts
  printf '  memory tracked %s / budget %s — parts active %s, outdated %s\n' \
    "$(human "$(ch "SELECT value FROM system.metrics WHERE metric = 'MemoryTracking'")")" \
    "$(human "$(ch "SELECT value FROM system.server_settings WHERE name = 'max_server_memory_usage'")")" \
    "$(ch "SELECT value FROM system.metrics WHERE metric = 'PartsActive'")" \
    "$(ch "SELECT value FROM system.metrics WHERE metric = 'PartsOutdated'")"
}
drop_log_tables() {  # drop_log_tables <regex on table name>
  local t
  for t in $(ch "SELECT name FROM system.tables WHERE database = 'system' AND match(name, '$1') ORDER BY name"); do
    printf '  DROP TABLE system.%s SYNC ... ' "$t"
    ch "DROP TABLE IF EXISTS system.$t SYNC" && echo done
  done
}
wait_healthy() {  # wait_healthy <seconds>
  local i cid
  cid=$($COMPOSE ps -q tinybird-local)
  for ((i = 0; i < $1; i += 5)); do
    [[ $(docker inspect "$cid" --format '{{.State.Health.Status}}' 2>/dev/null) == healthy ]] && return 0
    sleep 5
  done
  return 1
}

# ---------------------------------------------------------------- preflight
log "preflight"
[[ -d $LFI/.git ]] || die "$LFI is not the stack checkout"
cd "$LFI"
[[ -f .env ]] || die "$LFI/.env missing"
grep -q '<max_server_memory_usage>2147483648</max_server_memory_usage>' tinybird-local/clickhouse-lowmem.xml \
  || die "tinybird-local/clickhouse-lowmem.xml is the old config — git pull first"
grep -q '<query_views_log>' tinybird-local/clickhouse-lowmem.xml || die "clickhouse-lowmem.xml lacks the system-log TTLs — git pull first"
grep -qx tinybird-local <<<"$($COMPOSE ps --status running --services)" || die "tinybird-local is not running"
[[ -x scripts/analytics-check.sh ]] || die "scripts/analytics-check.sh missing — git pull first"

mkdir -p "$BK"
$COMPOSE exec -T tinybird-local cat "$CONF_IN_CONTAINER" > "$BK/lfi-lowmem.xml.before" 2>/dev/null || true
$COMPOSE logs --no-color --tail 300 tinybird-local > "$BK/tinybird-local.log" 2>&1 || true
limit_before=$(ch "SELECT value FROM system.server_settings WHERE name = 'max_server_memory_usage'")
tracked_before=$(ch "SELECT value FROM system.metrics WHERE metric = 'MemoryTracking'")
[[ $limit_before =~ ^[0-9]+$ && $tracked_before =~ ^[0-9]+$ ]] || die "cannot read ClickHouse state: $limit_before / $tracked_before"
{ echo "limit_before=$limit_before tracked_before=$tracked_before"; ch "SELECT name, value, last_error_time FROM system.errors WHERE name IN ('MEMORY_LIMIT_EXCEEDED','TOO_MANY_PARTS')"; } > "$BK/state-before.txt" 2>&1 || true
state
echo "  error counters: $(tr '\n\t' '  ' < "$BK/state-before.txt")"
echo "  snapshot: $BK"
(( tracked_before >= limit_before )) || warn "ClickHouse is currently UNDER its budget — this script still cleans the system logs and restarts the container"
if [[ ${YES:-0} != 1 ]]; then
  [[ -t 0 ]] || die "no TTY — run with YES=1 to skip the confirmation"
  read -r -p "Proceed? tinybird-local will be cleaned and restarted (analytics only; the site stays up). [y/N] " a
  [[ $a == y || $a == Y ]] || die "aborted"
fi

# ---------------------------------------------------------------- 1. unwedge the running ClickHouse
log "1/3 unwedge the running ClickHouse"
ch "SYSTEM STOP MERGES" || warn "SYSTEM STOP MERGES failed (continuing)"
rescue=${RESCUE_LIMIT:-$(( tracked_before + 1024 * 1024 * 1024 ))}   # 1 GiB above what is tracked now: enough for the DDL below
(( rescue > limit_before )) || rescue=$limit_before
if (( rescue > limit_before )); then
  echo "  hot-raising max_server_memory_usage $(human "$limit_before") -> $(human "$rescue") in the running container"
  $COMPOSE exec -T tinybird-local sed -i -E "s#<max_server_memory_usage>[0-9]+</max_server_memory_usage>#<max_server_memory_usage>$rescue</max_server_memory_usage>#" "$CONF_IN_CONTAINER"
  $COMPOSE exec -T tinybird-local grep -q "<max_server_memory_usage>$rescue<" "$CONF_IN_CONTAINER" || die "could not patch $CONF_IN_CONTAINER in the container"
  for i in $(seq 1 15); do   # ClickHouse re-reads config.d every 2 s
    [[ $(ch "SELECT value FROM system.server_settings WHERE name = 'max_server_memory_usage'") == "$rescue" ]] && break
    sleep 2
    (( i < 15 )) || die "ClickHouse did not reload the raised memory limit within 30 s"
  done
  echo "  reloaded."
fi
ch "SYSTEM DROP MARK CACHE" || warn "SYSTEM DROP MARK CACHE failed"
ch "SYSTEM DROP UNCOMPRESSED CACHE" || warn "SYSTEM DROP UNCOMPRESSED CACHE failed"
drop_log_tables '^(query_log|part_log|query_views_log)(_[0-9]+)?$'
state

# ---------------------------------------------------------------- 2. rebuild + recreate with the repo config
log "2/3 rebuild tinybird-local with the repo config and recreate it"
$COMPOSE build tinybird-local
$COMPOSE stop -t 120 tinybird-local
$COMPOSE up -d --no-deps tinybird-local
echo "  waiting for the healthcheck (first flushes + Tinybird API, up to 10 min) ..."
wait_healthy 600 || { $COMPOSE logs --no-color --tail 40 tinybird-local; die "tinybird-local not healthy after 10 min"; }
[[ $(ch "SELECT value FROM system.server_settings WHERE name = 'max_server_memory_usage'") == 2147483648 ]] || die "new container does not run the repo config (max_server_memory_usage != 2 GiB)"
echo "  up, with the 2 GiB budget."

# ---------------------------------------------------------------- 3. leftovers + verification
log "3/3 drop renamed system-log copies, then verify"
# A system log whose TTL changed is renamed <name>_0 at its first flush after
# start and recreated — give the flushes (7.5 s) a moment, then drop the copies.
sleep 20
drop_log_tables '^(query_log|part_log|query_views_log)_[0-9]+$'
echo "  query_log TTL now: $(ch "SELECT extract(create_table_query, 'TTL [^S]+') FROM system.tables WHERE database = 'system' AND name = 'query_log'" || echo '(table not created yet — appears at its first flush)')"
state
echo
SKIP_PROBE=${SKIP_PROBE:-0} scripts/analytics-check.sh || { warn "verification failed — see above (snapshot: $BK)"; exit 1; }
echo
log "DONE. Ghost Admin → Analytics should show visitors again (reload the page; Ghost caches pipe results for a few minutes)."
echo "  snapshot of the pre-recovery state: $BK"
