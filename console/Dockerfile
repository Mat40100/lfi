# LFI team console (invites v1) — plain Node, single dep (nodemailer).
# Runtime config via console/console.env + SMTP vars passed by compose.
FROM node:20-bookworm-slim
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force
COPY server.js ./
ENV CONSOLE_PORT=3300
EXPOSE 3300
CMD ["node", "server.js"]
