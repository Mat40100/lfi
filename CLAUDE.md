# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A self-hosted [Ghost](https://ghost.org/) blog deployed with Docker Compose. There is no application code — the repo is infrastructure config only:

- `docker-compose.yml` — six services: `ghost` (custom image), `mysql` (MySQL 8), `caddy` (reverse proxy / TLS), plus self-hosted web analytics for Ghost 6's native Analytics screens: `tinybird-local` (custom thin image over `tinybirdco/tinybird-local`, internal only), `tinybird-deploy` (one-shot: `tb` CLI + Ghost's Tinybird project, re-run on every `up`) and `traffic-analytics` (Ghost's official page-hit proxy). Runbook + gotchas: **`docs/analytics-tinybird.md`**.
- `ghost/Dockerfile` — extends `ghost:6-alpine`; adds bash, curl, tzdata, mariadb-client and a healthcheck
- `tinybird/` (deploy image + `entrypoint.sh` with `deploy` / `tokens` / `tb …` sub-commands), `tinybird-local/` (ClickHouse memory override + supervisord trim)
- `caddy/Caddyfile` — single site block; the address comes from `CADDY_SITE_ADDRESS` (default `:80` for local, a domain in prod → automatic Let's Encrypt). Two analytics routes inside it: `/.ghost/analytics/*` → traffic-analytics, `/.ghost/tinybird/v0/pipes/*` → tinybird-local (everything else under `/.ghost/tinybird/` is 403).
- `Makefile` — `dev`, `prod` (validates `.env` before launching; both end with `scripts/analytics-init.sh`), `analytics-init`, `down`, `logs`, `ps`
- `scripts/analytics-init.sh` — idempotent analytics bootstrap: waits for `tinybird-deploy`, writes `TINYBIRD_WORKSPACE_ID/ADMIN_TOKEN/TRACKER_TOKEN` into `.env`, recreates ghost + traffic-analytics when they change
- `.env` (from `.env.example`, git-ignored) — `GHOST_URL`, `CADDY_SITE_ADDRESS` + MySQL credentials (compose fails fast if passwords are unset) + the generated `TINYBIRD_*` values (never hand-edit) + `TINYBIRD_MEMORY_LIMIT` (default 4g)

## Architecture

Three Docker networks isolate traffic: `web` (caddy ↔ ghost), `internal` (ghost ↔ mysql) and `analytics` (caddy ↔ traffic-analytics/tinybird-local, traffic-analytics + tinybird-deploy ↔ tinybird-local). MySQL is never exposed to caddy, the host or the analytics services. Ghost waits on mysql's healthcheck before starting; it does NOT depend on the analytics services (analytics must never block the site). Caddy is the only service publishing ports (80/443).

Ghost reaches Tinybird through its **own public URL** (`tinybird__stats__endpoint=$GHOST_URL/.ghost/tinybird`) — on purpose: in production Ghost's outbound HTTP client refuses single-label hosts / private IPs (SSRF guard) unless the host is the site's host, and the Ghost Admin browser uses the same endpoint. Verified on prod that the ghost container can reach `https://adour-en-commun.fr/` (hairpin through Caddy's published port).

All persistent state lives in bind mounts under `./data/` (git-ignored): `data/ghost-content`, `data/mysql`, `data/caddy/data`, `data/caddy/config`, `data/tinybird/{clickhouse,redis}`, `data/traffic-analytics`. Keep the Ghost dir pre-created — if Docker creates it it's owned by root and Ghost (uid 1000) can't write its content dir (the tinybird/traffic-analytics containers run as root, so Docker may create theirs).

MySQL runs with `--default-authentication-plugin=mysql_native_password` because Ghost requires the classic auth plugin — don't remove it.

## Commands

```bash
make dev                         # build & start locally (requires .env), then analytics bootstrap
make prod                        # production launch — checks GHOST_URL/CADDY_SITE_ADDRESS first, then analytics bootstrap
make analytics-init              # (re)deploy Ghost's Tinybird pipes + write TINYBIRD_* tokens into .env
make logs / make ps / make down
docker compose config --quiet    # validate compose file (needs MYSQL_* vars set)
docker compose pull && docker compose build --pull && docker compose up -d   # update (tinybird-deploy re-syncs pipes on `up`)
docker compose run --rm tinybird-deploy tb --local sql "select count() from analytics_events"   # poke Tinybird
```

Site: `http://localhost/` — admin: `http://localhost/ghost`.

Going to production: currently IP-only — `GHOST_URL=http://<public-ip>` in `.env`, `CADDY_SITE_ADDRESS` unset (plain HTTP on :80), `make prod`. Once a domain exists: `GHOST_URL=https://<domain>` + `CADDY_SITE_ADDRESS=<domain>`, open ports 80/443 (see readme.md for the full procedure, plus backup commands).

## Production server

- **Host:** `37.59.103.153` (OVH, eu-west, Ubuntu cloud image), domain **`adour-en-commun.fr`** (+ `www`), DNS on OVH nameservers. Previous domains `landes-insoumises.fr` (until 2026-09-23) and `lol-reminder.fr` (until 2026-07-31) 301-redirect to it while their DNS still points at the box.
- **Domain cutover done 2026-09-23** (`landes-insoumises.fr → adour-en-commun.fr`) with `scripts/domain-cutover-adour.sh` (idempotent; runbook + gotchas in `docs/forum-discourse.md` → "Domain migration"). Rollback material: `~/domain-cutover-backup-20260923-*/` on the server. Ghost's Mailgun newsletter domain is still `landes-insoumises.fr` (operator step, see docs).
- **URL:** served over **HTTPS** — `GHOST_URL=https://adour-en-commun.fr`, `CADDY_SITE_ADDRESS=adour-en-commun.fr www.adour-en-commun.fr`. Caddy auto-manages the Let's Encrypt cert; `www` and `:80` redirect to the apex HTTPS site.
- **Ghost is public** (private mode OFF; newsletter signup open to all). Toggle in Ghost Admin → Settings → Access. Ghost members and forum accounts are unrelated — the forum is standalone (see below).
- **Box size:** 4 vCPU / 7.7 GB RAM / 72 GB disk. Discourse (~1.7 GB) + Tinybird Local (~1.6 GB idle, capped at 4 GB) + Ghost/MySQL/Caddy (~0.5 GB) — watch `free -m` / `docker stats` before adding anything else.
- **Umami incident (2026-09-23):** the former Umami container (`ghcr.io/umami-software/umami:mysql-v2.16`, Next.js 15.0.4, exposed on :8080) was compromised through the React Server Components RCE and ran a cryptominer (`/tmp/.ICEi-unix/javae`, `/tmp/dashboard`) as the container's `nextjs` user for ~5 days (4 GB RAM, all CPUs). Confined to the container (unprivileged, no binds; host cron/ld.so.preload/authorized_keys clean). Umami was **removed from the stack** the same day (`scripts/analytics-deploy-prod.sh`: container + image removed, leaked `umami` MySQL user dropped, tracker `<script>` stripped from Ghost's `codeinjection_head`; the `umami` MySQL database was kept — drop it when no longer wanted). Ghost's own Analytics (Tinybird) replaces it. Never re-expose an app on a bare port; put it behind a Caddy site block and keep images patched.
- **SSH:** `ssh ubuntu@37.59.103.153 -i ~/.ssh/id_lfi` — login user is `ubuntu`, key-only auth. The `id_lfi` ed25519 keypair lives on this workstation (`~/.ssh/id_lfi` / `.pub`); its public key is authorized on the box.
- If you hit `Too many authentication failures`, the client is offering too many keys before the right one — force it: add `-o IdentitiesOnly=yes`, or use a `Host` entry in `~/.ssh/config` pinning `IdentityFile ~/.ssh/id_lfi`.

### Prod-only config not in this repo

The live stack lives in `~/lfi` on the server. It tracks this repo (Ghost + MySQL + Caddy + Tinybird analytics), plus a few **server-only additions** — so edit prod config **on the server** and recreate there (`docker compose up -d <svc>`, or `docker compose restart caddy` after a Caddyfile change — `caddy reload` fails silently in this setup); don't assume a local `make prod` reproduces it:

- **Transactional email (SMTP)** is configured via a server-side `docker-compose.override.yml` that adds `mail__*` env to the `ghost` service; values live in the server `.env` (`MAIL_FROM`, `SMTP_HOST/PORT/SECURE/USER/PASS`). Provider: **Mailjet** (`in-v3.mailjet.com:465` SSL), sending as `noreply@adour-en-commun.fr` (sender domain must be SPF+DKIM-validated in Mailjet — Ghost's member magic-links go out as `noreply@<GHOST_URL host>`). This covers staff invites + member magic-links (NOT bulk newsletters — that's Mailgun-only in Ghost). The domain is SPF+DKIM authenticated (`spf.mailjet.com`, `mailjet._domainkey`); bulk newsletters (Mailgun EU) still use the `landes-insoumises.fr` Mailgun domain until a new one is verified. Secrets are only in the server `.env` — never commit them.
- **Forum (Discourse, standalone)** — a private team forum at `forum.adour-en-commun.fr`, installed OUTSIDE this compose stack via Discourse's own launcher in `/var/discourse` (standalone container, Postgres+Redis embedded), joined to the `lfi_web` network so Caddy can proxy it (server-only `forum.` site block in the prod Caddyfile). Accounts are Discourse-native: `login_required` + `invite_only` (admins invite people from Discourse). The former Ghost-SSO bridge (Discourse-on-Ghost connector, Équipe tier gate, team invite console) was **removed on 2026-09-05** — do not reintroduce a Ghost↔forum link. Runbook: **`docs/forum-discourse.md`**.
- **Auto-publishing to Facebook/Instagram (n8n)** — planned but NOT deployed; implementation plan in **`docs/n8n-social-publishing.md`**.
- **Web analytics rollout (2026-09-23)** via `scripts/analytics-deploy-prod.sh` (idempotent; backups + Umami forensic copies in `~/analytics-deploy-backup-<ts>/` on the server). The server Caddyfile got the two analytics routes inserted by that script — it is NOT the repo Caddyfile (server-only forum/redirect blocks), so future route changes must be applied on the server too.
- **Theme** = the stock Source bundled with the Ghost image, via symlink `data/ghost-content/themes/source -> /var/lib/ghost/current/content/themes/source` (translated since Ghost 6; the fr locale works out of the box). Historical note: under Ghost 5 a manual Source v1.6.1 copy was needed for French — leftovers `source-161.manual` / `source-171.broken` next to the symlink are safe to delete.

### Recovery via OVH rescue mode (locked out of SSH)

1. OVH Manager → server → **Boot → Rescue → reboot**. OVH emails temporary `root` rescue credentials (short-lived — don't commit them).
2. SSH in as rescue `root`. If the client won't reach the password prompt, force password-only: `ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new root@37.59.103.153`.
3. Disk layout: `sda1` = real root (`cloudimg-rootfs`), `sda16` = `/boot`, `sda15` = EFI, `sdb1` = the rescue OS (ignore). Mount + chroot:
   ```bash
   mount /dev/sda1 /mnt && mount /dev/sda16 /mnt/boot && mount /dev/sda15 /mnt/boot/efi
   for d in dev proc sys run; do mount --rbind /$d /mnt/$d; done
   chroot /mnt /bin/bash
   ```
4. Fix auth (add pubkey to `/home/ubuntu/.ssh/authorized_keys`, `chown ubuntu:ubuntu`, `chmod 700` dir / `600` file; or `passwd ubuntu`).
5. `exit`, `umount -R /mnt`, then OVH Manager → **Boot → Hard disk → reboot**.

## Clipboard

To copy text to the local clipboard, pipe data to the appropriate command.

### Local shells
- macOS: `echo "text" | pbcopy`
- Linux (X11): `echo "text" | xclip -selection clipboard`
- Windows: `echo "text" | clip`
- WSL2: `echo "text" | clip.exe`

### SSH / remote shells
When running over SSH, use OSC 52 to write to the local clipboard:

`echo "text" | printf '\e]52;c;%s\a' "$(base64 | tr -d '\n')"`
