# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A self-hosted [Ghost](https://ghost.org/) blog deployed with Docker Compose. There is no application code — the repo is infrastructure config only:

- `docker-compose.yml` — four services: `ghost` (custom image), `mysql` (MySQL 8), `caddy` (reverse proxy / TLS), `umami` (self-hosted analytics, dashboard on port 8080, shares the MySQL instance via a dedicated `umami` database)
- `ghost/Dockerfile` — extends `ghost:5-alpine`; adds bash, curl, tzdata, mariadb-client and a healthcheck
- `caddy/Caddyfile` — single site block; the address comes from `CADDY_SITE_ADDRESS` (default `:80` for local, a domain in prod → automatic Let's Encrypt)
- `Makefile` — `dev`, `prod` (validates `.env` before launching), `down`, `logs`, `ps`
- `.env` (from `.env.example`, git-ignored) — `GHOST_URL`, `CADDY_SITE_ADDRESS` + MySQL credentials; compose fails fast if passwords are unset

## Architecture

Two Docker networks isolate traffic: `web` (caddy ↔ ghost/umami) and `internal` (ghost/umami ↔ mysql). MySQL is never exposed to caddy or the host. Ghost and umami wait on mysql's healthcheck before starting. Caddy is the only service publishing ports (80/443 for Ghost, 8080 for the Umami dashboard + tracker — the tracking script is wired into Ghost via the `codeinjection_head` setting).

All persistent state lives in bind mounts under `./data/` (git-ignored): `data/ghost-content`, `data/mysql`, `data/caddy/data`, `data/caddy/config`. Keep these directories pre-created — if Docker creates them they're owned by root and Ghost (uid 1000) can't write its content dir.

MySQL runs with `--default-authentication-plugin=mysql_native_password` because Ghost requires the classic auth plugin — don't remove it.

## Commands

```bash
make dev                         # build & start locally (requires .env)
make prod                        # production launch — checks GHOST_URL/CADDY_SITE_ADDRESS first
make logs / make ps / make down
docker compose config --quiet    # validate compose file (needs MYSQL_* vars set)
docker compose pull && docker compose build --pull && docker compose up -d   # update
```

Site: `http://localhost/` — admin: `http://localhost/ghost`.

Going to production: currently IP-only — `GHOST_URL=http://<public-ip>` in `.env`, `CADDY_SITE_ADDRESS` unset (plain HTTP on :80), `make prod`. Once a domain exists: `GHOST_URL=https://<domain>` + `CADDY_SITE_ADDRESS=<domain>`, open ports 80/443 (see readme.md for the full procedure, plus backup commands).

## Production server

- **Host:** `37.59.103.153` (OVH, eu-west, Ubuntu cloud image), domain **`lol-reminder.fr`** (+ `www`), DNS on OVH nameservers.
- **URL:** served over **HTTPS** — `GHOST_URL=https://lol-reminder.fr`, `CADDY_SITE_ADDRESS=lol-reminder.fr www.lol-reminder.fr`. Caddy auto-manages the Let's Encrypt cert; `www` and `:80` redirect to the apex HTTPS site.
- **Ghost is in private mode** (members-only) — the front-end redirects to `/private/`. Toggle in Ghost Admin → Settings → Access.
- **SSH:** `ssh ubuntu@37.59.103.153 -i ~/.ssh/id_lfi` — login user is `ubuntu`, key-only auth. The `id_lfi` ed25519 keypair lives on this workstation (`~/.ssh/id_lfi` / `.pub`); its public key is authorized on the box.
- If you hit `Too many authentication failures`, the client is offering too many keys before the right one — force it: add `-o IdentitiesOnly=yes`, or use a `Host` entry in `~/.ssh/config` pinning `IdentityFile ~/.ssh/id_lfi`.

### Prod-only config not in this repo

The live stack lives in `~/lfi` on the server. It tracks this repo (Ghost + MySQL + Caddy + Umami), plus **one server-only addition** — so edit prod config **on the server** and recreate there (`docker compose up -d <svc>`, or `caddy reload` for a zero-downtime Caddyfile change); don't assume a local `make prod` reproduces it:

- **Transactional email (SMTP)** is configured via a server-side `docker-compose.override.yml` that adds `mail__*` env to the `ghost` service; values live in the server `.env` (`MAIL_FROM`, `SMTP_HOST/PORT/SECURE/USER/PASS`). Provider: **Mailjet** (`in-v3.mailjet.com:465` SSL), sending as `noreply@lol-reminder.fr`. This covers staff invites + member magic-links (NOT bulk newsletters — that's Mailgun-only in Ghost). Domain is SPF+DKIM authenticated (`spf.mailjet.com`, `mailjet._domainkey`). Secrets are only in the server `.env` — never commit them.
- **Private forum (Discourse + Ghost SSO)** — a team-only forum at `forum.lol-reminder.fr`, installed OUTSIDE this compose stack via Discourse's own launcher in `/var/discourse` (standalone container, Postgres+Redis embedded), plus a `DoG` (discourse-on-ghost) connector patched with a tier gate (`dog/tier-gate.patch`): only members with the hidden **Équipe tier** can SSO in; plain (newsletter) members are redirected to a landing page. Full runbook + install progress: **`docs/forum-discourse.md`**.
- **Team console** (`console/`, service `console` in the server override) — invite system at `https://lol-reminder.fr/equipe/admin` (Caddy basic_auth): sends single-use e-mail invites that auto-create the Ghost member with the comped Équipe tier (= forum access). Newsletter signup is public; the tier is what separates team from subscribers. Details in `docs/forum-discourse.md` (Phase 7).
- **Auto-publishing to Facebook/Instagram (n8n)** — planned but NOT deployed; implementation plan in **`docs/n8n-social-publishing.md`**.

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
