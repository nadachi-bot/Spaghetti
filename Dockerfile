####################################
# Stage 1: Build Haxe project
####################################
FROM debian:bookworm-slim AS builder

WORKDIR /build

# Install Haxe 4.3+ from official binary
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl tar ca-certificates \
    && rm -rf /var/lib/apt/lists/* && \
    curl -fsSL https://github.com/HaxeFoundation/haxe/releases/download/4.3.6/haxe-4.3.6-linux64.tar.gz \
    -o /tmp/haxe.tar.gz && \
    tar xzf /tmp/haxe.tar.gz -C /opt/ && \
    rm /tmp/haxe.tar.gz && \
    ln -s /opt/haxe-4.3.6/haxe /usr/local/bin/haxe

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
FROM python:3.11-slim

# Install runtime dependencies
# - curl, tar, unzip: for Factorio downloads and mod extraction
# - xz-utils: for .tar.xz Factorio archives
# - procps: for process management (kill, ps)
# - strace: optional debugging tool (removed to slim image)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    tar \
    unzip \
    xz-utils \
    procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy compiled artifacts from builder
COPY --from=builder /build/dist/server.py ./dist/server.py
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
ENTRYPOINT ["python3", "dist/server.py"]
