#!/usr/bin/env bash
# Create the Ghost webhook that feeds social-publisher, through the Admin API —
# the scripted alternative to Ghost Admin → Settings → Integrations → <your
# integration> → Add webhook. Idempotent: Ghost refuses a second webhook with the
# same event + target URL, which this script reports as "already exists".
#
#   scripts/social-webhook.sh <ghost-url> <admin-api-key> [target-url] [secret]
#
#   ghost-url       the site, e.g. https://adour-en-commun.fr (GHOST_URL in .env)
#   admin-api-key   "Admin API key" of a custom integration (Ghost Admin → Settings →
#                   Integrations → Add custom integration, e.g. "Facebook"): id:secret
#   target-url      default http://social-publisher.lfi.internal:8080/webhooks/ghost
#   secret          default SOCIAL_WEBHOOK_SECRET from .env (must match the publisher)
#
# Needs curl + openssl. The webhook is attached to the key's integration.
set -euo pipefail

GHOST_URL=${1:?usage: $0 <ghost-url> <admin-api-key> [target-url] [secret]}
ADMIN_KEY=${2:?usage: $0 <ghost-url> <admin-api-key> [target-url] [secret]}
TARGET_URL=${3:-http://social-publisher.lfi.internal:8080/webhooks/ghost}
SECRET=${4:-}
GHOST_URL=${GHOST_URL%/}

if [[ -z $SECRET ]]; then
  ENV_FILE=${ENV_FILE:-$(dirname "$0")/../.env}
  SECRET=$(grep -E '^SOCIAL_WEBHOOK_SECRET=' "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)
  [[ -n $SECRET ]] || { echo "error: no secret given and SOCIAL_WEBHOOK_SECRET missing in $ENV_FILE" >&2; exit 1; }
fi
[[ $ADMIN_KEY =~ ^[0-9a-f]{24}:[0-9a-f]{64}$ ]] || { echo "error: the Admin API key looks wrong (expected <24 hex>:<64 hex>, as shown in Ghost Admin)" >&2; exit 1; }
[[ $SECRET =~ ^[A-Za-z0-9._-]{16,191}$ ]] || { echo "error: the webhook secret must be 16-191 chars of [A-Za-z0-9._-]" >&2; exit 1; }
[[ $TARGET_URL =~ ^https?://[^\"[:space:]]+$ ]] || { echo "error: odd target URL: $TARGET_URL" >&2; exit 1; }

# Admin API auth: a 5-minute HS256 JWT signed with the hex-decoded key secret.
ghost_jwt() {
  local id=${ADMIN_KEY%%:*} secret=${ADMIN_KEY#*:} now header payload sig
  b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  now=$(date +%s)
  header=$(printf '{"alg":"HS256","typ":"JWT","kid":"%s"}' "$id" | b64url)
  payload=$(printf '{"iat":%d,"exp":%d,"aud":"/admin/"}' "$now" $((now + 300)) | b64url)
  sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$secret" -binary | b64url)
  printf '%s.%s.%s' "$header" "$payload" "$sig"
}

body=$(printf '{"webhooks":[{"name":"Facebook (social-publisher)","event":"post.published","target_url":"%s","secret":"%s"}]}' "$TARGET_URL" "$SECRET")
out=$(mktemp); trap 'rm -f "$out"' EXIT
code=$(curl -sS ${CURL_OPTS:-} -o "$out" -w '%{http_code}' -m 30 -X POST \
  -H "Authorization: Ghost $(ghost_jwt)" -H 'Content-Type: application/json' -H 'Accept-Version: v6.0' \
  --data "$body" "$GHOST_URL/ghost/api/admin/webhooks/")

case $code in
  201)
    echo "webhook created: post.published → $TARGET_URL"
    ;;
  422)
    if grep -q 'already been used' "$out"; then
      echo "webhook already exists: post.published → $TARGET_URL (nothing to do)"
    else
      echo "error: Ghost rejected the webhook (422):" >&2; cat "$out" >&2; echo >&2; exit 1
    fi
    ;;
  *)
    echo "error: HTTP $code from $GHOST_URL/ghost/api/admin/webhooks/:" >&2; cat "$out" >&2; echo >&2; exit 1
    ;;
esac
