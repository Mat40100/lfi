# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A self-hosted [Ghost](https://ghost.org/) blog deployed with Docker Compose. There is no application code — the repo is infrastructure config only:

- `docker-compose.yml` — three services: `ghost` (custom image), `mysql` (MySQL 8), `caddy` (reverse proxy / TLS)
- `ghost/Dockerfile` — extends `ghost:5-alpine`; adds bash, curl, tzdata, mariadb-client and a healthcheck
- `caddy/Caddyfile` — `:80` block for local testing; commented-out domain block for production (Let's Encrypt)
- `.env` (from `.env.example`, git-ignored) — `GHOST_URL` + MySQL credentials; compose fails fast if passwords are unset

## Architecture

Two Docker networks isolate traffic: `web` (caddy ↔ ghost) and `internal` (ghost ↔ mysql). MySQL is never exposed to caddy or the host. Ghost waits on mysql's healthcheck before starting. Caddy is the only service publishing ports (80/443).

All persistent state lives in bind mounts under `./data/` (git-ignored): `data/ghost-content`, `data/mysql`, `data/caddy/data`, `data/caddy/config`. Keep these directories pre-created — if Docker creates them they're owned by root and Ghost (uid 1000) can't write its content dir.

MySQL runs with `--default-authentication-plugin=mysql_native_password` because Ghost requires the classic auth plugin — don't remove it.

## Commands

```bash
docker compose up -d --build     # build & start (requires .env)
docker compose ps                # status
docker compose logs -f ghost     # logs
docker compose config --quiet    # validate compose file (needs MYSQL_* vars set)
docker compose pull && docker compose build --pull && docker compose up -d   # update
```

Site: `http://localhost/` — admin: `http://localhost/ghost`.

Going to production: switch the Caddyfile to the domain block, set `GHOST_URL=https://<domain>` in `.env`, open ports 80/443 (see readme.md for the full procedure, plus backup commands).

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
