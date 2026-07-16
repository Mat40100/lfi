# Discourse-on-Ghost (SSO connector) — no official image; built from pinned source.
# Audited commit (v0.3.0): 74f3a32a12d33bb50d898f070930314faba6a650
# See docs/forum-discourse.md for the audit notes and runtime config (dog/dog.env).
FROM node:20-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN git clone https://github.com/vikaspotluri123/discourse-on-ghost.git . \
 && git checkout 74f3a32a12d33bb50d898f070930314faba6a650
RUN corepack enable && yarn install --frozen-lockfile && yarn build
ENV DOG_HOSTNAME=0.0.0.0
ENV DOG_PORT=3286
EXPOSE 3286
CMD ["node", "build/index.js"]
