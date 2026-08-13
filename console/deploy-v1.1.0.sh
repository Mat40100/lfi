#!/usr/bin/env bash
# Deploy console v1.1.0 on the prod server (run it there, from ~/lfi,
# after `git pull` so console/server.js is current):
#   - console auth becomes "Ghost Admin session" (any Owner/Administrator),
#     served at /ghost/console; the Caddy basic_auth block is removed.
#   - fixes tier-comping for existing members (Ghost 6 ignores tiers on PUT).
set -euo pipefail
cd ~/lfi

echo "== 1/5 sanity: console source is v1.1.0 =="
grep -q 'ghostStaffFromCookie' console/server.js || { echo "console/server.js is not v1.1.0 — run git pull first"; exit 1; }

echo "== 2/5 rewrite Caddyfile block (basic_auth -> /ghost/console) =="
cp caddy/Caddyfile caddy/Caddyfile.bak-console-v1.1.0
python3 - <<'PYEOF'
import re
p = 'caddy/Caddyfile'
s = open(p).read()
block = re.compile(
    r'[ \t]*# Team console admin.*?\n[ \t]*handle /equipe/admin\* \{.*?\n[ \t]*\}\n',
    re.DOTALL)
new = """    # Team console admin (invites) — auth = Ghost Admin session (role Owner/
    # Administrator), validated by the console app itself. Served under /ghost
    # so the browser sends the ghost-admin-api-session cookie (Path=/ghost).
    handle /ghost/console* {
        reverse_proxy console:3300
    }
"""
s2, n = block.subn(new, s, count=1)
assert n == 1, "basic_auth block not found - Caddyfile layout changed, aborting"
open(p, 'w').write(s2)
print("Caddyfile updated")
PYEOF

echo "== 3/5 build image lfi-console:v1.1.0 =="
docker build -t lfi-console:v1.1.0 console/

echo "== 4/5 point override at new image + recreate =="
sed -i 's|lfi-console:v1\.0\.0|lfi-console:v1.1.0|' docker-compose.override.yml
docker compose up -d console
docker compose restart caddy

echo "== 5/5 verify =="
sleep 3
curl -sk -o /dev/null -w "health (expect 200): %{http_code}\n"  https://landes-insoumises.fr/equipe/health
curl -sk -o /dev/null -w "console no-cookie (expect 401): %{http_code}\n" https://landes-insoumises.fr/ghost/console
curl -sk -o /dev/null -w "legacy /equipe/admin (expect 303): %{http_code}\n" https://landes-insoumises.fr/equipe/admin
echo "done - open https://landes-insoumises.fr/ghost/console while logged into Ghost Admin"
