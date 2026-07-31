# Discourse-on-Ghost (SSO connector) — no official image; built from pinned source.
# Audited commit (v0.3.0): 74f3a32a12d33bb50d898f070930314faba6a650
# + tier-gate.patch (LFI): SSO restricted to members with an active tier whose slug
#   is DOG_SSO_REQUIRED_TIER_SLUG; others are 302'd to DOG_SSO_DENIED_REDIRECT.
# See docs/forum-discourse.md for the audit notes and runtime config (dog/dog.env).
FROM node:20-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN git clone https://github.com/vikaspotluri123/discourse-on-ghost.git . \
 && git checkout 74f3a32a12d33bb50d898f070930314faba6a650
COPY tier-gate.patch /tmp/tier-gate.patch
RUN git apply --stat --check /tmp/tier-gate.patch && git apply /tmp/tier-gate.patch
RUN corepack enable && yarn install --frozen-lockfile && yarn build
ENV DOG_HOSTNAME=0.0.0.0
ENV DOG_PORT=3286
EXPOSE 3286
CMD ["node", "build/index.js"]
