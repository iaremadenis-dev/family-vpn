# Family VPN panel. Node 24 is required for node:sqlite.
FROM node:24-bookworm-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

FROM node:24-bookworm-slim AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

FROM node:24-bookworm-slim AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000
ENV HOSTNAME=0.0.0.0
ENV FAMILY_VPN_DATA_DIR=/data
ENV FAMILY_VPN_TRUST_PROXY=1

RUN groupadd --system --gid 1001 familyvpn \
  && useradd --system --uid 1001 --gid familyvpn familyvpn \
  && mkdir -p /data \
  && chown familyvpn:familyvpn /data

COPY --from=builder /app/public ./public
COPY --from=builder --chown=familyvpn:familyvpn /app/.next/standalone ./
COPY --from=builder --chown=familyvpn:familyvpn /app/.next/static ./.next/static

USER familyvpn
EXPOSE 3000
CMD ["node", "server.js"]
