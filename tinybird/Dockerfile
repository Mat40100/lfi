# Tinybird deploy/bootstrap image for the `tinybird-deploy` service.
#
# Bundles the `tb` CLI with the Tinybird project Ghost ships inside its own image
# (core/server/data/tinybird: analytics_events datasource, materialized views and
# the api_* pipes Ghost Admin queries). Rebuilding with `docker compose build --pull`
# therefore picks up the datafiles of the same Ghost release as ./ghost.
#
# Stage 1 is only a source for COPY --from: keep the tag identical to ghost/Dockerfile.
FROM ghost:6-alpine AS ghost-src

# The Tinybird CLI requires Python >=3.10,<3.14.
FROM python:3.13-slim

# uv gives a reproducible, fast install of a pinned CLI version.
COPY --from=ghcr.io/astral-sh/uv:0.11.6 /uv /uvx /bin/

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        jq \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Same pin as Ghost's own tb-cli image (docker/tb-cli/Dockerfile): 4.6.14 broke
# JSON payload ingestion for analytics_events. Bump together with the
# tinybird-local digest in docker-compose.yml.
ARG TINYBIRD_VERSION=4.6.13
RUN uv tool install "tinybird==${TINYBIRD_VERSION}" --python 3.13 --force
ENV PATH="/root/.local/bin:$PATH"

# Ghost's Tinybird project. fixtures/ and tests/ are dev/CI material (sample
# events, `tb test`) and must never end up in a production workspace.
COPY --from=ghost-src /var/lib/ghost/current/core/server/data/tinybird /project
RUN rm -rf /project/fixtures /project/tests /project/scripts

COPY entrypoint.sh /usr/local/bin/tinybird-entrypoint
RUN chmod +x /usr/local/bin/tinybird-entrypoint

WORKDIR /project
ENTRYPOINT ["tinybird-entrypoint"]
CMD ["deploy"]
