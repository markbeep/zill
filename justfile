# Global entry point for the subprojects. Run from the repo root: the
# executables and tests resolve `data/` relative to the working directory.

# Build both Zig subprojects.
default: build

build: find convert

# find: build the route finder (zill).
find *ARGS:
    zig build --build-file find/build.zig {{ARGS}}

# convert: build the OSM -> .zl converter (zillconv).
convert *ARGS:
    zig build --build-file convert/build.zig {{ARGS}}

# find: run the route finder, e.g. `just run -- -i data/switzerland_walkable_100m.zl -d 1000`.
run *ARGS:
    zig build --build-file find/build.zig run {{ARGS}}

# convert: run the converter, e.g. `PROJ_DATA=/usr/share/proj just generate -- -o /tmp/graph.zl`.
generate *ARGS:
    zig build --build-file convert/build.zig run {{ARGS}}

# find: build the browser WebAssembly module into find/zig-out/bin/zill.wasm, and
# keep the link the dev server serves it through (the image copies the file itself).
wasm *ARGS:
    zig build --build-file find/build.zig wasm {{ARGS}}
    ln -sf ../../find/zig-out/bin/zill.wasm dashboard/public/zill.wasm

# find: smoke-test the browser module against a graph the test builds itself.
wasm-smoke:
    zig build --build-file find/build.zig wasm
    node find/test/wasm_smoke.mjs

# Package a .zl graph for the browser as data/<name>.zl.tar.gz (gzip, so the
# client can stream it through DecompressionStream).
graph name="switzerland_walkable_100m":
    #!/usr/bin/env bash
    set -euo pipefail
    ln -sf ../../data/{{name}}.zl.tar.gz dashboard/public/graph.tar.gz
    cd data
    tar -cf - "{{name}}.zl" | gzip -9 > "{{name}}.zl.tar.gz"
    ls -l "{{name}}.zl.tar.gz"

# Package the dashboard as a minimal Alpine image. The image builds the wasm
# module and the bundle itself; the graph is not part of it and is mounted at run
# time (see the README).
docker:
    docker build -t zill-dashboard .
    docker images zill-dashboard

# Run the test suites of both subprojects. Note that `find` runs a zbench
# benchmark on a 199 MB graph, which takes a long time in Debug builds.
test:
    zig build --build-file find/build.zig test
    zig build --build-file convert/build.zig test

# Cross-compile release binaries for all supported platforms into dist/.
dist:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf dist/bin
    for t in x86_64-linux-musl aarch64-linux-musl x86_64-windows-gnu aarch64-windows-gnu x86_64-macos.11.0 aarch64-macos.11.0; do
        ext=""
        [[ $t == *windows* ]] && ext=".exe"
        zig build --build-file find/build.zig -Doptimize=ReleaseFast -Dcpu=baseline -Dtarget="$t" --prefix dist
        mv "dist/bin/zill$ext" "dist/zill-$t$ext"
        zig build --build-file convert/build.zig -Doptimize=ReleaseFast -Dcpu=baseline -Dtarget="$t" --prefix dist
        mv "dist/bin/zillconv$ext" "dist/conv-$t$ext"
    done
    rm -rf dist/bin
