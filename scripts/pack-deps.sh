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
#   web-wasm       → deps/skia/out/web-wasm + deps/SDL/build-web-wasm
#                    (emsdk itself is not packed — the toolchain install is
#                    what activates emcc; only the Skia/SDL wasm objects are)
#   android-arm64  → deps/skia/out/android-arm64 + deps/SDL/build-android-arm64
#   ios            → deps/skia/out/ios-* + deps/SDL/build-ios-* + dawn/abseil
#                    externals (the iOS shim compiles against dawn headers)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# sha256 helper — Windows Git Bash ships sha256sum, macOS runners ship shasum.
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}
DEPS="$ROOT/deps"
DIST="$ROOT/dist"

OS="$(uname -s)"
ARCH="$(uname -m)"
# Git Bash / MSYS2 / Cygwin all report Windows hosts.
case "$OS" in MINGW*|MSYS*|CYGWIN*) OS=Windows ;; esac
case "$OS:$ARCH" in
  Darwin:arm64)  TAG="macos-arm64" ;;
  Linux:x86_64)  TAG="linux-x64" ;;
  Linux:aarch64) TAG="linux-arm64" ;;
  Windows:x86_64)  TAG="windows-x64" ;;
  Windows:aarch64|Windows:ARM64) TAG="windows-arm64" ;;
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
  # Shims include Skia private headers (src/core/SkUTF.h,
  # src/gpu/ganesh/gl/GrGLDefines.h, ...) — public include/ alone is not
  # enough. Headers only, sources stay out of the artifact.
  local filelist="$DIST/.filelist-$name"
  (cd "$DEPS" && find "$@" -type f | sort; find skia/src -name '*.h' -type f | sort) > "$filelist"
  # Embedded manifest: consumers verify every packed file exists after
  # extract — a partial tree must never pass as complete.
  printf '%s\n' ".deps-manifest-$name" >> "$filelist"
  cp "$filelist" "$DEPS/.deps-manifest-$name"
  tar -czf "$out" -C "$DEPS" -T "$filelist"
  rm -f "$DEPS/.deps-manifest-$name" "$filelist"
  (cd "$DIST" && sha256_file "$(basename "$out")" > "$(basename "$out").sha256")
  log "packed $(basename "$out") ($(du -sh "$out" | cut -f1))"
}

BUNDLES=("$@")
[ "${#BUNDLES[@]}" -eq 0 ] && BUNDLES=(native web-wasm android-arm64 ios)

rc=0
for b in "${BUNDLES[@]}"; do
  case "$b" in
    native)
      # Dawn/abseil externals are synced only on platforms whose Skia build
      # uses dawn (windows-x64 today — its shim includes <webgpu/webgpu_cpp.h>).
      # Pack them when present, skip them where they were never fetched.
      dawn_dirs=()
      for d in "skia/third_party/externals/dawn/include" \
               "skia/third_party/externals/dawn/src/dawn/partition_alloc" \
               "skia/third_party/externals/abseil-cpp"; do
        [ -d "$DEPS/$d" ] && dawn_dirs+=("$d")
      done
      pack_bundle "native-$TAG" \
        "skia/include" \
        "skia/out/$TAG" \
        "skia/modules" \
        "skia/third_party/externals/icu/source/common" \
        ${dawn_dirs[@]+"${dawn_dirs[@]}"} \
        "SDL/include" \
        "SDL/build-$TAG" || rc=1
      ;;
    web-wasm)
      pack_bundle web-wasm \
        "skia/include" \
        "skia/out/web-wasm" \
        "skia/modules" \
        "skia/src" \
        "skia/third_party/externals/icu/source/common" \
        "emdawnwebgpu_pkg" \
        "SDL/include" \
        "SDL/build-web-wasm" || rc=1
      ;;
    android-arm64)
      pack_bundle android-arm64 \
        "skia/include" \
        "skia/out/android-arm64" \
        "skia/modules" \
        "skia/third_party/externals/icu/source/common" \
        "SDL/include" \
        "SDL/build-android-arm64" || rc=1
      ;;
    ios)
      pack_bundle ios \
        "skia/include" \
        "skia/out/ios-arm64" \
        "skia/out/ios-sim-arm64" \
        "skia/modules" \
        "skia/third_party/externals/icu/source/common" \
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
