# social-publisher: shares published Ghost posts on a Facebook Page.
# Plain Node 22 (http/crypto/fs/fetch) — no npm install, nothing to audit but server.js.
FROM node:22-alpine

RUN apk add --no-cache su-exec

WORKDIR /app
COPY entrypoint.sh server.js ./
RUN chmod +x entrypoint.sh && mkdir -p /data && chown node:node /data

ENV NODE_ENV=production \
    STATE_DIR=/data \
    PORT=8080
EXPOSE 8080

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["serve"]
