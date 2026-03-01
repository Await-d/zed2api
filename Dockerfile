FROM node:22-bookworm-slim AS webui-builder

WORKDIR /app/webui
COPY webui/package.json webui/package-lock.json ./
RUN npm ci
COPY webui/ ./
RUN npm run build

FROM python:3.11-slim AS zig-builder

ARG TARGETARCH=amd64
ARG ZIG_VERSION=0.15.2

WORKDIR /app
RUN apt-get update -o Acquire::Retries=8 && apt-get install -y --fix-missing --no-install-recommends \
    ca-certificates \
    curl \
    xz-utils \
    libc6-dev \
    && rm -rf /var/lib/apt/lists/*

RUN if [ "${TARGETARCH}" = "amd64" ]; then \
      ZIG_ARCH="x86_64"; \
    elif [ "${TARGETARCH}" = "arm64" ]; then \
      ZIG_ARCH="aarch64"; \
    else \
      echo "Unsupported TARGETARCH: ${TARGETARCH}" && exit 1; \
    fi && \
    curl --http1.1 --retry 6 --retry-all-errors --retry-delay 2 -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz && \
    tar -xf /tmp/zig.tar.xz -C /tmp && \
    mv "/tmp/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}" /opt/zig

ENV PATH="/opt/zig:${PATH}"

WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src ./src
COPY --from=webui-builder /app/webui/dist ./webui/dist
RUN SKIP_WEBUI_BUILD=1 zig build -Doptimize=ReleaseSafe

FROM python:3.11-slim AS runtime

WORKDIR /app
RUN apt-get update -o Acquire::Retries=8 && apt-get install -y --fix-missing --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*

COPY --from=zig-builder /app/zig-out/bin/zed2api /app/zed2api
COPY accounts.example.json /app/accounts.example.json
COPY docker-entrypoint.sh /app/docker-entrypoint.sh

RUN chmod +x /app/docker-entrypoint.sh /app/zed2api

EXPOSE 8000

ENTRYPOINT ["/app/docker-entrypoint.sh"]
