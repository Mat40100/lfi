# Custom Ghost image.
# Extends the official Ghost image and bakes in the system packages
# needed to run, monitor, and back up the instance reliably.
FROM ghost:5-alpine

USER root

# System dependencies:
#  - bash:           nicer shell for maintenance / exec sessions
#  - curl:           container HEALTHCHECK and debugging
#  - tzdata:         correct timezone handling for scheduled posts
#  - mariadb-client: provides `mysql` / `mysqldump` for manual DB backups
RUN apk add --no-cache \
        bash \
        curl \
        tzdata \
        mariadb-client

# Ghost listens on 2368 inside the container.
HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=5 \
    CMD curl -fsS http://127.0.0.1:2368/ghost/api/admin/site/ >/dev/null || exit 1

# Drop back to the unprivileged user the base image runs as.
USER node
