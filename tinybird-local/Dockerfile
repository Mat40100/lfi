# Tinybird Local, trimmed for this single-site Ghost stack.
#
# Upstream tinybirdco/tinybird-local bundles ClickHouse + Redis + MinIO + the
# Tinybird API and a few side services, and idles around 2.5-3 GB. Two tweaks:
#
#  1. ClickHouse memory accounting (config.d/lfi-lowmem.xml): stock ClickHouse
#     sets its limit to 90% of the *cgroup* and counts the cgroup's usage as its
#     own — but the cgroup is mostly Tinybird's Python workers, so under a
#     compose memory cap every query fails with MEMORY_LIMIT_EXCEEDED. Give it
#     an explicit own-process budget and small caches instead.
#  2. Drop the supervisord programs a Ghost site never exercises (Kafka
#     ingestion, MCP/AI server) — same edit Ghost's docker/tinybird-local-slim
#     makes; awk on the shipped config keeps this robust to upstream bumps.
#
# The base digest is the one Ghost pins for its analytics CI (paired with tb CLI
# 4.6.13 in ../tinybird). Bump both together — see docs/analytics-tinybird.md.
FROM tinybirdco/tinybird-local:latest@sha256:cf9de0516700eea366161181e74cae943f1a7310e6f2cc4f5762cb1777ed3fb3

COPY clickhouse-lowmem.xml /etc/clickhouse-server/config.d/lfi-lowmem.xml

RUN set -eu; f=/etc/supervisor/conf.d/supervisord.conf; \
    awk 'BEGIN{RS="";ORS="\n\n"} !/\[program:tinybird-kafka\]/ && !/\[program:tinybird-mcp\]/' "$f" > "$f.new" \
    && mv "$f.new" "$f" \
    && ! grep -q 'program:tinybird-kafka' "$f" \
    && grep -q 'program:tinybird-hfi' "$f"   # hfi = the /v0/events API traffic-analytics writes to; must stay
