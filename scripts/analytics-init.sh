#!/usr/bin/env bash
# Bootstrap / refresh Ghost's self-hosted web analytics (Tinybird Local).
#
#   scripts/analytics-init.sh          from the repo root (needs .env)
#
# Idempotent. Run it once after the first `docker compose up`, and again any time
# (it is what `make dev` / `make prod` / `make analytics-init` call):
#   1. starts tinybird-local + runs the one-shot tinybird-deploy (Ghost's pipes)
#   2. reads the workspace id / admin token / tracker token from Tinybird Local
#   3. writes them into .env as TINYBIRD_WORKSPACE_ID / TINYBIRD_ADMIN_TOKEN /
#      TINYBIRD_TRACKER_TOKEN (replacing existing lines)
#   4. if any value changed: recreates ghost + traffic-analytics so they pick them up
#
# Env overrides (used by tests): COMPOSE="docker compose -f ... --env-file ..."  ENV_FILE=path
set -euo pipefail

cd "$(dirname "$0")/.."
COMPOSE=${COMPOSE:-docker compose}
ENV_FILE=${ENV_FILE:-.env}
[[ -f $ENV_FILE ]] || { echo "error: $ENV_FILE missing" >&2; exit 1; }

log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }

log "starting Tinybird Local and deploying Ghost's Tinybird project"
$COMPOSE up -d tinybird-local tinybird-deploy
# Block until the one-shot deploy container exits, and fail on its exit code.
cid=$($COMPOSE ps -aq tinybird-deploy | head -n1)
[[ -n $cid ]] || { echo "error: tinybird-deploy container not found" >&2; exit 1; }
rc=$(docker wait "$cid")
if [[ $rc -ne 0 ]]; then
  echo "error: tinybird-deploy exited with $rc — logs:" >&2
  docker logs --tail 60 "$cid" >&2
  exit 1
fi

log "reading tokens from Tinybird Local"
tokens=$($COMPOSE run --rm -T tinybird-deploy tokens)
grep -qE '^TINYBIRD_WORKSPACE_ID=.+' <<<"$tokens" || { echo "error: unexpected tokens output:" >&2; echo "$tokens" >&2; exit 1; }

changed=0
while IFS='=' read -r key value; do
  [[ -n $key ]] || continue
  current=$(grep -E "^${key}=" "$ENV_FILE" | head -n1 | cut -d= -f2- || true)
  if [[ $current == "$value" ]]; then
    continue
  fi
  changed=1
  if grep -qE "^${key}=" "$ENV_FILE"; then
    # value is a JWT-like token: safe for sed's replacement side after escaping & and |
    esc=$(printf '%s' "$value" | sed -e 's/[&|\\]/\\&/g')
    sed -i -E "s|^${key}=.*|${key}=${esc}|" "$ENV_FILE"
  else
    [[ -n $(tail -c1 "$ENV_FILE") ]] && echo >>"$ENV_FILE"
    grep -q '^# --- Web analytics (Tinybird)' "$ENV_FILE" \
      || printf '\n# --- Web analytics (Tinybird) — written by scripts/analytics-init.sh, do not edit by hand\n' >>"$ENV_FILE"
    printf '%s=%s\n' "$key" "$value" >>"$ENV_FILE"
  fi
  echo "  $key updated"
done <<<"$tokens"

if [[ $changed -eq 1 ]]; then
  log "tokens changed — recreating ghost + traffic-analytics with the new values (~15s Ghost blip)"
  $COMPOSE up -d ghost traffic-analytics
else
  log "tokens unchanged — making sure traffic-analytics is up"
  $COMPOSE up -d traffic-analytics
fi

log "done. Ghost Admin → Analytics should fill up as visitors arrive (Settings → Analytics → Web analytics must be ON)."
