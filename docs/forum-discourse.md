# Forum — Discourse (standalone)

> **Living runbook** for the private team forum at `https://forum.landes-insoumises.fr`.
>
> ⚠️ **This install lives OUTSIDE this repo's `docker-compose.yml`.** Discourse's only
> officially supported install is its own `discourse_docker` launcher in `/var/discourse`
> on the prod server — a standalone container (Postgres + Redis embedded) managed with
> `./launcher`, **not** `docker compose`. It is wired to the main stack only at the Docker
> **network** level (`lfi_web`) and through Caddy. Treat this file as the source of truth
> for that out-of-band piece; keep it updated as things change.

## History — the Ghost SSO bridge (2026-07 → 2026-09-05) is gone

From July 2026 the forum used **Ghost as SSO identity provider**: a *Discourse-on-Ghost*
(DoG) connector in the compose stack, patched with an "Équipe tier" gate, plus a *team
console* that e-mailed invites and comped the tier on the Ghost member. We did not like
coupling forum access to Ghost membership, so on **2026-09-05** the whole bridge was
removed and the forum returned to **standalone Discourse accounts**:

- Discourse: `enable_discourse_connect=false`, DoG API key / SSO records / `tier_equipe` group deleted.
- Ghost: custom integration "Forum" (+ its 2 `member.*` webhooks), the hidden Équipe tier
  and the `equipe` label deleted; former comped members are plain free members.
- Compose: `dog` and `console` services removed from the server override; Caddy no longer
  routes `/ghost/api/external_discourse_on_ghost/*`, `/ghost/console*`, `/equipe/*`.
- Repo: `dog/` and `console/` deleted (see `git log -- dog console` for the code).
- Rollback material on the server: `~/sso-teardown-backup-20260905/` (old override,
  Caddyfile, `dog.env`, `console.env`, `data/console`, dump of the Ghost tables touched).
  Teardown script: `~/sso-teardown.sh`.

Ghost and the forum are now **independent**: newsletter signup on the site is public and
grants nothing on the forum; the "Forum" link in Ghost's navigation is just a link.

## Coordinates

| | |
|---|---|
| Server | `37.59.103.153` (OVH, Ubuntu) — `ssh ubuntu@37.59.103.153 -i ~/.ssh/id_lfi` |
| Forum | `https://forum.landes-insoumises.fr` (Discourse, behind Caddy) |
| Discourse install | `/var/discourse` (launcher), container name `app` |
| Data | `/var/discourse/shared/standalone` (Postgres, uploads, backups) |
| Compose network shared with Caddy | `lfi_web` |
| Email | Mailjet SMTP (`in-v3.mailjet.com`), sender `noreply@landes-insoumises.fr` |
| Admins | `mathieu.d`, `Jean-Robert_DASSE` |

## Architecture

```
Browser → forum.landes-insoumises.fr ──(Caddy, TLS)──► Discourse `app`:80 (Postgres+Redis internal)
                                                        accounts, login, invites: Discourse itself
Browser → landes-insoumises.fr        ──(Caddy, TLS)──► Ghost  (no relation to forum accounts)
```

Caddy (the compose service) is the single TLS terminator for **all** hostnames:
`landes-insoumises.fr` (Ghost), `forum.landes-insoumises.fr` (Discourse), `:8080` (Umami).
Discourse does **not** manage its own certs (its Let's Encrypt templates are disabled) and
does **not** publish 80/443 (`expose: []` — Caddy owns them). Caddy reaches the `app`
container by name over `lfi_web`.

## Access model (standalone)

Discourse site settings (all set, verified 2026-09-05):

| Setting | Value | Effect |
|---|---|---|
| `login_required` | `true` | Nothing is visible anonymously — the forum is 100 % private. |
| `invite_only` | `true` | No self-signup. New people get in only through a **Discourse invite** (Admin → Utilisateurs → Inviter, or the "Inviter" button in the user menu); the invite e-mail goes out via Mailjet and the invitee picks a password. |
| `enable_local_logins` / `enable_local_logins_via_email` | `true` | Password login **and** "connexion par lien e-mail". |
| `must_approve_users` | `false` | No manual approval step. |
| `force_https` | `true` | |

**Users created during the SSO era have no password.** They use « Mot de passe oublié »
(or the e-mail-link login) once on `https://forum.landes-insoumises.fr/login`; the mail
arrives from `noreply@landes-insoumises.fr`.

Category visibility: all categories are public *inside* the forum (no group restriction).
Restrict a category to a group via Category → Sécurité if needed.

## Discourse config (`/var/discourse/containers/app.yml`)

Based on `samples/standalone.yml`. Key settings for **this** deployment:

```yaml
# Do NOT bind 80/443 on the host — Caddy owns them. Caddy reaches the container
# over lfi_web by name (app:80).
expose: []

# Disable Discourse's own TLS (Caddy terminates TLS):
#   -> templates/web.ssl.template.yml and templates/web.letsencrypt.ssl.template.yml removed

env:
  DISCOURSE_HOSTNAME: forum.landes-insoumises.fr
  DISCOURSE_DEVELOPER_EMAILS: "<ADMIN_EMAIL>"       # becomes admin; must be readable
  DISCOURSE_NOTIFICATION_EMAIL: noreply@landes-insoumises.fr

  # SMTP = Mailjet (same account as Ghost; creds in the server ~/lfi/.env)
  DISCOURSE_SMTP_ADDRESS: in-v3.mailjet.com
  DISCOURSE_SMTP_PORT: 587
  DISCOURSE_SMTP_USER_NAME: "<MAILJET_API_KEY>"
  DISCOURSE_SMTP_PASSWORD: "<MAILJET_SECRET_KEY>"
  DISCOURSE_SMTP_ENABLE_START_TLS: true
```

Apply changes / upgrade: `cd /var/discourse && sudo ./launcher rebuild app` (~10–15 min),
then **re-attach the network** (see Gotchas).

## Caddy wiring (server-only block in `~/lfi/caddy/Caddyfile`)

The repo's `caddy/Caddyfile` is the generic Ghost + Umami file; the prod copy adds one
block (this is why `git status` on the server shows `caddy/Caddyfile` modified):

```
# Discourse forum (out-of-band install in /var/discourse; container `app` on lfi_web).
forum.landes-insoumises.fr {
    reverse_proxy app:80
    encode gzip zstd
    log {
        output stdout
        format console
    }
}
```

Apply with `docker compose restart caddy` (not `caddy reload`, see Gotchas). Validate
first: `docker compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile`.

## Operations

```bash
# All Discourse ops run from /var/discourse as root on the server.
cd /var/discourse
sudo ./launcher logs app           # tail logs
sudo ./launcher enter app          # shell inside the container
sudo ./launcher restart app        # restart
sudo ./launcher rebuild app        # apply app.yml changes / upgrade (recreates the container)
sudo ./launcher cleanup            # prune old images

# Site settings / one-off admin from the CLI (rails runner, ~30 s to boot):
sudo docker exec app bash -lc "cd /var/www/discourse && su discourse -c 'RAILS_ENV=production bundle exec rails runner \"puts SiteSetting.login_required\"'"

# Backups: Admin → Sauvegardes (or `discourse backup` inside the container).
# Data lives in /var/discourse/shared/standalone (Postgres, uploads, backups).
```

## Gotchas

- **After every `./launcher rebuild app`, the `app` container drops off `lfi_web`**
  (rebuild recreates it). Re-run `docker network connect lfi_web app` or Caddy answers 502.
  Verify with `docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' app`.
- **Applying Caddyfile changes:** `caddy reload` (admin API on `:2019`) does NOT work in
  this setup — the reload fails **silently** and the old config keeps running (symptom: a
  new site block gets auto-HTTPS 308s but no cert is ever issued). Use
  `docker compose restart caddy` (~1–2 s blip).
- **`docker compose restart` does NOT reload `env_file`/environment changes** — use
  `docker compose up -d --force-recreate <svc>` after editing a service's env.
- **Ghost settings are read-only over an integration Admin API key** (every settings `PUT`
  returns `501`): change them in Ghost Admin, or (simple JSON fields) via a direct
  `settings` table write + `docker compose restart ghost`. The "Forum" nav link was added
  that way (`settings.navigation`).
- **Ghost Admin API auth only works via the canonical public URL** (`https://landes-insoumises.fr`),
  not `http://ghost:2368` (403).
- SMTP sender must stay `@landes-insoumises.fr` (SPF/DKIM authenticated for Mailjet).
- Discourse requires swap: 2 GB `/swapfile` is persisted in `/etc/fstab`.
- OVH DNS: when adding a record, OVH leaves its parking `A 213.186.33.5` in place — it must
  be *deleted*, not just supplemented (bit us during the domain migration of 2026-07-31).

## Install log (condensed)

- 2026-07 — swap, DNS `A forum → 37.59.103.153`, `discourse_docker` cloned to `/var/discourse`,
  `app.yml` (Mailjet SMTP, locale fr, `expose: []`, no Discourse TLS), bootstrapped; `app`
  joined to `lfi_web`; Caddy forum block; LE cert issued; admin account activated by e-mail.
- 2026-07 → 2026-08 — Ghost SSO era (DoG + tier gate + team console). Domain migration
  `lol-reminder.fr → landes-insoumises.fr` on 2026-07-31 (`DISCOURSE_HOSTNAME` + rebuild).
- **2026-09-05 — SSO removed, forum standalone** (see History above).

## Sources
- Discourse install: https://github.com/discourse/discourse_docker
- Discourse invites: https://meta.discourse.org/t/how-to-invite-users-to-a-private-site
