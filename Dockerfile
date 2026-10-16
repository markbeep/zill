# syntax=docker/dockerfile:1
#
# The image builds only the frontend: Zig compiles the WebAssembly module and npm
# builds the bundle. The graph is not built here (that needs the OSM and DHM25
# pipeline), so it is never baked in and is mounted next to the app at run time:
#
#   just docker
#   docker run --rm -p 8080:8080 \
#     -v "$PWD/data/switzerland_walkable_100m.zl.tar.gz:/app/graph.tar.gz:ro" \
#     zill-dashboard
#
# Without that mount the page reports the missing graph and stops there.

# ---------- build the browser module and the bundle ----------
FROM node:22-alpine AS build
ARG ZIG_VERSION=0.16.0
# Zig names its tarballs arch-os-version; override the triple on another platform.
ARG ZIG_TRIPLE=x86_64-linux
RUN apk add --no-cache curl xz \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_TRIPLE}-${ZIG_VERSION}.tar.xz" | tar -xJ -C /opt \
    && ln -s "/opt/zig-${ZIG_TRIPLE}-${ZIG_VERSION}/zig" /usr/local/bin/zig

WORKDIR /src
# Manifests first, so the dependency layer caches across source edits.
COPY find/build.zig find/build.zig.zon find/
COPY dashboard/package.json dashboard/package-lock.json dashboard/
RUN cd dashboard && npm ci --no-audit --no-fund

COPY find/ find/
COPY dashboard/ dashboard/
# public/dashboard.webp is a symlink into here, and the bundle copies it through.
COPY assets/ assets/
# public/ is what the bundle is copied from, and the dev tree fills two of its
# entries with symlinks into ignored build directories - a fresh checkout has
# neither. The graph belongs to the run-time mount, so it is dropped; the wasm is
# built here and copied in, so the image is its own source of truth for it.
RUN rm -f dashboard/public/graph.tar.gz dashboard/public/zill.wasm \
    && zig build --build-file find/build.zig wasm -Dwasm-optimize=ReleaseFast \
    && cp find/zig-out/bin/zill.wasm dashboard/public/zill.wasm \
    && cd dashboard && npm run build

# An image without the module cannot search, so it is not an image.
RUN test -s /src/dashboard/dist/zill.wasm \
    || { echo "dist/zill.wasm is missing: the bundle cannot run" >&2; exit 1; }

# ---------- serve it ----------
FROM alpine:3.21

# Base Alpine's busybox has no httpd applet; this adds it (about a megabyte).
RUN apk add --no-cache busybox-extras && adduser -D -H -u 10001 zill
WORKDIR /app
COPY --from=build /src/dashboard/dist/ /app/
USER zill
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=3s CMD wget -q -O /dev/null http://127.0.0.1:8080/
ENTRYPOINT ["httpd", "-f", "-p", "8080", "-h", "/app"]
