####################################
# Stage 1: Build Haxe project
####################################
FROM ghcr.io/haxe/haxe:4.3 AS builder

WORKDIR /build

# Copy build configuration and source
COPY compile_server.hxml compile_web.hxml ./
COPY src/ src/

# Create dist directory and compile
RUN mkdir -p dist/web && \
    haxe compile_web.hxml && \
    haxe compile_server.hxml

####################################
# Stage 2: Runtime
####################################
FROM debian:bookworm-slim

# Install runtime dependencies
# - hashlink: to run our server
# - curl, tar, unzip: for Factorio downloads and mod extraction
# - xz-utils: for .tar.xz Factorio archives
# - procps: for process management (kill, ps)
RUN apt-get update && apt-get install -y --no-install-recommends \
    hashlink \
    curl \
    tar \
    unzip \
    xz-utils \
    procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy compiled artifacts from builder
COPY --from=builder /build/dist/server.hl ./dist/server.hl
COPY --from=builder /build/dist/web/ ./dist/web/

# Create data directories
RUN mkdir -p data/config/instances data/server/mods data/saves

# Expose web UI port (default 8080, configurable via ENV or settings)
EXPOSE 8080

# Default environment variables
ENV FACTORIO_PORT=8080
ENV FACTORIO_USERNAME=""
ENV FACTORIO_TOKEN=""

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/api/servers || exit 1

# Start the server
ENTRYPOINT ["hl", "dist/server.hl"]
