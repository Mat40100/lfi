#!/usr/bin/env bash
# Create the two Ghost webhooks that feed social-publisher, through the Admin API —
# the scripted alternative to Ghost Admin → Settings → Integrations → <your
# integration> → Add webhook:
#   post.published         share a post when it is published
#   post.published.edited  share an already-published post when it is saved with
#                          the #facebook tag (the "send this older post" button)
# Idempotent: Ghost refuses a second webhook with the same event + target URL,
# which this script reports as "already exists".
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

out=$(mktemp); trap 'rm -f "$out"' EXIT
create_webhook() {  # create_webhook <event> <name>
  local event=$1 name=$2 body code
  body=$(printf '{"webhooks":[{"name":"%s","event":"%s","target_url":"%s","secret":"%s"}]}' "$name" "$event" "$TARGET_URL" "$SECRET")
  code=$(curl -sS ${CURL_OPTS:-} -o "$out" -w '%{http_code}' -m 30 -X POST \
    -H "Authorization: Ghost $(ghost_jwt)" -H 'Content-Type: application/json' -H 'Accept-Version: v6.0' \
    --data "$body" "$GHOST_URL/ghost/api/admin/webhooks/")
  case $code in
    201)
      echo "webhook created: $event → $TARGET_URL"
      ;;
    422)
      if grep -q 'already been used' "$out"; then
        echo "webhook already exists: $event → $TARGET_URL (nothing to do)"
      else
        echo "error: Ghost rejected the $event webhook (422):" >&2; cat "$out" >&2; echo >&2; return 1
      fi
      ;;
    *)
      echo "error: HTTP $code from $GHOST_URL/ghost/api/admin/webhooks/ ($event):" >&2; cat "$out" >&2; echo >&2; return 1
      ;;
  esac
}

create_webhook post.published        "Facebook (social-publisher)"
create_webhook post.published.edited "Facebook (social-publisher) — share on edit (#facebook tag)"
