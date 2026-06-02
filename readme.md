# Self-hosted Ghost (Dockerized, served by Caddy)

A self-hosted [Ghost](https://ghost.org/) publishing platform, running in Docker
and reverse-proxied by [Caddy](https://caddyserver.com/) (not nginx).

## Stack

| Service | Image                       | Role                                   |
|---------|-----------------------------|----------------------------------------|
| `ghost` | custom (`./ghost/Dockerfile`, extends `ghost:5-alpine`) | The publishing app |
| `mysql` | `mysql:8.0`                 | Database                               |
| `caddy` | `caddy:2-alpine`            | Reverse proxy + automatic HTTPS        |

Data persists in named Docker volumes (`ghost_content`, `mysql_data`,
`caddy_data`, `caddy_config`).

## Quick start

```bash
# 1. Configure secrets
cp .env.example .env
# edit .env and set MYSQL_ROOT_PASSWORD / MYSQL_PASSWORD

# 2. Build & start
docker compose up -d --build

# 3. Open the site / admin
#    http://localhost/         -> the blog
#    http://localhost/ghost    -> admin setup (create your account here)
```

Check status and logs:

```bash
docker compose ps
docker compose logs -f ghost
```

## Going to production (real domain + HTTPS)

1. Point your domain's DNS A/AAAA record at this server.
2. Edit `caddy/Caddyfile`: comment out the `:80` block and uncomment the
   `blog.example.com { ... }` block, replacing it with your domain.
3. Set `GHOST_URL=https://your-domain` in `.env`.
4. Ensure ports **80** and **443** are open to the internet (Caddy needs them
   to obtain a Let's Encrypt certificate).
5. `docker compose up -d` — Caddy provisions and renews the cert automatically.

## Backups

The custom Ghost image ships with `mysqldump`. Back up the database with:

```bash
docker compose exec mysql sh -c \
  'mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" ghost' > ghost-backup.sql
```

Ghost's uploaded images/themes live in the `ghost_content` volume — back that
up too (e.g. `docker run --rm -v lfi_ghost_content:/c -v "$PWD":/b alpine \
tar czf /b/ghost_content.tgz -C /c .`).

## Updating

```bash
docker compose pull          # newer mysql / caddy
docker compose build --pull  # newer Ghost base image
docker compose up -d
```
