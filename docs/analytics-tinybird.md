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
- **Don't lower ClickHouse's `max_concurrent_queries`** (upstream 100). Tinybird's
  first boot creates ~40 internal tables with concurrent `CREATE TABLE ON
  CLUSTER`; on the 4-vCPU prod box a limit of 32 made ClickHouse reject some
  ("processing too many queries"), the internal workspace never initialised and
  the API never listened on 8001 (nginx 502 on `/v0/health` forever). A first
  boot there takes minutes, hence the 600 s healthcheck grace period.
- **ClickHouse's own system logs can eat the memory budget.** Every part of a
  MergeTree table costs ~100 KB of RAM while it exists, and `system.query_log`,
  `system.query_views_log`, `system.part_log` (enabled by upstream's config with
  a 3-month TTL) each get a new part per 7.5 s flush. Once ClickHouse's RSS
  crosses `max_server_memory_usage`, *every* query **and every merge** fails with
  `MEMORY_LIMIT_EXCEEDED` — parts can no longer be merged away, memory never
  comes back, Tinybird answers **HTTP 429** and Ghost shows **0 visitors**. Only a
  restart gets out of it (`scripts/analytics-recover-prod.sh`), hence the 3-day
  TTLs in `clickhouse-lowmem.xml` and `make analytics-check` (see below).
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
make analytics-check   # ClickHouse memory budget / parts / error counters + api_kpis queried like Ghost does
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

## Troubleshooting: Ghost Admin shows 0 visitors

Run `make analytics-check` first. Reading its output:

| symptom | meaning | fix |
|---|---|---|
| `OVER BUDGET` / `system.parts aggregation FAILED … MEMORY_LIMIT_EXCEEDED` | ClickHouse is wedged (see the gotcha above). Ghost's log shows `Error in Tinybird API request … Response code 429`, the response body says `Memory limit (total) exceeded`. | on the server: `cd ~/lfi && git pull && bash scripts/analytics-recover-prod.sh` |
| probe `-> HTTP 403` | JWT rejected: `TINYBIRD_WORKSPACE_ID`/`TINYBIRD_ADMIN_TOKEN` in `.env` don't match the workspace | `./scripts/analytics-init.sh` |
| probe `-> HTTP 404` | pipe not deployed | `docker compose up -d tinybird-deploy && docker compose logs tinybird-deploy` |
| `no ghost-stats tracker tag` | Ghost doesn't emit the tracker: tokens missing on the ghost container or Settings → Analytics → Web analytics off | `./scripts/analytics-init.sh`, check Ghost settings |
| probe 200 with rows but Admin still at 0 | Ghost caches pipe results a few minutes; Admin's own browser requests go through the same Caddy route | wait / hard-reload, check the browser console |

Page hits never depend on ClickHouse being queryable: `traffic-analytics` logs
`POST /api/v1/page_hit` + `response received`, Tinybird's nginx log inside the
container (`/var/log/nginx/access.log`, `POST /v0/events`) answers 202 and the
HFI buffers the insert — so the data is usually all there once ClickHouse can
merge and answer again.

### Incident 2026-10-29 — MEMORY_LIMIT_EXCEEDED, 0 visitors for ~10 days

After 4 weeks of uptime ClickHouse's RSS had grown to 3.1 GB against the
1.5 GiB budget of the time: `system.query_views_log` held 17k part directories /
1.3 GB on disk, `query_log` 6.4k, `part_log` 4k, Tinybird's own spans table 1.6k (16.8k active +
12k outdated parts in total). Every merge and every pipe query died with
`MEMORY_LIMIT_EXCEEDED` (35 M errors, 166 k `TOO_MANY_PARTS`, ClickHouse at
245 % CPU retrying merges and writing 330 MB/h of error log), so Tinybird
answered 429 to Ghost, Ghost Admin showed 0 visitors — sporadically since
2026-10-19, permanently from 2026-10-28. Ingestion kept working (202s). Fix:
`scripts/analytics-recover-prod.sh` (hot-raise the limit, drop the system log
tables, restart with the new config) + this repo's 2 GiB budget and 3-day log
TTLs. Lesson: Tinybird Local's healthcheck (`/v0/health`) and Ghost (which just
logs the 429 and renders zeros) don't surface this — run `make analytics-check`
when the numbers look wrong.

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
