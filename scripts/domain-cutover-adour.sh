#!/usr/bin/env bash
# Domain cutover: landes-insoumises.fr -> adour-en-commun.fr (site + forum).
#
# Runs ON THE PROD SERVER as `ubuntu`:   bash ~/domain-cutover-adour.sh
#   YES=1              skip the confirmation prompt (needed when there is no TTY, e.g. detached:
#                      YES=1 setsid -f bash ~/domain-cutover-adour.sh > ~/domain-cutover.log 2>&1 < /dev/null)
#   SKIP_MAIL_CHECK=1  cut over even if Mailjet isn't validated for the new domain
#                      (keeps sending as noreply@landes-insoumises.fr for now)
#
# What it does (each step guarded / idempotent, backups in ~/domain-cutover-backup-<ts>/):
#   1. preflight: DNS A records of apex/www/forum -> 37.59.103.153, Mailjet SPF+DKIM
#   2. ~/lfi/.env            GHOST_URL, CADDY_SITE_ADDRESS, MAIL_FROM
#   3. ~/lfi/caddy/Caddyfile forum block renamed + 301 redirects for the old names
#   4. Ghost DB              "Forum" nav link (+ members_support_address if mail kept old)
#   5. docker compose up -d --force-recreate ghost caddy   (~15 s blip)
#   6. /var/discourse/containers/app.yml  DISCOURSE_HOSTNAME (+ notification e-mail)
#      -> ./launcher rebuild app  (forum DOWN ~10-15 min; re-run the script if the launcher
#         stops after a Postgres upgrade and asks for a second rebuild), re-attach lfi_web,
#         remap old->new host in posts (same as rake posts:remap), vapid_base_url
#   7. verification (HTTP codes) + summary
set -euo pipefail

OLD=landes-insoumises.fr
NEW=adour-en-commun.fr
IP=37.59.103.153
LFI=$HOME/lfi
CF=$LFI/caddy/Caddyfile
DISCOURSE_DIR=/var/discourse
APP_YML=$DISCOURSE_DIR/containers/app.yml
TS=$(date +%Y%m%d-%H%M)
BK=$HOME/domain-cutover-backup-$TS
MAIL_FROM_NEW="Adour en commun <noreply@$NEW>"
STAGE=preflight

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

on_exit() {
  local rc=$?
  if [[ $rc -ne 0 && $STAGE == config ]]; then
    cp "$BK/.env" "$LFI/.env"; cp "$BK/Caddyfile" "$CF"
    warn "aborted before anything was applied — .env and Caddyfile restored from $BK"
  fi
}
trap on_exit EXIT

a_rec() {  # ALL A records of $1 (space separated), public resolver first (avoid stale local cache)
  local r
  r=$(dig +short A "$1" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | sort | tr '\n' ' ' | sed 's/ $//' || true)
  [[ -n $r ]] || r=$(dig +short A "$1" 2>/dev/null | grep -E '^[0-9.]+$' | sort | tr '\n' ' ' | sed 's/ $//' || true)
  echo "$r"
}
txt_rec() { dig +short TXT "$1" @1.1.1.1 2>/dev/null | tr -d '"' || true; }
http_code() { curl -s -o /dev/null -m 15 -w '%{http_code}' "$1" 2>/dev/null || echo 000; }
check() {  # check <url> <regex of accepted codes>
  local code; code=$(http_code "$1")
  printf '  %-48s %s\n' "$1" "$code"
  [[ $code =~ $2 ]]
}
mysql_ghost() {  # SQL on stdin -> ghost DB (creds from the mysql container env)
  (cd "$LFI" && docker compose exec -T mysql sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -t "$MYSQL_DATABASE"' 2>&1 | grep -v 'insecure' || true)
}

# ---------------------------------------------------------------- preflight
log "Preflight"
[[ $(id -un) == ubuntu ]] || die "run as ubuntu"
for f in "$LFI/.env" "$CF" "$LFI/docker-compose.yml"; do [[ -f $f ]] || die "missing $f"; done
sudo test -f "$APP_YML" || die "missing $APP_YML"
for t in dig curl docker; do command -v "$t" >/dev/null || die "$t missing"; done

echo "DNS (must all point at $IP):"
DNS_FAIL=0
for h in "$NEW" "www.$NEW" "forum.$NEW"; do
  r=$(a_rec "$h"); printf '  %-32s -> %s\n' "$h" "${r:-<none>}"
  [[ $r == "$IP" ]] || DNS_FAIL=1   # exactly one A record, ours — a leftover parking A breaks the ACME challenge
done
[[ $DNS_FAIL == 0 ]] || die "apex, www and forum of $NEW must each resolve to exactly $IP (Let's Encrypt validates them). OVH zone: add the A records AND delete the parking A 213.186.33.5 on every name."
echo "Old names (kept as 301 redirects while they still point here):"
for h in "$OLD" "www.$OLD" "forum.$OLD"; do printf '  %-32s -> %s\n' "$h" "$(a_rec "$h")"; done

echo "Mailjet DNS on $NEW:"
spf=$(txt_rec "$NEW" | grep -i 'v=spf1' || true)
dkim=$(txt_rec "mailjet._domainkey.$NEW")
printf '  SPF : %s\n  DKIM: %s\n' "${spf:-<none>}" "$( [[ -n $dkim ]] && echo present || echo '<none>')"
if [[ $spf == *spf.mailjet.com* && -n $dkim ]]; then
  MAIL_MODE=new
  echo "  -> transactional mail will be sent as noreply@$NEW"
elif [[ ${SKIP_MAIL_CHECK:-0} == 1 ]]; then
  MAIL_MODE=keep-old
  warn "Mailjet not validated for $NEW — keeping noreply@$OLD as sender (SKIP_MAIL_CHECK=1). Re-run this script once validated."
else
  die "no Mailjet SPF (include:spf.mailjet.com) / DKIM (mailjet._domainkey) on $NEW. Add + validate the sender domain in Mailjet first, or run with SKIP_MAIL_CHECK=1 to keep sending as noreply@$OLD."
fi

cat <<EOF

Plan:
  .env        GHOST_URL=https://$NEW  CADDY_SITE_ADDRESS="$NEW www.$NEW"$( [[ $MAIL_MODE == new ]] && printf '  MAIL_FROM="%s"' "$MAIL_FROM_NEW" || true)
  Caddyfile   forum.$OLD -> forum.$NEW ; 301 redirects for $OLD, www.$OLD, forum.$OLD
  Ghost DB    navigation "Forum" -> https://forum.$NEW/$( [[ $MAIL_MODE == keep-old ]] && printf ' ; members_support_address=noreply@%s' "$OLD" || true)
  Discourse   DISCOURSE_HOSTNAME=forum.$NEW$( [[ $MAIL_MODE == new ]] && printf ' ; DISCOURSE_NOTIFICATION_EMAIL=noreply@%s' "$NEW" || true) ; launcher rebuild (forum down ~10-15 min) ; posts:remap
  Backups     $BK
EOF
if [[ ${YES:-0} != 1 ]]; then
  [[ -t 0 ]] || die "no terminal for the confirmation prompt. Either run from a real terminal (ssh -t ...), or detach it: YES=1 setsid -f bash ~/domain-cutover-adour.sh > ~/domain-cutover.log 2>&1 < /dev/null"
  read -rp "Type YES to proceed: " ans; [[ $ans == YES ]] || die "aborted"
fi

# ---------------------------------------------------------------- backups
log "Backups -> $BK"
mkdir -p "$BK"; chmod 700 "$BK"
cp "$LFI/.env" "$BK/.env"; cp "$CF" "$BK/Caddyfile"
sudo cp "$APP_YML" "$BK/app.yml"; sudo chown ubuntu:ubuntu "$BK/app.yml"
(cd "$LFI" && docker compose exec -T mysql sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" settings' 2>/dev/null > "$BK/ghost-settings.sql")
grep -q 'CREATE TABLE `settings`' "$BK/ghost-settings.sql" || die "ghost settings dump failed"
chmod 600 "$BK"/.env "$BK"/app.yml "$BK"/ghost-settings.sql
ls -la "$BK"
STAGE=config

# ---------------------------------------------------------------- .env
log "Update $LFI/.env"
sed -i -E \
  -e "s|^GHOST_URL=.*|GHOST_URL=https://$NEW|" \
  -e "s|^CADDY_SITE_ADDRESS=.*|CADDY_SITE_ADDRESS=$NEW www.$NEW|" "$LFI/.env"
if [[ $MAIL_MODE == new ]]; then sed -i -E "s|^MAIL_FROM=.*|MAIL_FROM=$MAIL_FROM_NEW|" "$LFI/.env"; fi
grep -E '^(GHOST_URL|CADDY_SITE_ADDRESS|MAIL_FROM)=' "$LFI/.env" | sed 's/^/  /'
grep -q "^GHOST_URL=https://$NEW\$" "$LFI/.env" || die ".env edit failed"

# ---------------------------------------------------------------- Caddyfile
log "Update Caddyfile"
sed -i "s|^forum\.$OLD {|forum.$NEW {|" "$CF"
grep -q "^forum\.$NEW {" "$CF" || die "forum block rename failed"
if ! grep -q "^$OLD, www\.$OLD {" "$CF"; then
  cat >> "$CF" <<EOF

# Old domain ($OLD, retired $(date +%F)): permanent redirects to $NEW.
# Caddy keeps renewing the old names' certs as long as their DNS points here.
$OLD, www.$OLD {
    redir https://$NEW{uri} permanent
}
forum.$OLD {
    redir https://forum.$NEW{uri} permanent
}
EOF
fi
echo "  validating with a throwaway caddy container..."
docker run --rm -e "CADDY_SITE_ADDRESS=$NEW www.$NEW" -v "$CF:/etc/caddy/Caddyfile:ro" caddy:2-alpine \
  caddy validate --config /etc/caddy/Caddyfile 2>&1 | tail -n 3 | sed 's/^/  /'
docker run --rm -e "CADDY_SITE_ADDRESS=$NEW www.$NEW" -v "$CF:/etc/caddy/Caddyfile:ro" caddy:2-alpine \
  caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 || die "Caddyfile invalid"

# ---------------------------------------------------------------- Ghost DB
log "Ghost DB: navigation link / support address"
{
  printf "UPDATE settings SET value = REPLACE(value, 'forum.%s', 'forum.%s') WHERE \`key\` IN ('navigation','secondary_navigation');\n" "$OLD" "$NEW"
  if [[ $MAIL_MODE == keep-old ]]; then
    printf "UPDATE settings SET value = 'noreply@%s' WHERE \`key\` = 'members_support_address' AND value = 'noreply';\n" "$OLD"
  else
    printf "UPDATE settings SET value = 'noreply' WHERE \`key\` = 'members_support_address' AND value = 'noreply@%s';\n" "$OLD"
  fi
  printf "SELECT \`key\`, LEFT(value,120) AS value FROM settings WHERE \`key\` IN ('navigation','members_support_address','mailgun_domain');\n"
} | mysql_ghost

# ---------------------------------------------------------------- Ghost + Caddy
if cmp -s "$LFI/.env" "$BK/.env" && cmp -s "$CF" "$BK/Caddyfile"; then
  log "ghost + caddy: .env and Caddyfile unchanged — nothing to recreate"
else
  log "Recreate ghost + caddy"
  (cd "$LFI" && docker compose up -d --force-recreate ghost caddy)
fi
STAGE=applied
s=none
for _ in $(seq 1 60); do
  s=$(docker inspect -f '{{.State.Health.Status}}' "$(cd "$LFI" && docker compose ps -q ghost)" 2>/dev/null || echo none)
  [[ $s == healthy ]] && break; sleep 3
done
echo "  ghost health: $s"
[[ $s == healthy ]] || warn "ghost not healthy yet: cd ~/lfi && docker compose logs --tail=50 ghost"

log "Wait for Let's Encrypt cert on $NEW (up to ~3 min)"
for _ in $(seq 1 36); do [[ $(http_code "https://$NEW/") == 200 ]] && break; sleep 5; done
check "https://$NEW/"        '^200$'            || warn "site not 200 yet: cd ~/lfi && docker compose logs --tail=50 caddy"
check "https://www.$NEW/"    '^(200|301|308)$'  || true
check "http://$NEW/"         '^(301|308)$'      || true
check "https://$OLD/"        '^(301|308)$'      || warn "old domain not redirecting"
echo "  $OLD -> $(curl -sI -m 15 "https://$OLD/" 2>/dev/null | grep -i '^location' | tr -d '\r' || echo '?')"

# ---------------------------------------------------------------- Discourse
log "Discourse: app.yml"
sudo sed -i -E "s|^(\s*DISCOURSE_HOSTNAME:).*|\1 \"forum.$NEW\"|" "$APP_YML"
if [[ $MAIL_MODE == new ]]; then
  sudo sed -i -E "s|^(\s*DISCOURSE_NOTIFICATION_EMAIL:).*|\1 noreply@$NEW|" "$APP_YML"
fi
sudo grep -nE 'DISCOURSE_HOSTNAME|DISCOURSE_NOTIFICATION_EMAIL' "$APP_YML" | sed 's/^/  /'
sudo grep -q "DISCOURSE_HOSTNAME: \"forum.$NEW\"" "$APP_YML" || die "app.yml edit failed"

app_running() { [[ -n $(docker ps -q --filter name='^app$' --filter status=running) ]]; }
if sudo cmp -s "$APP_YML" "$BK/app.yml" && app_running; then
  echo "  app.yml unchanged and forum container running — skipping rebuild"
else
  app_running || warn "forum container 'app' is not running — rebuilding (a launcher Postgres upgrade stops after the first rebuild and asks for a second one)"
  log "Discourse: launcher rebuild app (forum down ~10-15 min, do not interrupt)"
  (cd "$DISCOURSE_DIR" && sudo ./launcher rebuild app) || warn "launcher exited non-zero — checking whether the container came up anyway"
  sleep 5
  app_running || die "forum container 'app' still not running after rebuild — read the output above (a Postgres upgrade message means: run this script again) or: cd /var/discourse && sudo ./launcher logs app"
  sudo docker network connect lfi_web app 2>/dev/null || true
  docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' app | grep -q lfi_web || die "container app is not on lfi_web"
  echo "  app networks: $(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' app)"

  log "Wait for the forum on https://forum.$NEW (login_required -> 302 is fine)"
  for _ in $(seq 1 60); do [[ $(http_code "https://forum.$NEW/") =~ ^(200|302)$ ]] && break; sleep 5; done
  check "https://forum.$NEW/"  '^(200|302)$' || warn "forum not answering yet: cd /var/discourse && sudo ./launcher logs app"
  check "https://forum.$OLD/"  '^(301|308)$' || true

fi

log "Discourse: remap forum.$OLD -> forum.$NEW in posts + vapid_base_url (~30 s rails boot)"
cat > /tmp/domain-remap.rb <<EOF
old = "forum.$OLD"; new = "forum.$NEW"
SiteSetting.vapid_base_url = "https://#{new}"
n = 0
# same operation as \`rake posts:remap\`, minus its interactive confirmation
Post.where("raw LIKE ?", "%#{old}%").find_each do |p|
  new_raw = p.raw.gsub(old, new)
  next if new_raw == p.raw
  begin
    p.revise(Discourse.system_user, { raw: new_raw }, bypass_bump: true, skip_revision: true, skip_validations: true, bypass_rate_limiter: true)
    n += 1
  rescue => e
    puts "failed post #{p.id}: #{e.message}"
  end
end
puts "remapped #{n} posts; still containing #{old}: #{Post.where("raw LIKE ?", "%#{old}%").count}"
puts "hostname=#{Discourse.current_hostname} notification_email=#{SiteSetting.notification_email} vapid_base_url=#{SiteSetting.vapid_base_url}"
EOF
sudo docker cp /tmp/domain-remap.rb app:/tmp/domain-remap.rb
sudo docker exec app bash -lc "chown discourse /tmp/domain-remap.rb && cd /var/www/discourse && su discourse -c 'RAILS_ENV=production bundle exec rails runner /tmp/domain-remap.rb'" 2>&1 | grep -vE '^\s*$|warning' | sed 's/^/  /' \
  || warn "remap failed — manual: cd /var/discourse && sudo ./launcher enter app && rake posts:remap[\"forum.$OLD\",\"forum.$NEW\"]"

# ---------------------------------------------------------------- summary
log "Done"
cat <<EOF
  Site    https://$NEW        admin: https://$NEW/ghost
  Forum   https://forum.$NEW
  Mail    $MAIL_MODE$( [[ $MAIL_MODE == keep-old ]] && printf ' — still sending as noreply@%s; validate %s in Mailjet then re-run this script' "$OLD" "$NEW" || true)
  Backups $BK

Follow-ups (operator, not automated):
  - Ghost Admin -> Settings -> Email newsletter: Mailgun domain is still "$OLD"
    (create/verify $NEW in Mailgun EU before changing it; newsletters unused so far).
  - Ghost Admin -> Settings -> Title / meta / social accounts: check nothing else mentions $OLD.
  - Umami website "domain" field is the raw IP: nothing to do.
  - Log in once on https://forum.$NEW (cookies are per host) and check a post with a remapped link.
  - Repo: docs already describe $NEW — commit them; remove the old $OLD redirect blocks from
    ~/lfi/caddy/Caddyfile only if/when the old domain stops pointing here.
EOF
