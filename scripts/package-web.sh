#!/bin/bash
# package-web.sh — build + package the Klaxon web target as a static-site bundle.
#
# Usage: scripts/package-web.sh [output-dir]
#   output-dir — where to place the tarball (default: ./dist)
#
# Produces: <output-dir>/klaxon-web-hello.tar.gz
#   containing index.html + hello.js + hello.wasm — the three artifacts of the
#   wasm build, with hello.html renamed to index.html so the unpacked dir can
#   be served directly (python3 -m http.server, nginx, GitHub Pages, ...).
#
# Build pipeline (Phase 3f / 5b — the emcc link step lives in build.zig):
#   libhello.a + libkx_skia.a + libSDL3.a + libskia*.wasm.a
#     -- emcc --> zig-out/web/hello.{html,js,wasm}
#
# Requirements:
#   - Zig 0.17 (brew install zig)
#   - deps built: scripts/fetch-deps.sh web-wasm (emsdk + Skia wasm + SDL3 wasm)
set -euo pipefail
cd "$(dirname "$0")/.."

OUTPUT_DIR="${1:-./dist}"
ZIG="${ZIG:-zig}"
APP_NAME="hello"   # the wasm build is hello-only today (build.zig addWasmWeb)

command -v "$ZIG" >/dev/null 2>&1 || { echo "Error: zig not found — install Zig 0.17 (brew install zig)"; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "Error: tar not found — install GNU/BSD tar (system tar on macOS/Linux)"; exit 1; }
if [ ! -f deps/emsdk/upstream/emscripten/emcc ]; then
    echo "Error: emsdk emcc not found at deps/emsdk/upstream/emscripten/emcc"
    echo "       run: scripts/fetch-deps.sh web-wasm"
    exit 1
fi

echo "==> zig build -Dtarget=wasm32-emscripten web (ReleaseSmall)"
$ZIG build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall web

WEB_DIR="zig-out/web"
for f in "$APP_NAME.html" "$APP_NAME.js" "$APP_NAME.wasm"; do
    [ -f "$WEB_DIR/$f" ] || { echo "Error: expected wasm artifact missing: $WEB_DIR/$f"; exit 1; }
done

PKG_NAME="klaxon-web-${APP_NAME}"
STAGE="$WEB_DIR/.pkg-stage"
mkdir -p "$OUTPUT_DIR"
rm -rf "$STAGE" "$OUTPUT_DIR/$PKG_NAME.tar.gz"
mkdir -p "$STAGE"

# Stage a servable site: hello.html -> index.html, plus the .js loader and
# the .wasm binary (emcc emits all three next to each other).
cp "$WEB_DIR/$APP_NAME.html" "$STAGE/index.html"
cp "$WEB_DIR/$APP_NAME.js"   "$STAGE/"
cp "$WEB_DIR/$APP_NAME.wasm" "$STAGE/"

echo "==> Creating $OUTPUT_DIR/$PKG_NAME.tar.gz"
tar -czf "$OUTPUT_DIR/$PKG_NAME.tar.gz" -C "$STAGE" .
rm -rf "$STAGE"

echo ""
echo "==> Done: $OUTPUT_DIR/$PKG_NAME.tar.gz"
tar -tzf "$OUTPUT_DIR/$PKG_NAME.tar.gz" | sed 's/^/    /'
ls -lh "$OUTPUT_DIR/$PKG_NAME.tar.gz" | awk '{print "    "$5"  "$9}'
echo "    Serve: tar -xzf $PKG_NAME.tar.gz -C site/ && python3 -m http.server -d site/"
