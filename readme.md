# Self-hosted Ghost (Dockerized, served by Caddy)

A self-hosted [Ghost](https://ghost.org/) publishing platform, running in Docker
and reverse-proxied by [Caddy](https://caddyserver.com/) (not nginx).

## Stack

| Service | Image                       | Role                                   |
|---------|-----------------------------|----------------------------------------|
| `ghost` | custom (`./ghost/Dockerfile`, extends `ghost:5-alpine`) | The publishing app |
| `mysql` | `mysql:8.0`                 | Database                               |
| `caddy` | `caddy:2-alpine`            | Reverse proxy + automatic HTTPS        |

Data persists in local bind-mounted folders under `./data/`
(`data/ghost-content`, `data/mysql`, `data/caddy/data`, `data/caddy/config`).

## Quick start

```bash
# 1. Configure secrets
cp .env.example .env
# edit .env and set MYSQL_ROOT_PASSWORD / MYSQL_PASSWORD

# 2. Build & start
make dev          # or: docker compose up -d --build

# 3. Open the site / admin
#    http://localhost/         -> the blog
#    http://localhost/ghost    -> admin setup (create your account here)
```

Check status and logs:

```bash
docker compose ps
docker compose logs -f ghost
```

## Going to production

### IP only (no domain yet) — plain HTTP

1. In `.env`, set `GHOST_URL=http://<public-ip>` and leave
   `CADDY_SITE_ADDRESS` unset (Caddy serves plain HTTP on port 80).
2. Open port **80** to the internet.
3. `make prod` — verifies the `.env` settings, then starts the stack.

### Real domain + HTTPS

1. Point your domain's DNS A/AAAA record at this server.
2. In `.env`, set `GHOST_URL=https://your-domain` and
   `CADDY_SITE_ADDRESS=your-domain`.
3. Ensure ports **80** and **443** are open to the internet (Caddy needs them
   to obtain a Let's Encrypt certificate).
4. `make prod` — Caddy provisions and renews the cert automatically.

## Backups

The custom Ghost image ships with `mysqldump`. Back up the database with:

```bash
docker compose exec mysql sh -c \
  'mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" ghost' > ghost-backup.sql
```

Ghost's uploaded images/themes live in `./data/ghost-content` — back that
up too (e.g. `tar czf ghost_content.tgz -C data/ghost-content .`).

## Updating

```bash
docker compose pull          # newer mysql / caddy
docker compose build --pull  # newer Ghost base image
docker compose up -d
```
