#!/usr/bin/env bash
# scripts/pack-deps.sh — pack the built deps into uploadable artifacts.
#
# Produces dist/deps-<bundle>-<tag>.tar.gz (+ .sha256) containing the minimal
# closure a consumer needs: public headers + prebuilt static libs. Paired with
# the download fast path in fetch-deps.sh — consumers get a ~100-500 MB
# tarball instead of a 30-60 min Skia compile.
#
# Usage:
#   scripts/pack-deps.sh              # pack every bundle whose outputs exist
#   scripts/pack-deps.sh native ios   # pack selected bundles
#
# Bundles (mirroring fetch-deps.sh components):
#   native         → deps/skia/{include,out/$TAG} + deps/SDL/{include,build-$TAG}
#                    + deps/wamr/{core/iwasm/include,build-$TAG}
#   web-wasm       → deps/skia/out/web-wasm + deps/SDL/build-web-wasm
#                    (emsdk itself is not packed — the toolchain install is
#                    what activates emcc; only the Skia/SDL wasm objects are)
#   android-arm64  → deps/skia/out/android-arm64 + deps/SDL/build-android-arm64
#   ios            → deps/skia/out/ios-* + deps/SDL/build-ios-* + dawn/abseil
#                    externals (the iOS shim compiles against dawn headers)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/deps"
DIST="$ROOT/dist"

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS:$ARCH" in
  Darwin:arm64)  TAG="macos-arm64" ;;
  Linux:x86_64)  TAG="linux-x64" ;;
  Linux:aarch64) TAG="linux-arm64" ;;
  *) echo "unsupported host $OS/$ARCH" >&2; exit 1 ;;
esac

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# pack_bundle <name> <paths...> — tar a list of DEPS-relative paths into
# dist/deps-<name>.tar.gz. Missing paths are fatal: packing silently partial
# artifacts is how consumers end up with half a dep tree.
pack_bundle() {
  local name="$1"; shift
  local missing=()
  for p in "$@"; do
    [ -e "$DEPS/$p" ] || missing+=("$p")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "skip $name — not built (${missing[*]})"
    return 1
  fi
  mkdir -p "$DIST"
  local out="$DIST/deps-$name.tar.gz"
  tar -czf "$out" -C "$DEPS" "$@"
  (cd "$DIST" && shasum -a 256 "$(basename "$out")" > "$(basename "$out").sha256")
  log "packed $(basename "$out") ($(du -sh "$out" | cut -f1))"
}

BUNDLES=("$@")
[ "${#BUNDLES[@]}" -eq 0 ] && BUNDLES=(native web-wasm android-arm64 ios)

rc=0
for b in "${BUNDLES[@]}"; do
  case "$b" in
    native)
      pack_bundle "native-$TAG" \
        "skia/include" \
        "skia/out/$TAG" \
        "skia/modules" \
        "SDL/include" \
        "SDL/build-$TAG" \
        "wamr/core/iwasm/include" \
        "wamr/build-$TAG" || rc=1
      ;;
    web-wasm)
      pack_bundle web-wasm \
        "skia/include" \
        "skia/out/web-wasm" \
        "skia/modules" \
        "SDL/include" \
        "SDL/build-web-wasm" || rc=1
      ;;
    android-arm64)
      pack_bundle android-arm64 \
        "skia/include" \
        "skia/out/android-arm64" \
        "skia/modules" \
        "SDL/include" \
        "SDL/build-android-arm64" || rc=1
      ;;
    ios)
      pack_bundle ios \
        "skia/include" \
        "skia/out/ios-arm64" \
        "skia/out/ios-sim-arm64" \
        "skia/modules" \
        "skia/third_party/externals/dawn/include" \
        "skia/third_party/externals/dawn/src/dawn/partition_alloc" \
        "skia/third_party/externals/abseil-cpp" \
        "SDL/include" \
        "SDL/build-ios-arm64" \
        "SDL/build-ios-sim-arm64" || rc=1
      ;;
    *) die "unknown bundle '$b' (native | web-wasm | android-arm64 | ios)" ;;
  esac
done
exit "$rc"
