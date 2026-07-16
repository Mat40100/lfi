# Private forum — Discourse + Ghost SSO (Discourse-on-Ghost)

> **Living runbook.** This documents a members-only forum built with **Discourse**
> (forum engine) using **Ghost as the SSO identity provider**, bridged by
> **Discourse-on-Ghost (DoG)**. Ghost owns accounts + billing; Discourse is the
> forum; DoG maps Ghost tiers → Discourse groups.
>
> ⚠️ **This install lives OUTSIDE this repo's `docker-compose.yml`.** Discourse's
> only officially supported install is its own `discourse_docker` launcher in
> `/var/discourse` on the prod server — a standalone container (Postgres + Redis
> embedded), managed with `./launcher`, **not** `docker compose`. Treat this file
> as the source of truth for that out-of-band piece; keep it updated as things change.

## Coordinates

| | |
|---|---|
| Server | `37.59.103.153` (OVH, Ubuntu) — `ssh ubuntu@37.59.103.153 -i ~/.ssh/id_lfi` |
| Ghost site | `https://lol-reminder.fr` (private mode) |
| Forum | `https://forum.lol-reminder.fr` (Discourse, behind Caddy) |
| Discourse install | `/var/discourse` (launcher), container name `app` |
| DoG | container in the main `~/lfi` compose stack (Node service) |
| Compose network shared with Caddy | `lfi_web` |
| Email | Mailjet SMTP (`in-v3.mailjet.com`), sender `noreply@lol-reminder.fr` |

## Architecture

```
Member → forum.lol-reminder.fr ──(Caddy, TLS)──► Discourse app:80 (Postgres+Redis internal)
   "Login" → DiscourseConnect →
        https://lol-reminder.fr/ghost/api/external_discourse_on_ghost/sso
                    │  (Caddy routes THIS path prefix to DoG, not to Ghost)
                    ▼
              DoG (Node) ──► Ghost Admin API (verify member + tier)
                    │
                    ▼  HMAC-signed identity
        member logged into Discourse, placed in the group mapped from the Ghost tier
```

Caddy (already running, in a container) is the single TLS terminator for **all**
hostnames: `lol-reminder.fr` (Ghost), `forum.lol-reminder.fr` (Discourse),
`:8080` (Umami). Discourse does **not** manage its own certs (its Let's Encrypt
template is disabled) and does **not** publish 80/443 (Caddy owns those). Caddy
reaches Discourse container-to-container over the `lfi_web` network.

## Why external to docker-compose

Discourse upstream only supports the launcher install. Do **not** try to fold it
into `~/lfi/docker-compose.yml`. The two stacks coexist on the same host and are
wired together only at the Docker **network** level (`lfi_web`) and via Caddy.

---

## Install log / progress

- [x] **Phase 0 — prerequisites**
  - [x] 2 GB swap created + persisted (`/swapfile`, in `/etc/fstab`) — Discourse requires swap
  - [ ] DNS `A forum.lol-reminder.fr → 37.59.103.153` (OVH zone) — *user action*
  - [ ] Admin email chosen (a mailbox the operator can actually read; **not** `@lol-reminder.fr`)
- [x] **Phase 1a** — `git clone discourse_docker → /var/discourse`
- [ ] **Phase 1b** — configure `containers/app.yml` + bootstrap
- [ ] **Phase 2** — Caddy `forum.lol-reminder.fr` block; verify HTTPS
- [ ] **Phase 3** — create/activate Discourse admin account
- [ ] **Phase 4** — deploy DoG + Caddy route for the DoG path prefix
- [ ] **Phase 5** — wire SSO (Ghost custom integration + 2 webhooks; enable DiscourseConnect)
- [ ] **Phase 6** — private categories, tier→group mapping, acceptance tests

---

## Phase 1b — Discourse config (`/var/discourse/containers/app.yml`)

Base it on `samples/standalone.yml`. Key settings for **this** deployment:

```yaml
# Do NOT bind 80/443 on the host — Caddy owns them. Expose nothing to the host;
# Caddy reaches the container over the lfi_web network by name (app:80).
expose: []

# Disable Discourse's own TLS (Caddy terminates TLS).
#   -> remove templates/web.ssl.template.yml and templates/web.letsencrypt.ssl.template.yml

env:
  DISCOURSE_HOSTNAME: forum.lol-reminder.fr
  DISCOURSE_DEVELOPER_EMAILS: "<ADMIN_EMAIL>"       # becomes admin; must be readable
  DISCOURSE_NOTIFICATION_EMAIL: noreply@lol-reminder.fr

  # SMTP = Mailjet (same creds as Ghost; see server ~/lfi/.env)
  DISCOURSE_SMTP_ADDRESS: in-v3.mailjet.com
  DISCOURSE_SMTP_PORT: 587
  DISCOURSE_SMTP_USER_NAME: "<MAILJET_API_KEY>"
  DISCOURSE_SMTP_PASSWORD: "<MAILJET_SECRET_KEY>"
  DISCOURSE_SMTP_ENABLE_START_TLS: true
```

Connecting the container to Caddy's network — after bootstrap the launcher's
`app` container must join `lfi_web`. Preferred: add a launcher hook so it survives
`./launcher rebuild app` (details recorded here once implemented).

Bootstrap + start:
```bash
cd /var/discourse
sudo ./launcher rebuild app     # ~10–15 min build
```

## Phase 2 — Caddy wiring (`~/lfi/caddy/Caddyfile`)

Add a site block for the forum (Caddy fetches the LE cert once DNS resolves):
```
forum.lol-reminder.fr {
    reverse_proxy app:80          # 'app' = Discourse container on lfi_web
    encode gzip zstd
}
```
Caddy service must share the `lfi_web` network with the Discourse container.
Reload with `docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile`.

## Phase 4 — DoG (Discourse-on-Ghost)

Repo: https://github.com/vikaspotluri123/discourse-on-ghost — small Node service,
added to the `~/lfi` compose stack (network `web`), reverse-proxied by Caddy under
the Ghost domain path `…/ghost/api/external_discourse_on_ghost/…`. `.env` keys
(values only in the server `.env`, never committed):

```
DOG_GHOST_URL=https://lol-reminder.fr
DOG_GHOST_ADMIN_TOKEN=<id:secret from a Ghost custom integration>
DOG_DISCOURSE_URL=https://forum.lol-reminder.fr
DOG_DISCOURSE_API_KEY=<Discourse admin API key>
DOG_DISCOURSE_SHARED_SECRET=<openssl rand -hex 32>
DOG_GHOST_MEMBER_UPDATED_WEBHOOK_ID=<openssl rand -hex 12>
DOG_GHOST_MEMBER_DELETED_WEBHOOK_ID=<openssl rand -hex 12>
```

## Phase 5 — SSO wiring

1. Ghost Admin → Settings → Integrations → **Add custom integration** → copy Admin API Key.
2. Discourse Admin → Settings → Login:
   - `enable_discourse_connect` = ✅
   - `discourse_connect_url` = `https://lol-reminder.fr/ghost/api/external_discourse_on_ghost/sso`
   - `discourse_connect_secret` = `DOG_DISCOURSE_SHARED_SECRET`
   - ⚠️ **Keep an admin session open** — enabling this disables local Discourse login (everything goes through Ghost).
3. Ghost custom integration → **Add webhook** ×2:
   - `Member updated` → `…/ghost/api/external_discourse_on_ghost/<DOG_GHOST_MEMBER_UPDATED_WEBHOOK_ID>`
   - `Member deleted` → `…/ghost/api/external_discourse_on_ghost/<DOG_GHOST_MEMBER_DELETED_WEBHOOK_ID>`

## Phase 6 — Make it private

- Discourse: restrict category read access to a **group** (Category → Security).
- DoG: map Ghost tiers → Discourse groups (paid tier → group with access).
- Optional lock-everything: Discourse `login_required` = nothing visible unless logged in (i.e. unless a Ghost member).

---

## Operations

```bash
# All Discourse ops run from /var/discourse as root on the server.
cd /var/discourse
sudo ./launcher logs app           # tail logs
sudo ./launcher enter app          # shell inside the container
sudo ./launcher restart app        # restart
sudo ./launcher rebuild app        # apply app.yml changes / upgrade (rebuilds container)
sudo ./launcher cleanup            # prune old images

# Backups: Discourse Admin → Backups (or `discourse backup` inside the container).
# Discourse data lives in /var/discourse/shared/standalone (Postgres, uploads, backups).
```

**Gotchas**
- After every `./launcher rebuild app`, re-verify the container is on `lfi_web`
  (see Phase 1b) or Caddy can't reach it.
- SMTP sender must stay `@lol-reminder.fr` (SPF/DKIM authenticated for Mailjet).
- DiscourseConnect is free on self-hosted Discourse (no paid plan needed).

## Sources
- DoG: https://github.com/vikaspotluri123/discourse-on-ghost
- LinuxHandbook — Ghost SSO + Discourse: https://linuxhandbook.com/ghost-sso-discourse/
- Discourse Meta — Introducing Discourse on Ghost: https://meta.discourse.org/t/257108
