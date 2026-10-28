#!/bin/sh
# Docker creates a missing bind-mount dir as root: fix /data's owner, then drop
# to the unprivileged `node` user (same trap as data/ghost-content, see CLAUDE.md).
set -e
if [ "$(id -u)" = 0 ]; then
  chown node:node /data 2>/dev/null || true
  exec su-exec node node /app/server.js "$@"
fi
exec node /app/server.js "$@"
