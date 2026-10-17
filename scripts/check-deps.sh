#!/usr/bin/env bash
# check-deps.sh — verify the host's third-party deps are present and report
# exactly what's missing, so a bare `zig build` doesn't fail deep inside
# compile steps on absent headers/libs. Exits non-zero if anything's missing.
set -euo pipefail
cd "$(dirname "$0")/.."

case "$(uname -s):$(uname -m)" in
  Darwin:arm64)  TAG="macos-arm64" ;;
  Linux:x86_64)  TAG="linux-x64" ;;
  Linux:aarch64) TAG="linux-arm64" ;;
  *) echo "check-deps: unsupported host $(uname -s)/$(uname -m)"; exit 2 ;;
esac

missing=0
check() { # label path
  if [ ! -e "$2" ]; then echo "  MISSING  $1 — $2"; missing=1; else echo "  ok       $1"; fi
}

echo "checking deps for tag: $TAG"
check "skia build"        "deps/skia/out/$TAG/libskia.a"
check "SDL3 build"        "deps/SDL/build-$TAG/libSDL3.a"

if [ "$missing" -eq 1 ]; then
  echo
  echo "run: scripts/fetch-deps.sh          # full fetch+build for this host"
  echo "     scripts/fetch-deps.sh --help   # individual components"
  exit 1
fi
echo "all host deps present."
