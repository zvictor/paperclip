FROM node:lts-trixie-slim AS base
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl git \
  && rm -rf /var/lib/apt/lists/*
RUN corepack enable

FROM base AS build
WORKDIR /app
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml .npmrc ./
COPY cli/package.json cli/
COPY server/package.json server/
COPY ui/package.json ui/
COPY packages/shared/package.json packages/shared/
COPY packages/db/package.json packages/db/
COPY packages/adapter-utils/package.json packages/adapter-utils/
COPY packages/adapters/claude-local/package.json packages/adapters/claude-local/
COPY packages/adapters/codex-local/package.json packages/adapters/codex-local/
COPY packages/adapters/cursor-local/package.json packages/adapters/cursor-local/
COPY packages/adapters/gemini-local/package.json packages/adapters/gemini-local/
COPY packages/adapters/openclaw-gateway/package.json packages/adapters/openclaw-gateway/
COPY packages/adapters/opencode-local/package.json packages/adapters/opencode-local/
COPY packages/adapters/pi-local/package.json packages/adapters/pi-local/

RUN pnpm fetch --frozen-lockfile \
  && pnpm install --frozen-lockfile --offline

COPY tsconfig.json tsconfig.base.json ./
COPY server server
COPY ui ui
COPY packages packages
COPY scripts/prepare-server-ui-dist.sh scripts/prepare-server-ui-dist.sh

RUN pnpm --filter @paperclipai/server prepare:ui-dist \
  && pnpm --filter @paperclipai/server build
RUN test -f server/dist/index.js || (echo "ERROR: server build output missing" && exit 1)

FROM build AS runtime-bundle
RUN mkdir -p /runtime/packages /runtime/server \
  && for dir in packages/adapter-utils packages/shared packages/db packages/adapters/*; do \
    mkdir -p "/runtime/$dir"; \
    cp "$dir/package.json" "/runtime/$dir/package.json"; \
    cp -R "$dir/src" "/runtime/$dir/src"; \
  done \
  && cp server/package.json /runtime/server/package.json \
  && cp -R server/dist /runtime/server/dist \
  && cp -R server/ui-dist /runtime/server/ui-dist

FROM base AS production
WORKDIR /app
RUN npm install --global --omit=dev @anthropic-ai/claude-code@latest @openai/codex@latest opencode-ai \
  && mkdir -p /paperclip \
  && chown node:node /paperclip
COPY --from=build /app/package.json /app/pnpm-workspace.yaml /app/tsconfig.base.json /app/
COPY --from=build /app/node_modules /app/node_modules
COPY --from=build /app/server/node_modules /app/server/node_modules
COPY --from=runtime-bundle /runtime/server /app/server
COPY --from=runtime-bundle /runtime/packages /app/packages
COPY --chown=node:node skills /app/skills

ENV NODE_ENV=production \
  HOME=/paperclip \
  HOST=0.0.0.0 \
  PORT=3100 \
  SERVE_UI=true \
  PAPERCLIP_HOME=/paperclip \
  PAPERCLIP_INSTANCE_ID=default \
  PAPERCLIP_CONFIG=/paperclip/instances/default/config.json \
  PAPERCLIP_DEPLOYMENT_MODE=authenticated \
  PAPERCLIP_DEPLOYMENT_EXPOSURE=private

VOLUME ["/paperclip"]
EXPOSE 3100

USER node
CMD ["node", "--import", "./server/node_modules/tsx/dist/loader.mjs", "server/dist/index.js"]
