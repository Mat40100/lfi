#!/usr/bin/env bash
# Production rollout of the Facebook auto-share (social-publisher service).
#
# Runs ON THE PROD SERVER as `ubuntu`:   bash ~/lfi/scripts/social-deploy-prod.sh
#   (after `git pull` there — or scp this file over first)
#   YES=1                     skip the confirmation prompt
#   GHOST_ADMIN_API_KEY=id:s  also create the Ghost webhook through the Admin API (the
#                             "Admin API key" of a custom integration, Ghost Admin → Settings
#                             → Integrations). Without it, the values to enter by hand are printed.
#
# Prerequisite in ~/lfi/.env (docs/social-facebook.md): FACEBOOK_PAGE_ID + FACEBOOK_PAGE_ACCESS_TOKEN
# (from `make facebook-token`). The Caddyfile is NOT touched: nothing is exposed publicly.
#
# What it does (idempotent; backups in ~/social-deploy-backup-<ts>/):
#   1. ~/lfi: git pull --ff-only (server-only Caddyfile edits are kept)
#   2. .env: SOCIAL_WEBHOOK_SECRET generated if missing
#   3. build + start social-publisher, recreate ghost (new env + `social` network, ~15 s blip)
#   4. verify: publisher healthy + reachable from the ghost container, no published port,
#      Page token valid (`check`), site up
#   5. Ghost webhook: created via the Admin API when GHOST_ADMIN_API_KEY is set, else printed
set -euo pipefail

LFI=$HOME/lfi
TS=$(date +%Y%m%d-%H%M)
BK=$HOME/social-deploy-backup-$TS
TARGET_URL=http://social-publisher.lfi.internal:8080/webhooks/ghost

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
http_code() { curl -s -o /dev/null -m 20 -w '%{http_code}' "$@" 2>/dev/null || true; }
env_get() { grep -E "^$1=" .env | head -n1 | cut -d= -f2- | tr -d '"' || true; }

# ---------------------------------------------------------------- preflight
log "preflight"
[[ -d $LFI/.git ]] || die "$LFI is not the stack checkout"
cd "$LFI"
command -v docker >/dev/null || die "docker missing"
docker compose version >/dev/null || die "docker compose v2 missing"
[[ -f .env ]] || die "$LFI/.env missing"
GHOST_URL=$(env_get GHOST_URL)
[[ $GHOST_URL == https://* ]] || die "unexpected GHOST_URL in .env: '$GHOST_URL'"
PAGE_ID=$(env_get FACEBOOK_PAGE_ID)
PAGE_TOKEN=$(env_get FACEBOOK_PAGE_ACCESS_TOKEN)
[[ -n $PAGE_ID && -n $PAGE_TOKEN ]] \
  || die "FACEBOOK_PAGE_ID / FACEBOOK_PAGE_ACCESS_TOKEN missing in $LFI/.env — run 'make facebook-token' in $LFI first (docs/social-facebook.md)"
echo "  site: $GHOST_URL   page: $PAGE_ID   token: ${#PAGE_TOKEN} chars"
echo "  RAM available: $(free -m | awk '/^Mem:/{print $7}') MB"

git fetch -q origin main
echo "  local: $(git rev-parse --short HEAD)  origin/main: $(git rev-parse --short origin/main)"
dirty=$(git status --porcelain | grep -vE '^( M|MM) caddy/Caddyfile$|^\?\? docker-compose.override.yml$' || true)
[[ -z $dirty ]] || { echo "$dirty"; die "unexpected local changes in $LFI — resolve first"; }

mkdir -p "$BK"
cp .env "$BK/.env"; cp docker-compose.yml "$BK/docker-compose.yml"
[[ -f docker-compose.override.yml ]] && cp docker-compose.override.yml "$BK/"
echo "  backups: $BK"

if [[ ${YES:-0} != 1 ]]; then
  [[ -t 0 ]] || die "no TTY — run with YES=1 to skip the confirmation"
  read -r -p "Proceed? social-publisher starts, Ghost is recreated (~15 s blip). [y/N] " a
  [[ $a == y || $a == Y ]] || die "aborted"
fi

# ---------------------------------------------------------------- 1. repo sync
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
[[ -f social-publisher/server.js && -x scripts/social-webhook.sh ]] || die "social-publisher files missing after pull — is the commit pushed?"
grep -q '^  social-publisher:' docker-compose.yml || die "docker-compose.yml has no social-publisher service — wrong revision"

# ---------------------------------------------------------------- 2. webhook secret
log ".env: webhook secret"
if grep -qE '^SOCIAL_WEBHOOK_SECRET=.+' .env; then
  echo "  SOCIAL_WEBHOOK_SECRET present"
else
  sed -i '/^SOCIAL_WEBHOOK_SECRET=$/d' .env
  [[ -n $(tail -c1 .env) ]] && echo >>.env
  grep -q '^# --- Facebook auto-share' .env || printf '\n# --- Facebook auto-share (social-publisher) — docs/social-facebook.md\n' >>.env
  printf 'SOCIAL_WEBHOOK_SECRET=%s\n' "$(openssl rand -hex 32)" >>.env
  echo "  SOCIAL_WEBHOOK_SECRET generated"
fi
SECRET=$(env_get SOCIAL_WEBHOOK_SECRET)

# ---------------------------------------------------------------- 3. services
log "building social-publisher"
docker compose build social-publisher
log "starting social-publisher + recreating ghost (new env + social network, ~15 s blip)"
docker compose up -d social-publisher ghost
for i in $(seq 1 60); do
  [[ $(docker inspect lfi-ghost-1 --format '{{.State.Health.Status}}' 2>/dev/null) == healthy ]] && break; sleep 3
done
for i in $(seq 1 20); do
  [[ $(docker inspect lfi-social-publisher-1 --format '{{.State.Health.Status}}' 2>/dev/null) == healthy ]] && break; sleep 3
done

# ---------------------------------------------------------------- 4. verify
log "verification"
ok=1
check() {  # check <label> <expected-regex> <value>
  printf '  %-62s %s\n' "$1" "$3"; [[ $3 =~ $2 ]] || ok=0
}
check "social-publisher health" '^healthy$' "$(docker inspect lfi-social-publisher-1 --format '{{.State.Health.Status}}' 2>/dev/null || echo missing)"
check "ghost health" '^healthy$' "$(docker inspect lfi-ghost-1 --format '{{.State.Health.Status}}' 2>/dev/null || echo missing)"
check "ghost → $TARGET_URL (healthz)" '^200$' \
  "$(docker compose exec -T ghost curl -s -o /dev/null -m 10 -w '%{http_code}' http://social-publisher.lfi.internal:8080/healthz 2>/dev/null || echo 000)"
check "ghost security__allowWebhookInternalIPs" '^true$' \
  "$(docker compose exec -T ghost sh -c 'printf %s "$security__allowWebhookInternalIPs"' 2>/dev/null || echo unset)"
check "published ports on social-publisher (must be none)" '^0$' "$(docker port lfi-social-publisher-1 2>/dev/null | wc -l)"
check "GET  $GHOST_URL/" '^200$' "$(http_code "$GHOST_URL/")"
check "GET  $GHOST_URL/ghost/api/admin/site/" '^200$' "$(http_code "$GHOST_URL/ghost/api/admin/site/")"
echo "  Facebook Page token:"
if docker compose run --rm -T social-publisher check 2>&1 | sed 's/^/      /'; then
  echo "  Page token                                                     OK"
else
  echo "  Page token                                                     FAILED"; ok=0
fi

# ---------------------------------------------------------------- 5. Ghost webhook
log "Ghost webhook (post.published → social-publisher)"
if [[ -n ${GHOST_ADMIN_API_KEY:-} ]]; then
  ./scripts/social-webhook.sh "$GHOST_URL" "$GHOST_ADMIN_API_KEY" "$TARGET_URL" "$SECRET" || ok=0
else
  cat <<EOT
  Create it once in Ghost Admin → Settings → Integrations → "Add custom integration"
  (e.g. "Facebook") → "Add webhook":
      Name:        Facebook (social-publisher)
      Event:       Post published
      Target URL:  $TARGET_URL
      Secret:      $SECRET
  (or re-run this script with GHOST_ADMIN_API_KEY=<that integration's Admin API key> to create it)
EOT
fi

echo
docker compose ps --format 'table {{.Name}}\t{{.Status}}'
echo
free -m | head -2

echo
if (( ok )); then
  log "DONE. Every post published from now on is shared on the Page (once the webhook exists)."
  echo "  watch:   cd ~/lfi && docker compose logs -f social-publisher"
  echo "  opt-out: tag a post #no-facebook before publishing"
else
  warn "finished with failed checks — see above. Backups: $BK"
  exit 1
fi
