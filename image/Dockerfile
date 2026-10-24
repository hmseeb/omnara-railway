# Omnara control plane for Railway: api + worker + maintenance + web behind one nginx on $PORT.
# Railway cannot share a volume between services, and upstream's api, worker and maintenance
# all mount the same memory directory, so they run together here. Binaries, migrations and
# web assets are copied unmodified from upstream's published images.
ARG OMNARA_VERSION=v0.2.10
FROM ghcr.io/omnara-ai/omnara-api:${OMNARA_VERSION} AS api
FROM ghcr.io/omnara-ai/omnara-worker:${OMNARA_VERSION} AS worker
FROM ghcr.io/omnara-ai/omnara-maintenance:${OMNARA_VERSION} AS maintenance
FROM ghcr.io/omnara-ai/omnara-migrations:${OMNARA_VERSION} AS migrations
FROM ghcr.io/omnara-ai/omnara-web:${OMNARA_VERSION} AS web

# Same Debian release upstream builds the worker's chroot jail and rg from.
FROM debian:bookworm-slim
# nginx: the gateway; ripgrep: worker file search; libcap2-bin: re-apply the chroot helper's
# file capability; postgresql-client: the first-boot claim (boot.sh); curl: readiness probes.
RUN apt-get update && apt-get install -y --no-install-recommends \
      nginx ripgrep libcap2-bin postgresql-client curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* /etc/nginx/sites-enabled/*

COPY --from=api /usr/local/bin/omnara-api /usr/local/bin/
COPY --from=api /app/mcp-registry /app/mcp-registry
COPY --from=api /etc/ssl/rds-global-bundle.pem /etc/ssl/rds-global-bundle.pem
COPY --from=worker /usr/local/bin/omnara-worker /usr/local/bin/omnara-sandbox /usr/local/bin/omnara-chroot-sandbox /usr/local/bin/
COPY --from=worker /usr/local/lib/omnara /usr/local/lib/omnara
COPY --from=maintenance /usr/local/bin/omnara-maintenance /usr/local/bin/
COPY --from=migrations /usr/local/bin/omnara-migrate /usr/local/bin/
COPY --from=migrations /app/migrations /app/migrations
COPY --from=web /usr/share/nginx/omnara /usr/share/nginx/omnara
# COPY drops file capabilities; scripted edits need the helper to hold cap_sys_chroot.
RUN setcap cap_sys_chroot=ep /usr/local/bin/omnara-chroot-sandbox

COPY nginx.conf /etc/omnara/nginx.conf.in
COPY boot.sh /usr/local/bin/omnara-boot

# Upstream runs every process as distroless nonroot (65532); boot.sh drops to it after
# chowning the Railway volume.
RUN groupadd -g 65532 nonroot && useradd -u 65532 -g 65532 -M -d /nonexistent -s /usr/sbin/nologin nonroot
ENV PORT=8080 \
    OMNARA_MEMORY_DIR=/data/memory \
    OMNARA_MIGRATIONS_DIR=/app/migrations \
    OMNARA_MCP_REGISTRY_SNAPSHOT_PATH=/app/mcp-registry/mcp-registry.json \
    OMNARA_WEB_SERVING=disabled

EXPOSE 8080
CMD ["/usr/local/bin/omnara-boot"]
