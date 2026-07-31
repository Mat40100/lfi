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
  - [x] DNS `A forum.lol-reminder.fr → 37.59.103.153` (OVH zone)
  - [x] Admin email = `mathieu.dolhen@gmail.com`
- [x] **Phase 1a** — `git clone discourse_docker → /var/discourse`
- [x] **Phase 1b** — `containers/app.yml` (hostname `forum.`, Mailjet SMTP, locale fr, `expose: []`, no Discourse TLS); bootstrapped OK, container `app` running (`--restart=always`)
- [x] **Phase 2** — `app` joined to `lfi_web`; Caddy `forum.lol-reminder.fr` block added; HTTPS live (LE cert issued via TLS-ALPN-01). Forum reachable, shows `finish_installation`.
- [x] **Phase 3** — admin account created + activated via Mailjet email: `mathieu.d <mathieu.dolhen@gmail.com>` (active, approved). Confirms Discourse SMTP works end-to-end.
- [x] **Phase 4** — DoG built (pinned `lfi-dog:v0.3.0`) + deployed as `dog` service (compose override, network `web`, `dog/dog.env`); Caddy `handle`s the `/ghost/api/external_discourse_on_ghost/*` prefix → `dog:3286`, everything else → Ghost. Public `/health` → `Howdy!`. Discourse API key generated via rails; HMAC secret + webhook IDs generated.
- [x] **Phase 5** — SSO wired. 2 Ghost webhooks created (`member.edited`/`member.deleted` → DoG `hook/<id>`). Ghost member `mathieu.dolhen@gmail.com` created so the Discourse admin survives SSO. DiscourseConnect enabled via rails (`enable_discourse_connect=true`, url→DoG `/sso`, secret = `DOG_DISCOURSE_SHARED_SECRET`). Redirect chain verified end-to-end (Discourse→DoG→Ghost; HMAC accepted).
  - ⚠️ **Ghost private-mode (site password) conflicts with member login**: it redirects the whole front-end to `/private/`, so members can't reach the portal to sign in for SSO. Decide: turn OFF Ghost private mode (recommended — gate the *forum* via Discourse `login_required` instead), or keep it and accept the friction.
  - Rollback if locked out: `docker exec app rails r 'SiteSetting.enable_discourse_connect=false'`.
- [x] **Phase 6** — forum set 100% private: `login_required=true` (+ `must_approve_users=false`). Anonymous hits `forum/` → 302 to `/session/sso` (nothing visible without a Ghost-member SSO login). DoG auto-maps Ghost tiers → Discourse groups on member sync.
  - **Decision (user, superseded):** private mode was initially kept, later turned OFF (site is public, newsletter signup open — see Phase 7).
  - **Remaining = manual browser tests** (need a real member session): (a) a Ghost member can log into the forum via SSO; (b) cancelling/deleting a member removes forum access via the webhooks; (c) confirm no local Discourse login is possible.
- [x] **Phase 7 (2026-07-21) — Équipe tier gate + invite console.** Newsletter signup is now public (`members_signup_access=all`), so forum access is restricted to members holding the hidden **Équipe tier** (id `6a5f456f593d38000179072b`, slug `equipe`, visibility none, created via Admin API — works without Stripe, comped via `PUT /members/<id>` with `tiers:[{id}]`).
  - **DoG tier gate** — image `lfi-dog:v0.3.0-lfi.1` = pinned v0.3.0 + `dog/tier-gate.patch` (applied in the Dockerfile). SSO is refused to members without an active `DOG_SSO_REQUIRED_TIER_SLUG` (=`equipe`) tier; they are 302'd to `DOG_SSO_DENIED_REDIRECT` (=`https://lol-reminder.fr/equipe/reserve`). Both vars in `dog/dog.env`.
  - **Team console** (`console/`, image `lfi-console:v1.0.0`) — plain Node + nodemailer, service `console` in the server compose override, state in `data/console/invites.json`. Admin page `https://lol-reminder.fr/equipe/admin` (Caddy `basic_auth`, user `mathieu`): create invite → e-mail sent via Mailjet with a single-use, 7-day, email-bound link `/equipe/invite/<token>`; accepting creates/updates the Ghost member with label `equipe` + comped Équipe tier and triggers a Ghost magic-link. Also serves `/equipe/reserve` (denied landing) and `/equipe/health`. Config: `console/console.env` (server-only; template in `console/console.env.example`).
  - **Tested end-to-end** (invite → mail → accept → member+tier → magic-link). Remaining manual check: a tierless member hitting the forum should land on `/equipe/reserve`.

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

Repo: https://github.com/vikaspotluri123/discourse-on-ghost — small Node/TS service.
**No official Docker image**, so we build one from **pinned, audited source**.

**Security audit (option B).** Pinned commit **`74f3a32a12d33bb50d898f070930314faba6a650`**
(= tag `v0.3.0`). Reviewed: no `child_process`/`exec`/`eval`/`vm`; network egress
only to the configured Ghost/Discourse URLs; `process.env` only maps `DOG_*` config
(no exfiltration); deps minimal + reputable (`@tryghost/*`, `express`, `node-fetch`,
`dotenv`); no pre/postinstall scripts; standard WebCrypto HMAC-SHA256. Built with
`git checkout <commit>` + `yarn install --frozen-lockfile`.

Build: `~/lfi/dog/Dockerfile` → image `lfi-dog:v0.3.0`. Runs as a service in the
`~/lfi` compose stack (network `web`), listening on `0.0.0.0:3286`
(`DOG_HOSTNAME=0.0.0.0`). Caddy proxies the path prefix
`/ghost/api/external_discourse_on_ghost/*` (on `lol-reminder.fr`) to `dog:3286`.

Routes DoG exposes under that prefix (verified in source): `sso`, `health`
(→ `{"message":"Howdy!"}`), `hook/<webhook_id>` (POST), `admin/sync-tiers`,
`admin/clear-caches`. **Note:** webhook path is `.../hook/<ID>`, not `.../<ID>`.

`.env` keys (values only in the server `.env`, never committed):
```
DOG_GHOST_URL=https://lol-reminder.fr
DOG_GHOST_ADMIN_TOKEN=<id:secret from a Ghost custom integration>
DOG_DISCOURSE_URL=https://forum.lol-reminder.fr
DOG_DISCOURSE_API_KEY=<Discourse admin API key>
DOG_DISCOURSE_SSO_TYPE=session
DOG_GHOST_MEMBER_DELETE_DISCOURSE_ACTION=suspend
DOG_GHOST_MEMBER_WEBHOOKS_ENABLED=true
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
3. Ghost custom integration → **Add webhook** ×2 (note the `/hook/` segment):
   - `Member updated` → `…/ghost/api/external_discourse_on_ghost/hook/<DOG_GHOST_MEMBER_UPDATED_WEBHOOK_ID>`
   - `Member deleted` → `…/ghost/api/external_discourse_on_ghost/hook/<DOG_GHOST_MEMBER_DELETED_WEBHOOK_ID>`

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

**Operator TODO (Ghost Admin UI — cannot be done via API)**
Ghost blocks editing these settings through an integration Admin API key
(every settings `PUT` returns `501 NotImplementedError`); they must be changed
by a staff user in Ghost Admin, or (simple JSON fields only) via a direct
`settings` table write + `docker compose restart ghost`:
- **Members were disabled** on this blog (`members_enabled=false`,
  `members_signup_access=none`) — the whole forum-SSO needs Ghost members. Set
  **Settings → Membership → Access → Subscription access = "Only people I invite"**.
- **Ghost private mode** (`is_private`, site password) redirects the whole
  front-end to `/private/`, hiding the members portal so nobody can sign in for
  SSO. Turn it **off** (Settings → search "private"); the forum stays private via
  Discourse `login_required`.
- The **"Forum" nav link** (`https://forum.lol-reminder.fr/`) was added to
  `settings.navigation` via a direct MySQL write + `restart ghost` (the API 501s).

**Gotchas**
- **Ghost settings are read-only over the integration Admin API** — see the
  Operator TODO above; use the Admin UI (or DB + restart for trivial fields).
- **Ghost Admin API auth only works via the canonical public URL** — the same
  integration JWT gets `403 Authorization failed` on `http://ghost:2368` but 200
  on `https://lol-reminder.fr`. Point every API client (DoG, console) at the
  public URL.
- **`docker compose restart` does NOT reload `env_file` changes** — use
  `docker compose up -d --force-recreate <svc>` after editing a service's env file.
- **Applying Caddyfile changes:** `caddy reload` (via the admin API on `:2019`)
  does NOT work in this setup — the admin endpoint is unreachable, so a reload
  fails **silently** and the old config keeps running (symptom: new site gets
  auto-HTTPS 308s but no cert is ever issued, and its requests log as JSON
  instead of the block's console format). Apply changes with
  `docker compose restart caddy` instead (~1-2 s blip, reads the Caddyfile fresh).
- After every `./launcher rebuild app`, the `app` container drops off `lfi_web`
  (rebuild recreates it). Re-run `docker network connect lfi_web app` or Caddy
  can't reach it (502). Verify with
  `docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' app`.
- SMTP sender must stay `@lol-reminder.fr` (SPF/DKIM authenticated for Mailjet).
- DiscourseConnect is free on self-hosted Discourse (no paid plan needed).

## Sources
- DoG: https://github.com/vikaspotluri123/discourse-on-ghost
- LinuxHandbook — Ghost SSO + Discourse: https://linuxhandbook.com/ghost-sso-discourse/
- Discourse Meta — Introducing Discourse on Ghost: https://meta.discourse.org/t/257108
