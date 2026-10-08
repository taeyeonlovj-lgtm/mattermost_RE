# =============================================================================
# Multi-stage Dockerfile – build Mattermost from source
# =============================================================================
# Stage 1 : Build the webapp   (Node 24)
# Stage 2 : Build the server   (Go 1.26)
# Stage 3 : Runtime image      (Ubuntu noble, minimal)
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1 – Webapp
# ---------------------------------------------------------------------------
FROM node:24.11.1-bookworm AS webapp-builder

# The .npmrc in webapp/ sets engine-strict=true, requiring npm 11.6.2 exactly.
# The official node image ships with npm 10.x, so upgrade first.
RUN npm install -g npm@11.6.2

WORKDIR /src/webapp

# Copy all workspace package.json files FIRST so npm install can resolve
# every workspace even before the full source is copied.
COPY webapp/package.json                    webapp/package-lock.json   ./
COPY webapp/channels/package.json           channels/
COPY webapp/platform/client/package.json    platform/client/
COPY webapp/platform/components/package.json platform/components/
COPY webapp/platform/eslint-plugin/package.json platform/eslint-plugin/
COPY webapp/platform/mattermost-redux/package.json platform/mattermost-redux/
COPY webapp/platform/shared/package.json    platform/shared/
COPY webapp/platform/types/package.json     platform/types/

# Install deps (CI=false so devDependencies are included — build needs them)
RUN CI=false npm install

# Copy the rest of the webapp source
COPY webapp/ ./

# Build the production bundle
RUN npm run build

# ---------------------------------------------------------------------------
# Stage 2 – Server (Go)
# ---------------------------------------------------------------------------
FROM golang:1.26.7-bookworm AS server-builder

ARG BUILD_ENTERPRISE_READY=false
ARG BUILD_NUMBER=docker-local

RUN apt-get update && apt-get install -y --no-install-recommends \
        make git build-essential zip xmlsec1 jq \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src/mattermost

# Copy go module files first for layer caching
COPY server/go.mod server/go.sum ./server/
RUN cd server && go mod download

# Copy the full source
COPY server/ ./server/

# Note: if you have the enterprise repo, copy it alongside this repo
# and uncomment the line below:
# COPY enterprise/ ./enterprise/

# Copy the pre-built webapp dist from stage 1
COPY --from=webapp-builder /src/webapp/channels/dist ./webapp/channels/dist

# Symlink the client dist so the server can embed it
RUN mkdir -p server/client \
    && ln -nfs /src/mattermost/webapp/channels/dist server/client/dist

# Build the server binary
RUN cd server \
    && BUILD_ENTERPRISE_READY=${BUILD_ENTERPRISE_READY} \
       BUILD_NUMBER=${BUILD_NUMBER} \
       GOOS=linux GOARCH=amd64 \
       go build \
          -o /mattermost/bin/mattermost \
          -ldflags "-X github.com/mattermost/mattermost/server/public/model.BuildNumber=${BUILD_NUMBER} \
                    -X github.com/mattermost/mattermost/server/public/model.BuildEnterpriseReady=${BUILD_ENTERPRISE_READY} \
                    -X github.com/mattermost/mattermost/server/public/model.BuildDate=$(date -u) \
                    -X github.com/mattermost/mattermost/server/public/model.BuildHash=$(git rev-parse HEAD 2>/dev/null || echo docker-local)" \
          ./cmd/mattermost

# Build mmctl
RUN cd server \
    && go build -o /mattermost/bin/mmctl ./cmd/mmctl

# ---------------------------------------------------------------------------
# Stage 3 – Runtime
# ---------------------------------------------------------------------------
FROM ubuntu:noble-20251013

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG PUID=2000
ARG PGID=2000

# Install runtime dependencies only
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        ca-certificates curl jq \
        media-types mailcap \
        unrtf wv poppler-utils tidy \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# Create mattermost user/group
RUN groupadd  --gid ${PGID} mattermost \
    && useradd  --uid ${PUID} --gid ${PGID} --comment "" --home-dir /mattermost mattermost \
    && mkdir -p /mattermost/data \
                /mattermost/plugins \
                /mattermost/client/plugins \
                /mattermost/config \
                /mattermost/logs \
                /mattermost/bleve-indexes \
                /mattermost/.postgresql \
    && chmod 700 /mattermost/.postgresql

# Copy server binary + mmctl from builder
COPY --from=server-builder /mattermost/bin/mattermost /mattermost/bin/mattermost
COPY --from=server-builder /mattermost/bin/mmctl      /mattermost/bin/mmctl

# Copy the built webapp dist
COPY --from=webapp-builder  /src/webapp/channels/dist /mattermost/client/dist

# Fix ownership
RUN chown -R mattermost:mattermost /mattermost

ENV PATH="/mattermost/bin:${PATH}"
ENV MM_SERVICESETTINGS_ENABLELOCALMODE="true"
ENV MM_INSTALL_TYPE="docker"

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s \
    CMD ["/mattermost/bin/mmctl", "system", "status", "--local"]

EXPOSE 8065 8067 8074

VOLUME ["/mattermost/data", "/mattermost/logs", "/mattermost/config", \
        "/mattermost/plugins", "/mattermost/client/plugins", "/mattermost/bleve-indexes"]

USER mattermost
WORKDIR /mattermost
CMD ["/mattermost/bin/mattermost"]