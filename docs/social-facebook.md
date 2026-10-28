# Facebook auto-share — `social-publisher`

> **Living runbook.** Every post published in Ghost is shared on the site's Facebook
> Page by a tiny service of this stack (`social-publisher/`, ~300 lines of plain
> Node, no dependencies). Built, tested locally and **deployed to production on
> 2026-10-28** (`scripts/social-deploy-prod.sh`; webhook created with
> `scripts/social-webhook.sh` on the Ghost custom integration "Facebook"). Page:
> *l'Adour en commun* (`1273835645808453`), Meta app `4573195109567373`.
>
> Instagram is **not** covered (it needs an image upload flow and a Business/Creator
> account); the n8n plan in `docs/n8n-social-publishing.md` remains the option for it.

## How it fits together

```
Ghost ── post.published webhook (HMAC-signed) ──▶ social-publisher ──▶ graph.facebook.com
      http://social-publisher.lfi.internal:8080/webhooks/ghost        POST /v26.0/{page-id}/feed
      private `social` Docker network (no Caddy, nothing public)      message + link + Page token
```

- **Trigger:** Ghost's own webhook system (Settings → Integrations → custom
  integration → webhook, event *Post published*). Scheduled posts fire it when the
  scheduler publishes them. Pages (`page.published`) are not shared.
- **Transport:** Ghost POSTs straight to the publisher over the `social` network.
  Ghost's outbound SSRF guard refuses webhook targets that resolve to private IPs,
  so the `ghost` service sets `security__allowWebhookInternalIPs=true` (only
  Administrators can create webhooks — harmless here), and because Ghost's URL
  validator rejects single-label hostnames, the publisher carries the dotted
  network alias `social-publisher.lfi.internal`. The service publishes **no port**
  and is not on the `web` network: there is nothing to attack from the internet.
- **Authentication:** every webhook is checked against `X-Ghost-Signature`
  (`sha256=HMAC-SHA256(secret, body + timestamp), t=<timestamp>`, 5-minute replay
  window). The secret is `SOCIAL_WEBHOOK_SECRET` in `.env`, entered in the
  webhook's *Secret* field in Ghost Admin.
- **Timing:** Ghost drops a webhook delivery after **2 s** and never retries a
  POST, so the publisher answers `202` immediately and does the work in the
  background: wait 5 s, check that Ghost serves the article (Facebook scrapes it
  for the preview), then call the Graph API — with retries (15 s, 1 min, 5 min) on
  rate limits / 5xx, none on permanent errors (bad token, missing permission).
- **The Facebook post:** text = the title, a blank line, the excerpt (the custom
  excerpt verbatim, else the automatic excerpt cut at ~280 chars on a word
  boundary); `link` = the article URL. Facebook renders the preview card (image,
  title, description) from the article's Open Graph tags, which Ghost generates
  from the feature image / meta fields — **always set a feature image**.
- **Rules:** skipped when the post is email-only (no public page), or carries the
  internal tag **`#no-facebook`** (slug `hash-no-facebook`, `SOCIAL_SKIP_TAG`), or
  was **already shared** (`data/social-publisher/shared-posts.json` keeps the
  Facebook post id per Ghost post id, so unpublish → republish does not post twice).
- **Ghost never depends on it:** if the publisher is down, Ghost logs a failed
  webhook delivery and the site is unaffected.

## One-time setup

### 1. Facebook side — a Page, a Meta app, a permanent Page token

The Graph API only publishes to **Pages**. A personal profile — even switched to
"professional mode" — cannot be automated. You must be an admin of the Page
(Page → Settings → Page access), with a Facebook account that can log in to
developers.facebook.com.

1. **Meta app:** <https://developers.facebook.com/apps/> → *Create app*. Any
   use case / type that offers the Pages permissions works (Meta renames these
   regularly; "Other" → "Business" was the path in 2025). Note the **App ID** and
   **App secret** (App settings → Basic). The site's app in use (created
   2026-10-28, use case "Manage everything on your Page"): **App ID
   `4573195109567373`** (put it in `.env` as `FACEBOOK_APP_ID` so
   `make facebook-token` pre-fills it). A first app, `2070468306308815`, was
   created without the Pages use case and is unused.
   **The use case only grants `pages_show_list` by default**: open it →
   *Customize* → *Permissions* and add `pages_manage_posts` and
   `pages_read_engagement` (both required to post), otherwise the Graph API
   Explorer does not even offer them and the Page token comes out without them
   (`make social-check` tells). The app can stay in *Development* mode
   forever: with *Standard Access*, Pages permissions work for people who have a
   role on the app (you), which is all we need — **no App Review, no Business
   Verification** as long as only your own Page is involved.
2. **Short-lived user token:** <https://developers.facebook.com/tools/explorer/>
   → pick the app → *Permissions*: `pages_show_list`, `pages_read_engagement`,
   `pages_manage_posts`, `pages_manage_metadata` → *Generate Access Token* → log
   in, tick the Page → copy the token (valid ~1 h — go straight to step 3).
3. **Exchange it for the permanent Page token** (in the stack checkout, locally
   or on the server; needs the image, built on first use):
   ```bash
   make facebook-token        # asks App ID, App secret, the user token
   ```
   It swaps the user token for a long-lived one, lists your Pages with their
   **never-expiring** Page tokens (verified through `debug_token`: `expires: never`,
   scopes include `pages_manage_posts`, tasks include `CREATE_CONTENT`), and
   prints the two `.env` lines. Non-interactive: `FB_APP_ID=… FB_APP_SECRET=…
   FB_USER_TOKEN=… docker compose run --rm social-publisher token`.
4. Put them in `.env` (**never commit**):
   ```
   FACEBOOK_PAGE_ID=<page id>
   FACEBOOK_PAGE_ACCESS_TOKEN=<page token>
   ```
5. `make social-check` — inspects the token through the Graph API (`debug_token`):
   type must be `PAGE`, target = your Page, scopes must include
   `pages_manage_posts` + `pages_read_engagement`, expiry `never`; then prints
   the webhook values for Ghost Admin. It also shows the token's *data access*
   expiry (~90 days after the last login through the app): if posting ever
   starts failing with `(#190)`, redo steps 2–4.

A Page token derived from a long-lived user token has no expiry, but Meta
invalidates it if that user changes their Facebook password, loses the Page
role, removes the app, or gets security-checkpointed. Symptom: `(#190)` errors
in the publisher logs → redo steps 2–4, `docker compose up -d social-publisher`.

### 2. Deploy

**Production** (server, as `ubuntu`, after the commit is pushed):

```bash
cd ~/lfi && git pull          # or scp the script over
make facebook-token           # once, see above — then paste the two lines into ~/lfi/.env
bash scripts/social-deploy-prod.sh                # add YES=1 without a TTY
# with GHOST_ADMIN_API_KEY=<Admin API key of a custom integration> it also creates the webhook
```

The script generates `SOCIAL_WEBHOOK_SECRET` in `.env` if missing, builds and
starts `social-publisher`, recreates `ghost` (new env + network: ~15 s blip),
verifies everything (publisher reachable from the ghost container by its alias,
no published port, Page token valid, site up) and prints the webhook to create.
The Caddyfile is untouched. Backups of `.env`/compose in `~/social-deploy-backup-<ts>/`.

**Locally:** `make dev` starts it with the rest. Without a token, put
`FACEBOOK_DRY_RUN=1` in `.env`: webhooks are processed and the would-be post is
logged, nothing is sent.

### 3. The Ghost webhook

Ghost Admin → Settings → Integrations → *Add custom integration* (e.g. "Facebook")
→ *Add webhook*:

| Field      | Value                                                       |
|------------|-------------------------------------------------------------|
| Name       | Facebook (social-publisher)                                 |
| Event      | **Post published**                                          |
| Target URL | `http://social-publisher.lfi.internal:8080/webhooks/ghost`  |
| Secret     | the `SOCIAL_WEBHOOK_SECRET` value from `.env` (`make social-check` prints it) |

Scripted alternative (idempotent), with that integration's *Admin API key*:

```bash
scripts/social-webhook.sh https://adour-en-commun.fr <admin-api-key>
```

The integration page in Ghost Admin shows the last delivery status for the
webhook (`202` = accepted by the publisher).

### 4. First real post

Publish an article (with a feature image). Within ~10 s:

```bash
docker compose logs -f social-publisher
#  INFO  queued "…"  → INFO shared "…" → https://www.facebook.com/<page>_<post>
```

If the preview card on Facebook came out without image/description (shared
before Ghost served the page, or OG tags changed later), re-scrape it once at
<https://developers.facebook.com/tools/debug/> — Facebook caches scrapes.

## Ops

```bash
docker compose logs -f social-publisher                      # what was shared / skipped / why
make social-check                                            # token + Page still valid?
docker compose exec social-publisher cat /data/shared-posts.json   # what went out (Ghost id → FB post id)
docker compose build social-publisher && docker compose up -d social-publisher   # upgrade (Node base image)
make social-test                                             # unit + integration tests (mock Graph API)
```

- **Keep a post off Facebook:** add the internal tag `#no-facebook` *before*
  publishing (tags are read from the webhook payload at publish time).
- **Share a post again on purpose:** delete its entry from
  `data/social-publisher/shared-posts.json`, `docker compose restart
  social-publisher` (the list is loaded at start), then unpublish → republish.
- **Facebook post text:** `EXCERPT_MAX_CHARS` (default 280) env on the service;
  the custom excerpt is never cut — write one in the post settings when the
  automatic one is poor.
- **Graph API version:** `FACEBOOK_GRAPH_VERSION` (default `v26.0`, released
  2026-07-29). Each version lives ~2 years; bump it before Meta retires it
  (<https://developers.facebook.com/docs/graph-api/changelog/versions/>).
- **Footprint:** ~40 MB RSS, idle. No cron, no polling — purely event-driven.

## Gotchas (learned the hard way)

- Ghost's webhook client gives up after **2 s** with **no retry** on POST: any
  receiver must acknowledge first and work later, or deliveries silently fail
  (the only trace is `[WEBHOOK_DELIVERY_FAILURE]` in Ghost's log).
- Ghost signs `body + timestamp` (concatenated, no separator) with a hex HMAC in
  `sha256=…, t=…` — different from the `base64(HMAC("ts:body"))` format its
  `signed-webhook.js` helper documents for Ghost-Pro-host webhooks.
- The Ghost 6 Admin API returns an integration's admin key with the `secret`
  field **already** in `id:secret` form (what Ghost Admin displays); don't prefix
  it with the id again.
- Webhook targets: `security__allowWebhookInternalIPs=true` alone is not enough
  for a Docker service name — Ghost's `@tryghost/request` validator wants a TLD,
  hence the `social-publisher.lfi.internal` alias. Without the flag, Ghost would
  need the public URL (`https://adour-en-commun.fr/...`) hair-pinned through
  Caddy, i.e. a public endpoint — avoided on purpose.
- The service drops to the unprivileged `node` user, after fixing the owner of
  the bind-mounted `/data` (Docker creates missing bind-mount dirs as root).

## Why not n8n / Zapier / Buffer

`docs/n8n-social-publishing.md` planned n8n (+ Instagram). For Facebook alone it
would add a 400 MB container, a public editor UI with its own logins to patch
(cf. the 2026-09-23 Umami incident), a subdomain and DNS work — for one HTTP call
per article. The publisher is small enough to read in full, exposes nothing, and
is covered by `make social-test`.
