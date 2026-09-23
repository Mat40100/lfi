#!/usr/bin/env bash
# Production rollout of Ghost's self-hosted web analytics (Tinybird Local) and
# removal of Umami (compromised on 2026-09-23 — cryptominer via the Next.js RCE).
#
# Runs ON THE PROD SERVER as `ubuntu`:   bash ~/analytics-deploy-prod.sh
#   YES=1              skip the confirmation prompt (no TTY:  YES=1 bash ~/analytics-deploy-prod.sh 2>&1 | tee ~/analytics-deploy.log)
#   SKIP_UMAMI=1       don't touch Umami (container / MySQL user / Ghost snippet)
#   DRY_CADDY=<file>   only patch that Caddyfile copy and validate it, then exit (local test)
#
# What it does (idempotent; backups in ~/analytics-deploy-backup-<ts>/):
#   1. Umami: save forensic copies (logs, diff, dropped files), stop + remove the
#      container and image, DROP the leaked `umami` MySQL user (the database is kept —
#      command to drop it is printed), strip the Umami <script> from Ghost's code injection
#   2. ~/lfi: git pull (server-only Caddyfile edits are kept), UMAMI_* dropped from .env
#   3. Caddyfile: remove the :8080 Umami block, add the /.ghost/analytics + /.ghost/tinybird
#      routes, validate with `caddy validate`
#   4. build + start tinybird-local / tinybird-deploy / traffic-analytics, run
#      scripts/analytics-init.sh (tokens -> .env, recreates ghost + traffic-analytics),
#      recreate caddy
#   5. verification (tracker in HTML, page hit 202, pipes 200 via Caddy, 403 guards) + summary
set -euo pipefail

LFI=$HOME/lfi
CF=$LFI/caddy/Caddyfile
TS=$(date +%Y%m%d-%H%M)
BK=$HOME/analytics-deploy-backup-$TS
SITE_URL=https://adour-en-commun.fr

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
http_code() { curl -s -o /dev/null -m 20 -w '%{http_code}' "$@" 2>/dev/null || true; }   # curl prints 000 itself on connect failure
mysql_root() {  # SQL on stdin, executed as root with the password from the container env
  (cd "$LFI" && docker compose exec -T mysql sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --default-character-set=utf8mb4 "$@"' -- "$@")
}

# ---------------------------------------------------------------- Caddyfile patch
ANALYTICS_ROUTES=$(cat <<'CADDY'
    # --- Web analytics (Tinybird, self-hosted) ---------------------------------
    # Page hits: Ghost's ghost-stats.js POSTs to /.ghost/analytics/api/v1/page_hit
    # -> prefix stripped -> traffic-analytics (bot filter, UA parsing, salted
    # user signature) -> Tinybird Local /v0/events.
    handle_path /.ghost/analytics/* {
        reverse_proxy traffic-analytics:3000
    }
    # Stats: Ghost Admin (browser, JWT signed by Ghost) and Ghost itself read
    # Tinybird pipes at /.ghost/tinybird/v0/pipes/<pipe>.json. Only the read-only
    # pipes API is forwarded; tokens / SQL / ingestion stay internal.
    handle /.ghost/tinybird/v0/pipes/* {
        uri strip_prefix /.ghost/tinybird
        reverse_proxy tinybird-local:7181
    }
    handle /.ghost/tinybird/* {
        respond 403
    }

    # --- Ghost (everything else) ------------------------------------------------
CADDY
)

patch_caddyfile() {  # patch_caddyfile <file>  (in place, idempotent)
  local f=$1 tmp
  tmp=$(mktemp)
  # 1. drop the Umami block: its comment line, ":8080 {" ... matching "}" and one blank line after
  awk '
    /^# Umami analytics/ { next }
    /^:8080 \{/          { skip=1; next }
    skip && /^\}/        { skip=0; eat_blank=1; next }
    skip                 { next }
    eat_blank && /^$/    { eat_blank=0; next }
    { eat_blank=0; print }
  ' "$f" > "$tmp"
  # 2. insert the analytics routes right after the main site block opens (once)
  if ! grep -q 'handle_path /.ghost/analytics/\*' "$tmp"; then
    awk -v block="$ANALYTICS_ROUTES" '
      !done && /^\{\$CADDY_SITE_ADDRESS::80\} \{/ { print; print block; done=1; next }
      { print }
    ' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"
    grep -q 'handle_path /.ghost/analytics/\*' "$tmp" || die "could not find the main site block in $f"
  fi
  # 3. also drop the "Umami" mention from the header comment if any
  sed -i -E '1s/ \+ Umami//; 1s/Ghost \+ Umami \+/Ghost +/' "$tmp"
  mv "$tmp" "$f"
}

validate_caddyfile() {  # validate_caddyfile <file> <site address>
  docker run --rm -v "$(readlink -f "$1"):/etc/caddy/Caddyfile:ro" -e CADDY_SITE_ADDRESS="$2" caddy:2-alpine \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>"$BK/caddy-validate.err" \
    || { cat "$BK/caddy-validate.err" >&2; return 1; }
}

if [[ -n ${DRY_CADDY:-} ]]; then
  mkdir -p "$BK"
  patch_caddyfile "$DRY_CADDY"
  validate_caddyfile "$DRY_CADDY" "adour-en-commun.fr www.adour-en-commun.fr" && echo "Caddyfile OK: $DRY_CADDY"
  exit 0
fi

# ---------------------------------------------------------------- preflight
log "preflight"
[[ -d $LFI/.git ]] || die "$LFI is not the stack checkout"
cd "$LFI"
command -v docker >/dev/null || die "docker missing"
docker compose version >/dev/null || die "docker compose v2 missing"
[[ -f .env ]] || die "$LFI/.env missing"
grep -q '^GHOST_URL=https://adour-en-commun.fr' .env || die "unexpected GHOST_URL in .env"
CADDY_ADDR=$(grep -E '^CADDY_SITE_ADDRESS=' .env | cut -d= -f2- | tr -d '"' || true)
[[ -n $CADDY_ADDR ]] || die "CADDY_SITE_ADDRESS not set in .env"

avail_mb=$(free -m | awk '/^Mem:/{print $7}')
disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
echo "  RAM available: ${avail_mb} MB   disk free: ${disk_gb} GB"
(( disk_gb >= 10 )) || die "need >= 10 GB free on / (tinybird-local image is ~7 GB unpacked)"

git fetch -q origin main
echo "  local: $(git rev-parse --short HEAD)  origin/main: $(git rev-parse --short origin/main)"
dirty=$(git status --porcelain | grep -vE '^( M|MM) caddy/Caddyfile$|^\?\? docker-compose.override.yml$' || true)
[[ -z $dirty ]] || { echo "$dirty"; die "unexpected local changes in $LFI — resolve first"; }

umami_present=0
docker inspect lfi-umami-1 >/dev/null 2>&1 && umami_present=1
echo "  umami container present: $umami_present   (SKIP_UMAMI=${SKIP_UMAMI:-0})"

mkdir -p "$BK"
cp .env "$BK/.env"; cp "$CF" "$BK/Caddyfile"; cp docker-compose.yml "$BK/docker-compose.yml"
[[ -f docker-compose.override.yml ]] && cp docker-compose.override.yml "$BK/"
echo "  backups: $BK"

if [[ ${YES:-0} != 1 ]]; then
  [[ -t 0 ]] || die "no TTY — run with YES=1 to skip the confirmation"
  read -r -p "Proceed? Umami will be removed, Ghost + Caddy recreated (~20 s blip). [y/N] " a
  [[ $a == y || $a == Y ]] || die "aborted"
fi

# ---------------------------------------------------------------- 1. Umami
if [[ ${SKIP_UMAMI:-0} != 1 ]]; then
  log "Umami: forensics, then remove"
  if (( umami_present )); then
    mkdir -p "$BK/umami"
    docker logs lfi-umami-1 > "$BK/umami/container.log" 2>&1 || true
    docker diff lfi-umami-1 > "$BK/umami/container.diff" 2>/dev/null || true
    docker inspect lfi-umami-1 > "$BK/umami/inspect.json" 2>/dev/null || true
    for p in /tmp /var/tmp/.bin /app/.next/.c; do
      docker cp "lfi-umami-1:$p" "$BK/umami/fs$(echo "$p" | tr / _)" 2>/dev/null || true
    done
    chmod -R a-x "$BK/umami" 2>/dev/null || true   # never accidentally run the samples
    docker stop lfi-umami-1 >/dev/null 2>&1 || true
    docker rm -f lfi-umami-1 >/dev/null
    echo "  container stopped + removed (evidence in $BK/umami)"
  else
    echo "  no umami container"
  fi
  docker image rm -f ghcr.io/umami-software/umami:mysql-v2.16 >/dev/null 2>&1 && echo "  image removed" || true

  echo "  MySQL: backing up ghost.settings, dropping the leaked 'umami' user"
  (cd "$LFI" && docker compose exec -T mysql sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" ghost settings') > "$BK/ghost-settings.sql"
  [[ -s $BK/ghost-settings.sql ]] || die "settings backup is empty"
  mysql_root <<'SQL'
DROP USER IF EXISTS 'umami'@'%';
FLUSH PRIVILEGES;
UPDATE ghost.settings
   SET value = REGEXP_REPLACE(REGEXP_REPLACE(value, '\\n?<!-- Umami analytics[^>]*-->', ''), '\\n?<script[^>]*:8080/script\\.js[^>]*></script>', '')
 WHERE `key` = 'codeinjection_head' AND value LIKE '%8080/script.js%';
SQL
  left=$(mysql_root -N <<<"SELECT COUNT(*) FROM ghost.settings WHERE \`key\`='codeinjection_head' AND value LIKE '%8080/script.js%';")
  [[ $left == 0 ]] || die "Umami snippet still present in codeinjection_head"
  echo "  Umami tracker removed from Ghost's code injection (Ghost is recreated later, so its settings cache reloads)"
  echo "  NOTE: database 'umami' kept. To drop it later:"
  echo "    docker compose exec -T mysql sh -c 'mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e \"DROP DATABASE umami\"'"
fi

# ---------------------------------------------------------------- 2. repo sync
log "syncing ~/lfi with origin/main (keeping the server-only Caddyfile edits)"
if [[ $(git rev-parse HEAD) != $(git rev-parse origin/main) ]]; then
  stashed=0
  if ! git diff --quiet -- caddy/Caddyfile; then git stash push -q -- caddy/Caddyfile; stashed=1; fi
  git pull -q --ff-only origin main
  if (( stashed )); then
    git checkout -q stash@{0} -- caddy/Caddyfile   # server version wins; repo version is for fresh installs
    git reset -q -- caddy/Caddyfile
    git stash drop -q
  fi
fi
echo "  now at $(git rev-parse --short HEAD): $(git log -1 --pretty=%s)"
[[ -f scripts/analytics-init.sh && -d tinybird && -d tinybird-local ]] || die "analytics files missing after pull — is the commit pushed?"
grep -q 'umami:' docker-compose.yml && die "docker-compose.yml still has umami — wrong revision"

if grep -q '^UMAMI_' .env; then
  sed -i '/^UMAMI_/d; /^# Umami analytics/d' .env
  echo "  UMAMI_* removed from .env"
fi

# ---------------------------------------------------------------- 3. Caddyfile
log "patching the Caddyfile (Umami block out, analytics routes in)"
patch_caddyfile "$CF"
validate_caddyfile "$CF" "$CADDY_ADDR" || { cp "$BK/Caddyfile" "$CF"; die "Caddyfile invalid — restored from backup"; }
echo "  Caddyfile valid"

# ---------------------------------------------------------------- 4. services
log "building tinybird-local + tinybird-deploy (pulls the ~2 GB Tinybird base once)"
docker compose build tinybird-local tinybird-deploy

# A Tinybird Local that never completed its bootstrap (no tokens in .env yet) holds
# no data worth keeping. If a previous attempt left it half-initialised (e.g. the
# 2026-09-23 max_concurrent_queries incident), start it from clean volumes.
if ! grep -qE '^TINYBIRD_ADMIN_TOKEN=.+' .env && docker inspect lfi-tinybird-local-1 >/dev/null 2>&1; then
  st=$(docker inspect lfi-tinybird-local-1 --format '{{.State.Health.Status}}' 2>/dev/null || echo none)
  if [[ $st != healthy ]]; then
    warn "tinybird-local is '$st' and analytics were never bootstrapped — resetting its volumes for a clean first boot"
    docker compose rm -sf tinybird-local tinybird-deploy >/dev/null
    sudo -n rm -rf data/tinybird/clickhouse data/tinybird/redis \
      || die "need passwordless sudo to reset data/tinybird (root-owned)"
  fi
fi
log "starting analytics services + bootstrapping tokens (recreates ghost + traffic-analytics)"
docker compose up -d tinybird-local traffic-analytics
./scripts/analytics-init.sh
log "recreating caddy (new routes, port 8080 gone, analytics network)"
docker compose up -d caddy

# ---------------------------------------------------------------- 5. verify
log "verification"
# Ghost answers 200 a few seconds before its settings/url services are warm (the
# tracker tag is missing until then): wait for its own healthcheck first.
for i in $(seq 1 60); do
  [[ $(docker inspect lfi-ghost-1 --format '{{.State.Health.Status}}' 2>/dev/null) == healthy ]] && break; sleep 3
done
for i in $(seq 1 30); do [[ $(http_code "$SITE_URL/") == 200 ]] && break; sleep 2; done
ok=1
check() {  # check <label> <accepted-codes-regex> <curl args...>
  local code; code=$(http_code "${@:3}"); printf '  %-58s %s\n' "$1" "$code"; [[ $code =~ $2 ]] || ok=0
}
check "GET  $SITE_URL/" '^200$' "$SITE_URL/"
if curl -s -m 20 "$SITE_URL/" | grep -q 'ghost-stats.min.js'; then
  echo "  tracker script present in HTML                              yes"
else
  echo "  tracker script present in HTML                              NO"; ok=0
fi
curl -s -m 20 "$SITE_URL/" | grep -q ':8080/script.js' && { echo "  Umami snippet still in HTML!"; ok=0; }
SITE_UUID=$(curl -s -m 20 "$SITE_URL/" | grep -oE 'tb_site_uuid="[^"]+"' | head -1 | cut -d'"' -f2)
UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36'
hit=$(printf '{"timestamp":"%s","action":"page_hit","version":"1","session_id":"%s","payload":{"user-agent":"%s","locale":"fr-FR","location":"FR","referrer":"","pathname":"/","href":"%s/","site_uuid":"%s","post_uuid":"undefined","post_type":"null","member_uuid":"undefined","member_status":"undefined","event_id":"%s"}}' \
  "$(date -u +%FT%T.000Z)" "$(cat /proc/sys/kernel/random/uuid)" "$UA" "$SITE_URL" "$SITE_UUID" "$(cat /proc/sys/kernel/random/uuid)")
check "POST page_hit (deploy smoke test, shows up as 1 visit)" '^202$' -X POST -H 'Content-Type: application/json' -H "x-site-uuid: $SITE_UUID" -A "$UA" --data "$hit" "$SITE_URL/.ghost/analytics/api/v1/page_hit?name=analytics_events"
ADMIN_TOKEN=$(grep -E '^TINYBIRD_ADMIN_TOKEN=' .env | cut -d= -f2-)
check "GET  pipes/api_kpis via Caddy (admin token)" '^200$' -H "Authorization: Bearer $ADMIN_TOKEN" "$SITE_URL/.ghost/tinybird/v0/pipes/api_kpis.json?site_uuid=$SITE_UUID&date_from=$(date -u +%F)&date_to=$(date -u +%F)"
check "GET  pipes/api_kpis via Caddy (no token)" '^40[13]$' "$SITE_URL/.ghost/tinybird/v0/pipes/api_kpis.json?site_uuid=$SITE_UUID"
check "GET  /.ghost/tinybird/tokens (must be blocked)" '^403$' "$SITE_URL/.ghost/tinybird/tokens"
check "GET  /.ghost/tinybird/v0/sql (must be blocked)" '^403$' "$SITE_URL/.ghost/tinybird/v0/sql?q=select+1"
check "GET  :8080 (Umami gone)" '^000$' "http://37.59.103.153:8080/"
check "GET  /ghost/api/admin/site/" '^200$' "$SITE_URL/ghost/api/admin/site/"
check "GET  forum" '^(200|30[12])$' "https://forum.adour-en-commun.fr/"

echo
docker compose ps --format 'table {{.Name}}\t{{.Status}}'
echo
free -m | head -2
docker stats --no-stream --format '  {{.Name}}\t{{.MemUsage}}' 2>/dev/null | sort

echo
if (( ok )); then
  log "DONE. Ghost Admin → Analytics (https://adour-en-commun.fr/ghost/#/analytics) is live; data appears as visitors arrive."
else
  warn "finished with failed checks — see above. Backups: $BK"
  exit 1
fi
echo "  backups + Umami evidence: $BK"
