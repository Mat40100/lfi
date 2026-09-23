# Web analytics — self-hosted Tinybird for Ghost's Analytics screens

Ghost 6's native **Analytics** (Ghost Admin → Analytics: visitors, top content,
sources, locations, devices, member attribution) is backed by Tinybird. Ghost's
docs assume Tinybird Cloud; this stack runs **Tinybird Local** on the same box
instead, so no data leaves the server and nothing is paid for.

## How it fits together

```
browser ──GET /──────────────▶ caddy ──▶ ghost            (HTML + /public/ghost-stats.min.js)
browser ──POST /.ghost/analytics/api/v1/page_hit ─▶ caddy ──▶ traffic-analytics ──▶ tinybird-local /v0/events
                                                             (bot filter, UA/referrer parsing,     (ClickHouse table
                                                              daily-salted user signature,          analytics_events
                                                              tracker token added)                  + materialized views)
Ghost Admin / ghost ──GET /.ghost/tinybird/v0/pipes/<pipe>.json ─▶ caddy ──▶ tinybird-local
                      (Authorization: JWT signed by Ghost, PIPES:READ scopes only)
```

| Service | Image | Role |
|---|---|---|
| `tinybird-local` | `tinybird-local/Dockerfile` (thin derivative of `tinybirdco/tinybird-local`, digest-pinned) | ClickHouse + Redis + Tinybird API on port 7181, **internal only** |
| `tinybird-deploy` | `tinybird/Dockerfile` (`tb` CLI 4.6.13 + Ghost's Tinybird project copied out of the `ghost:6-alpine` image) | one-shot: `tb --local deploy` on every `docker compose up`; `tokens` sub-command |
| `traffic-analytics` | `ghost/traffic-analytics:1.0.429` (TryGhost, digest-pinned) | Ghost's official page-hit proxy |

Ghost config (env in `docker-compose.yml`):

| key | value | why |
|---|---|---|
| `tinybird__tracker__endpoint` | `$GHOST_URL/.ghost/analytics/api/v1/page_hit` | where `ghost-stats.js` POSTs |
| `tinybird__tracker__datasource` | `analytics_events` | |
| `tinybird__stats__endpoint` | `$GHOST_URL/.ghost/tinybird` | used by Ghost Admin **and** by Ghost server-side ("Top content"). Must be the site's own origin: in production Ghost's outbound HTTP client (SSRF guard) refuses single-label hosts / private IPs unless host == site host. Caddy forwards only `/v0/pipes/*`. |
| `tinybird__workspaceId`, `tinybird__adminToken` | from `.env` (generated) | Ghost signs 3-hour JWTs with `PIPES:READ` scopes pinned to the site uuid |

Persistent data: `data/tinybird/clickhouse`, `data/tinybird/redis` (the Tinybird
workspace, tokens, deployments and all events), `data/traffic-analytics/salts.json`.

## First boot / bootstrap

```bash
make prod            # or make dev — both end with scripts/analytics-init.sh
# equivalent by hand:
docker compose up -d
./scripts/analytics-init.sh
```

`scripts/analytics-init.sh` waits for the one-shot `tinybird-deploy`, then runs
`docker compose run --rm tinybird-deploy tokens`, writes
`TINYBIRD_WORKSPACE_ID` / `TINYBIRD_ADMIN_TOKEN` / `TINYBIRD_TRACKER_TOKEN` into
`.env` and recreates `ghost` + `traffic-analytics` if they changed. Idempotent —
run it whenever in doubt. Ghost only emits the tracker once both
`workspaceId` and `adminToken` are set **and** Settings → Analytics → *Web
analytics* is on (it is by default).

### Gotchas learned the hard way

- **`tb --local` deploys into a per-project *build* workspace**
  (`Tinybird_Local_Build_<sha256 of the project path>`), not into the
  container's default workspace whose token the unauthenticated `/tokens`
  endpoint returns. Tokens/ids must come from `tb info` (that is what
  `tinybird/entrypoint.sh tokens` does). Never change `WORKDIR /project` in
  `tinybird/Dockerfile`: a different path = a different (empty) workspace.
- **Memory.** Stock Tinybird Local idles at ~3 GB: ClickHouse (~600 MB) plus
  `ceil(cpu_count/2)` CSV workers at ~450 MB each plus Kafka/MCP side services.
  Worse, ClickHouse 25.x sets its memory limit to 90 % of the *cgroup* and
  counts the cgroup's usage as its own, so under a compose `memory:` cap every
  query dies with `MEMORY_LIMIT_EXCEEDED` while ClickHouse itself uses 200 MB.
  Fixes in this repo: `tinybird-local/clickhouse-lowmem.xml`
  (`memory_worker_use_cgroup=false`, explicit 1.5 GiB budget, small caches),
  `PYTHON_CPU_COUNT=2` (→ 1 CSV worker; Python 3.13 honours it), Kafka + MCP
  programs removed from supervisord. Result: ~1.6 GB idle under a 4 GB cap
  (`TINYBIRD_MEMORY_LIMIT`).
- `tb deploy` prints `Deployment failed` / `[Error] …` but may still exit 0,
  and exits non-zero for the harmless "No changes to be deployed" — the
  entrypoint decides on the text, not the exit code.
- Ghost's `fixtures/` (sample events) and `tests/` are stripped from the deploy
  image: `tb build` (used by Ghost's CI) would load them into production data.
  We use `tb --local deploy`, which never loads fixtures.
- `analytics_events.datasource` declares `TOKEN "tracker" APPEND` — that is the
  token `traffic-analytics` uses. It is created by the deploy; if `tokens`
  reports it missing, the deploy did not happen.

## Day-2 operations

```bash
docker compose logs -f traffic-analytics tinybird-local        # ingestion / Tinybird logs
docker compose run --rm tinybird-deploy tb --local sql "select count() from analytics_events"
docker compose run --rm tinybird-deploy tb --local endpoint ls  # pipes Ghost queries
docker compose run --rm tinybird-deploy tokens                  # print the 3 values (stdout only)
docker stats --no-stream tinybird-local                         # memory vs TINYBIRD_MEMORY_LIMIT
```

**Ghost upgrade** (`docker compose build --pull && docker compose up -d`): the
deploy image is rebuilt from the same `ghost:6-alpine` tag, so new/changed
pipes are deployed by the one-shot service on `up`. Check its log:
`docker compose logs tinybird-deploy`.

**Bumping Tinybird** = the image digest in `tinybird-local/Dockerfile` **and**
`TINYBIRD_VERSION` in `tinybird/Dockerfile`, together. Take the pair from
Ghost's `compose.dev.analytics.yaml` + `docker/tb-cli/Dockerfile` (upstream
tests its datafiles against exactly that pair; the CLI is pinned because
4.6.14 broke JSON payload ingestion). After a bump re-run
`docker compose build tinybird-local tinybird-deploy && docker compose up -d && ./scripts/analytics-init.sh`.

**Rotating tokens**: `docker compose run --rm tinybird-deploy tb --local token refresh tracker`
(or `"workspace admin token"`), then `./scripts/analytics-init.sh`.

**Reset everything** (loses all analytics history): `docker compose rm -sf tinybird-local tinybird-deploy && sudo rm -rf data/tinybird && docker compose up -d && ./scripts/analytics-init.sh`.

## Security notes

- Port 7181 is never published. Caddy forwards only `/.ghost/tinybird/v0/pipes/*`
  to Tinybird; everything else under `/.ghost/tinybird/` answers 403 — Tinybird
  Local's unauthenticated `/tokens` endpoint (hands out the workspace admin
  token) and the SQL/ingest APIs stay unreachable.
- Browsers never see a Tinybird token: page hits are authenticated by
  `traffic-analytics` (APPEND-only `tracker` token), stats reads by a JWT Ghost
  signs server-side, scoped to read a fixed list of pipes for this site uuid.
- `tinybird-local`, `traffic-analytics` and `tinybird-deploy` live on their own
  `analytics` Docker network with Caddy; they cannot reach MySQL.

## Production rollout (2026-09-23)

`scripts/analytics-deploy-prod.sh` — run on the server as `ubuntu`. It also
removes Umami (see the incident note in `CLAUDE.md`) and patches the server's
Caddyfile, which carries server-only blocks (forum, old-domain redirects) and is
therefore not overwritten by `git pull`.
