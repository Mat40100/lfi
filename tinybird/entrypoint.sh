#!/usr/bin/env bash
# Entrypoint of the tinybird-deploy image. Sub-commands:
#
#   deploy   (default) wait for tinybird-local, then `tb --local deploy` Ghost's
#            Tinybird project into it. Idempotent: no-op when nothing changed.
#   tokens   print the three values Ghost + traffic-analytics need, as KEY=value
#            lines on stdout (everything else goes to stderr):
#              TINYBIRD_WORKSPACE_ID, TINYBIRD_ADMIN_TOKEN, TINYBIRD_TRACKER_TOKEN
#   tb ...   run an arbitrary tb command against tinybird-local
#            (e.g. `docker compose run --rm tinybird-deploy tb --local sql "select count() from analytics_events"`)
#
# Talks to the Tinybird Local container named by TB_LOCAL_HOST (port 7181).
set -euo pipefail

TB_LOCAL_HOST=${TB_LOCAL_HOST:-tinybird-local}
TB_URL=${TB_HOST:-http://$TB_LOCAL_HOST:7181}
export TB_HOST=$TB_URL TB_LOCAL_HOST

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

wait_for_tinybird() {
  local i
  for i in $(seq 1 90); do
    if curl -fsS -m 5 "$TB_URL/v0/health" >/dev/null 2>&1; then
      return 0
    fi
    [[ $i -eq 1 ]] && log "waiting for Tinybird Local at $TB_URL ..."
    sleep 2
  done
  die "Tinybird Local at $TB_URL not healthy after 180s"
}

cmd_deploy() {
  wait_for_tinybird
  cd /project
  log "deploying Ghost's Tinybird project ($(ls -1 datasources | wc -l) datasources, $(ls -1 pipes endpoints | grep -c '\.pipe$') pipes) to $TB_URL"
  # `tb deploy` exits non-zero when there is nothing to deploy; treat that as success
  # so re-running on every `docker compose up` stays quiet.
  local out rc=0
  out=$(tb --local deploy 2>&1) || rc=$?
  printf '%s\n' "$out" >&2
  # tb prints "Deployment failed" / "[Error] ..." but has been seen exiting 0, and
  # exits non-zero for the harmless "No changes to be deployed": decide on the text.
  if grep -qE 'Deployment failed|^\[Error\]' <<<"$out"; then
    die "tb deploy failed (exit $rc)"
  fi
  if grep -qE 'No changes to be deployed' <<<"$out" && ! grep -qE 'Deployment (created|promoted|done|succeeded)|Deploying' <<<"$out"; then
    log "nothing to deploy — workspace already up to date"
    return 0
  fi
  [[ $rc -eq 0 ]] || die "tb deploy exited $rc"
  log "deploy done"
}

cmd_tokens() {
  wait_for_tinybird
  local info ws_token tokens_json workspace_id admin_token tracker_token
  # `tb --local` deploys into a per-project *build* workspace (Tinybird_Local_Build_<hash>),
  # not the container's default workspace whose token /tokens returns — so take the
  # workspace id and its admin token from `tb info`, like Ghost's own tb-cli script.
  info=$(cd /project && tb --output json info 2>/dev/null) || die "'tb info' failed"
  workspace_id=$(jq -re '.local.workspace_id' <<<"$info") || die "no workspace id in 'tb info'"
  ws_token=$(jq -re '.local.token' <<<"$info") || die "no workspace token in 'tb info'"

  tokens_json=$(curl -fsS -m 10 -H "Authorization: Bearer $ws_token" "$TB_URL/v0/tokens") \
    || die "could not list tokens"

  # Ghost signs its JWTs with the workspace's ADMIN-scoped token (same selection
  # rule as Ghost's own docker/tb-cli/entrypoint.sh: pick by scope, not by name).
  admin_token=$(jq -re '[.tokens[] | select(any(.scopes[]?; .type == "ADMIN"))][0].token' <<<"$tokens_json") \
    || die "no ADMIN-scoped token in the workspace"
  # Created by `tb deploy` from `TOKEN "tracker" APPEND` in analytics_events.datasource.
  tracker_token=$(jq -re '[.tokens[] | select(.name == "tracker")][0].token' <<<"$tokens_json") \
    || die "no 'tracker' token — has the project been deployed? (run: tinybird-entrypoint deploy)"

  printf 'TINYBIRD_WORKSPACE_ID=%s\nTINYBIRD_ADMIN_TOKEN=%s\nTINYBIRD_TRACKER_TOKEN=%s\n' \
    "$workspace_id" "$admin_token" "$tracker_token"
}

case "${1:-deploy}" in
  deploy) cmd_deploy ;;
  tokens) cmd_tokens ;;
  tb) shift; wait_for_tinybird; cd /project; exec tb "$@" ;;
  *) exec "$@" ;;
esac
