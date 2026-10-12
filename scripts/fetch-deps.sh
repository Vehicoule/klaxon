#!/usr/bin/env bash
# scripts/fetch-deps.sh — fetch + build Klaxon's third-party dependencies into deps/.
#
#   Skia  @ 8643b1d64cff21b5e6f8d65ca98204c6eecb0098   (Graphite + Ganesh + raster;
#                                                        Graphite Dawn/Metal on iOS)
#   SDL3  @ release-3.4.18
#   WAMR  @ WAMR-2.4.4   (fast-interp; plugin runtime for klaxon-plugin-sdk — the framework does not link it)
#   emsdk @ 4.0.7        (web-wasm only — pinned by Skia's bin/activate-emsdk)
#
# Fast path: every component first tries a prebuilt tarball from the
# `deps-<script-hash>` GitHub release (see the artifacts section) — a seconds-
# long download instead of a 30-60 min Skia compile. Missing artifacts fall
# back to the source build below. KLAXON_DEPS_SOURCE=1 forces source builds.
#
# Hosts: macOS arm64 (dev host), Linux x64/arm64 (CI), Windows x64 (Git Bash; arm64 secondary). Idempotent: up-to-date steps are skipped.
#
# Usage:
#   scripts/fetch-deps.sh              # all components
#   scripts/fetch-deps.sh skia sdl3    # selected components
#   scripts/fetch-deps.sh web-wasm     # web target (emsdk + Skia wasm + SDL3 wasm; heavy, ~1-2 GB)
#   scripts/fetch-deps.sh android-arm64  # Phase 3d Android target (Android NDK required; heavy)
#   scripts/fetch-deps.sh ios            # Phase 3e iOS target (macOS arm64 + Xcode only; heavy)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/deps"
# NINJA_JOBS overrides parallelism for the Skia ninja steps and the CMake
# builds. The iOS Skia steps also cap Dawn's inner ninja (CMAKE_BUILD_PARALLEL_LEVEL)
# so outer + inner clang processes stay within a 16 GB host's memory budget.
JOBS="${NINJA_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 8)}"

SKIA_PIN="8643b1d64cff21b5e6f8d65ca98204c6eecb0098"
SDL3_PIN="release-3.4.18"
WAMR_PIN="WAMR-2.4.4"
EMSDK_PIN="4.0.7" # pinned by Skia's bin/activate-emsdk (see MODULE.bazel)

SKIA_URL="https://skia.googlesource.com/skia.git"
SDL3_URL="https://github.com/libsdl-org/SDL.git"
WAMR_URL="https://github.com/bytecodealliance/wasm-micro-runtime.git"
EMSDK_URL="https://github.com/emscripten-core/emsdk.git"

CHROMIUM="https://chromium.googlesource.com"
SKIA_GOOG="https://skia.googlesource.com"
DAWN_URL="https://dawn.googlesource.com/dawn.git"
SWIFTSHADER_URL="https://swiftshader.googlesource.com/SwiftShader"

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- prerequisites ----------------------------------------------------------

command -v git     >/dev/null || die "git is required"
command -v ninja   >/dev/null || die "ninja is required (brew install ninja / apt install ninja-build)"
command -v cmake   >/dev/null || die "cmake is required (brew install cmake)"

OS="$(uname -s)"
ARCH="$(uname -m)"
# Git Bash / MSYS2 / Cygwin all report Windows hosts.
case "$OS" in MINGW*|MSYS*|CYGWIN*) OS=Windows ;; esac
case "$OS:$ARCH" in
  Darwin:arm64)    TAG="macos-arm64";    SKIA_TARGET_CPU="arm64"; SKIA_TARGET_OS="mac";     WAMR_PLATFORM="darwin";  WAMR_TARGET="AARCH64" ;;
  Linux:x86_64)    TAG="linux-x64";      SKIA_TARGET_CPU="x64";   SKIA_TARGET_OS="linux";   WAMR_PLATFORM="linux";   WAMR_TARGET="X86_64" ;;
  Linux:aarch64)   TAG="linux-arm64";    SKIA_TARGET_CPU="arm64"; SKIA_TARGET_OS="linux";   WAMR_PLATFORM="linux";   WAMR_TARGET="AARCH64" ;;
  Windows:x86_64)  TAG="windows-x64";    SKIA_TARGET_CPU="x64";   SKIA_TARGET_OS="win";     WAMR_PLATFORM="windows"; WAMR_TARGET="X86_64" ;;
  Windows:aarch64|Windows:ARM64) TAG="windows-arm64"; SKIA_TARGET_CPU="arm64"; SKIA_TARGET_OS="win"; WAMR_PLATFORM="windows"; WAMR_TARGET="AARCH64" ;;
  *) die "unsupported host $OS/$ARCH — add it to scripts/fetch-deps.sh" ;;
esac

# python3: Skia's bin/fetch-gn and depot_tools' python3.bat want a `python3`
# on PATH. Stock Windows Python ships only python.exe — shim it into
# deps/.win-tools/ (repo-local, not a system change).
if ! command -v python3 >/dev/null; then
  if [ "$OS" = "Windows" ] && command -v python >/dev/null; then
    mkdir -p "$DEPS/.win-tools"
    PY="$(command -v python)"
    cp -f "$PY" "$DEPS/.win-tools/python3.exe" 2>/dev/null || true
    command -v python3 >/dev/null || export PATH="$DEPS/.win-tools:$PATH"
  fi
fi
command -v python3 >/dev/null || die "python3 is required (Skia's bin/gn wrapper)"

# MSVC environment (Windows): locate vcvars through vswhere and import
# INCLUDE/LIB/LIBPATH/PATH so cl.exe, cmake -G Ninja and gn resolve.
load_msvc_env() {
  [ -n "${KX_MSVC_LOADED:-}" ] && return 0
  local vswhere="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
  [ -x "$vswhere" ] || die "Visual Studio not found — install VS 2022 Build Tools (workload: VCTools + a Windows SDK)"
  local vs_path
  vs_path="$("$vswhere" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | tr -d '\r')"
  [ -n "$vs_path" ] || die "MSVC C++ tools not found — add the VCTools workload"
  # Pick the vcvars matching the target arch. vcvars64.bat = host arch on
  # both x64 and ARM64 native installs; cross from an x64 host to ARM64
  # needs vcvarsamd64_arm64.bat.
  local vcvars_name="vcvars64.bat"
  if [ "$SKIA_TARGET_CPU" = "arm64" ] && [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "ARM64" ]; then
    vcvars_name="vcvarsamd64_arm64.bat"
  fi
  local vcvars="$(cygpath -u "$vs_path")/VC/Auxiliary/Build/$vcvars_name"
  [ -f "$vcvars" ] || die "$vcvars_name not found under $vs_path"
  # Direct `cmd //c "vcvars && set"` quoting is fragile under MSYS bash — a
  # temp .bat is deterministic.
  local tmpbat
  tmpbat="$(mktemp --suffix=.bat)"
  printf '@echo off\r\ncall "%s" >nul\r\nset\r\n' "$(cygpath -w "$vcvars")" > "$tmpbat"
  local line
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
      INCLUDE=*|LIB=*|LIBPATH=*) export "$line" ;;
      Path=*|PATH=*) PATH="$(cygpath -pu "${line#*=}"):$PATH" ;;
    esac
  done < <(cmd //c "$(cygpath -w "$tmpbat")")
  rm -f "$tmpbat"
  export KX_MSVC_LOADED=1
  command -v cl >/dev/null || die "cl.exe not on PATH after vcvars — MSVC setup incomplete"
}

if [ "$OS" = "Darwin" ]; then
  xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools required (xcode-select --install)"
fi
if [ "$OS" = "Linux" ]; then
  command -v clang >/dev/null || die "clang is required (Skia args.gn uses clang)"
fi
log "host: $TAG ($JOBS jobs)"

SKIA="$DEPS/skia"

# --- helpers ----------------------------------------------------------------

# git_clone_at <dir> <url> <pin> — shallow fetch of an exact ref/sha. Idempotent via .pin stamp.
git_clone_at() {
  local dir="$1" url="$2" pin="$3"
  if [ -f "$dir/.pin" ] && [ "$(cat "$dir/.pin")" = "$pin" ]; then
    log "$dir already at $pin"
    return 0
  fi
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$url"
  log "fetch $(basename "$dir") @ $pin"
  if ! git -C "$dir" fetch -q --depth=1 origin "$pin" 2>/dev/null; then
    log "  shallow fetch failed, retrying full fetch"
    git -C "$dir" fetch -q origin "$pin"
  fi
  git -C "$dir" checkout -q FETCH_HEAD
  printf '%s\n' "$pin" > "$dir/.pin"
}

# --- prebuilt artifacts (fast path) ------------------------------------------
# Building Skia takes ~30-60 min; a published tarball takes seconds. Every
# component below first tries to download deps-<bundle>.tar.gz from the
# `deps-<DEPS_ID>` GitHub release — DEPS_ID is the script's own hash, so any
# pin/args change produces a new key (stale artifacts are unreachable).
# Fallbacks: missing artifact → source build (unchanged path below).
#   KLAXON_DEPS_SOURCE=1   force source builds, never download
#   KLAXON_DEPS_BASE_URL   override the release base (testing/mirrors)

# sha256 helper — Git Bash on Windows only ships sha256sum; macOS/Linux runners
# may only have shasum. Both print "<hash>  <file>" so cut -c/-d' ' work alike.
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

DEPS_ID="$(sha256_file "${BASH_SOURCE[0]}" | cut -c1-12)"
DEPS_BASE_URL="${KLAXON_DEPS_BASE_URL:-https://github.com/Vehicoule/klaxon/releases/download/deps-$DEPS_ID}"

# verify_bundle <bundle> — when the tarball embedded a .deps-manifest-<name>,
# every listed file must exist under deps/. A partial tree (truncated upload,
# stale cache) must never pass as complete: missing entries → return 1 and the
# caller falls back to the source build.
verify_bundle() {
  # Split decls: under `set -u`, expansions in a single `local` run before any
  # assignment, so `m=...$name` would read the caller's (possibly unset) name.
  local name="$1" f missing=0
  local m="$DEPS/.deps-manifest-$name"
  [ -f "$m" ] || return 0
  while IFS= read -r f; do
    [ -e "$DEPS/$f" ] || missing=$((missing + 1))
  done < "$m"
  if [ "$missing" -gt 0 ]; then
    log "$name: $missing files missing from deps tree"
    return 1
  fi
}

# try_artifact <bundle> — download + verify + extract deps-<bundle>.tar.gz
# into deps/, then stamp deps/.artifact-<bundle>. Idempotent via the stamp.
try_artifact() {
  local name="$1"
  [ "${KLAXON_DEPS_SOURCE:-0}" = "1" ] && return 1
  [ -f "$DEPS/.artifact-$name" ] && { log "$name: artifact already extracted"; return 0; }
  command -v curl >/dev/null || return 1
  local base="deps-$name.tar.gz"
  local url="$DEPS_BASE_URL/$base"
  local tmp="$DEPS/.dl-$base"
  mkdir -p "$DEPS"
  log "try artifact $base"
  if ! curl -fsSL --retry 2 -o "$tmp" "$url"; then
    rm -f "$tmp"
    log "no artifact for $name — will build from source"
    return 1
  fi
  if ! curl -fsSL -o "$tmp.sha256" "$url.sha256"; then
    rm -f "$tmp" "$tmp.sha256"
    log "artifact without checksum for $name — will build from source"
    return 1
  fi
  local want got
  want="$(cut -d' ' -f1 < "$tmp.sha256")"
  got="$(sha256_file "$tmp" | cut -d' ' -f1)"
  if [ "$want" != "$got" ]; then
    rm -f "$tmp" "$tmp.sha256"
    die "checksum mismatch on $base — refusing to extract (want $want, got $got)"
  fi
  tar -xzf "$tmp" -C "$DEPS"
  rm -f "$tmp" "$tmp.sha256"
  if ! verify_bundle "$name"; then
    rm -f "$DEPS/.artifact-$name" "$DEPS/.deps-manifest-$name"
    log "artifact $base failed completeness check — will build from source"
    return 1
  fi
  printf '%s\n' "$name" > "$DEPS/.artifact-$name"
  log "extracted $base"
  return 0
}

# component_bundle <component> — which artifact covers this component.
component_bundle() {
  case "$1" in
    skia|sdl3|wamr) echo "native-$TAG" ;;
    *) echo "$1" ;;
  esac
}

# satisfied <component> — component outputs present (artifact stamp or
# source-built marker). Checked cheaply via representative output files.
satisfied() {
  local comp="$1" bundle
  bundle="$(component_bundle "$comp")"
  if [ -f "$DEPS/.artifact-$bundle" ]; then
    if verify_bundle "$bundle"; then
      return 0
    fi
    # Partial tree (stale cache / truncated artifact): drop the stamp so the
    # caller re-downloads or rebuilds — representative files like libskia.a
    # can exist in a partial tree, so do NOT fall through to the case check.
    rm -f "$DEPS/.artifact-$bundle" "$DEPS/.deps-manifest-$bundle"
    return 1
  fi
  case "$comp" in
    skia)  [ -f "$SKIA/out/$TAG/libskia.a" ] ;;
    sdl3)  [ -f "$DEPS/SDL/build-$TAG/libSDL3.a" ] ;;
    wamr)  [ -d "$DEPS/wamr/build-$TAG" ] ;;
    web-wasm)   [ -f "$SKIA/out/web-wasm/libskia.wasm.a" ] \
                 && [ -f "$DEPS/emdawnwebgpu_pkg/emdawnwebgpu.port.py" ] ;;
    android-arm64) [ -f "$SKIA/out/android-arm64/libskia.a" ] ;;
    ios)   [ -f "$SKIA/out/ios-arm64/libskia.a" ] ;;
    *) return 1 ;;
  esac
}

# --- Skia -------------------------------------------------------------------

# Dawn (Graphite Dawn) externals — pins from Skia's DEPS at $SKIA_PIN (kept in
# sync with the Dawn DEPS at the pinned Dawn revision). Required only when
# skia_use_dawn = true (the iOS targets in Phase 3e).
fetch_dawn() {
  local ext="$SKIA/third_party/externals"
  git_clone_at "$ext/dawn"                     "$DAWN_URL"                                                           2c217c7f8c9fe26f5622aae94ced28e9ae8d27b6
  git_clone_at "$ext/abseil-cpp"               "$CHROMIUM/chromium/src/third_party/abseil-cpp"                       af5aede14a0b4013be6890148d34e0fd7b1fac69
  git_clone_at "$ext/glslang"                  "$CHROMIUM/external/github.com/KhronosGroup/glslang"                  1d47ffa8ac4374a19b302021e216a20f22a3de92
  git_clone_at "$ext/spirv-tools"              "$SKIA_GOOG/external/github.com/KhronosGroup/SPIRV-Tools.git"         1ba1f5b8fe921e46091d18370f91fb46450ff786
  git_clone_at "$ext/spirv-headers"            "$SKIA_GOOG/external/github.com/KhronosGroup/SPIRV-Headers.git"       86f980c731e62ae4eaf383d320449d71687936bf
  git_clone_at "$ext/vulkan-headers"           "$CHROMIUM/external/github.com/KhronosGroup/Vulkan-Headers"           c46850864f4661461b0f6cb9922c058ffea4915e
  # Windows D3D12: Skia cross-compiles SPIRV → HLSL through spirv-cross, and
  # its D3D12 backend allocates through D3D12MemoryAllocator.
  git_clone_at "$ext/spirv-cross"              "$CHROMIUM/external/github.com/KhronosGroup/SPIRV-Cross"               b8fcf307f1f347089e3c46eb4451d27f32ebc8d3
  git_clone_at "$ext/d3d12allocator"           "$SKIA_GOOG/external/github.com/GPUOpen-LibrariesAndSDKs/D3D12MemoryAllocator.git" 169895d529dfce00390a20e69c2f516066fe7a3b
  git_clone_at "$ext/vulkan-utility-libraries" "$CHROMIUM/external/github.com/KhronosGroup/Vulkan-Utility-Libraries" f91385f84e1c82d744b3050d1919edb3eaa32827
  git_clone_at "$ext/egl-registry"             "$SKIA_GOOG/external/github.com/KhronosGroup/EGL-Registry"            b055c9b483e70ecd57b3cf7204db21f5a06f9ffe
  git_clone_at "$ext/opengl-registry"          "$SKIA_GOOG/external/github.com/KhronosGroup/OpenGL-Registry"         14b80ebeab022b2c78f84a573f01028c96075553
  git_clone_at "$ext/webgpu-headers"           "$CHROMIUM/external/github.com/webgpu-native/webgpu-headers"          706853a9da45b8e89b7ea005aa267294d115f8ce
  git_clone_at "$ext/swiftshader"              "$SWIFTSHADER_URL"                                                    1e80438d2b93ef36a7c05f8d2b81233bac0e3d16
}

# Apply scripts/patches/*.patch to the Skia checkout — local fixes on top of
# the pinned Skia (currently: Dawn-on-iOS support in third_party/dawn).
# Idempotent: a patch whose reverse applies cleanly is already applied.
apply_skia_patches() {
  local patch_dir="$ROOT/scripts/patches"
  [ -d "$patch_dir" ] || return 0
  local patch
  for patch in "$patch_dir"/*.patch; do
    [ -e "$patch" ] || continue
    if git -C "$SKIA" apply --check "$patch" 2>/dev/null; then
      log "apply skia patch $(basename "$patch")"
      git -C "$SKIA" apply "$patch"
    elif git -C "$SKIA" apply --reverse --check "$patch" 2>/dev/null; then
      log "skia patch $(basename "$patch") already applied"
    else
      die "scripts/patches/$(basename "$patch") does not apply to $SKIA @ $SKIA_PIN"
    fi
  done
}

fetch_skia() {
  git_clone_at "$SKIA" "$SKIA_URL" "$SKIA_PIN"

  # Minimal third_party/externals — pins from Skia's DEPS at $SKIA_PIN.
  # Enough for graphite+ganesh+raster; Dawn externals come from fetch_dawn.
  local ext="$SKIA/third_party/externals"
  git_clone_at "$ext/freetype"        "$CHROMIUM/chromium/src/third_party/freetype2.git"               264b5fbf5b912b39f98d038bf75d39be0a73f21b
  git_clone_at "$ext/harfbuzz"        "$CHROMIUM/external/github.com/harfbuzz/harfbuzz.git"           9cb1fee51069b206effb4736e443b038d230789d
  git_clone_at "$ext/icu"             "$CHROMIUM/chromium/deps/icu.git"                               d578f2e8b7bd5938e21cfb6bf15c079e0aa5b738
  git_clone_at "$ext/libpng"          "$SKIA_GOOG/third_party/libpng.git"                             d5515b5b8be3901aac04e5bd8bd5c89f287bcd33
  git_clone_at "$ext/zlib"            "$CHROMIUM/chromium/src/third_party/zlib"                       646b7f569718921d7d4b5b8e22572ff6c76f2596
  git_clone_at "$ext/jinja2"          "$CHROMIUM/chromium/src/third_party/jinja2"                     c3027d884967773057bf74b957e3fea87e5df4d7
  git_clone_at "$ext/markupsafe"      "$CHROMIUM/chromium/src/third_party/markupsafe"                 4256084ae14175d38a3ff7d739dca83ae49ccec6
  git_clone_at "$ext/partition_alloc" "$CHROMIUM/chromium/src/base/allocator/partition_allocator.git" 03cc513177b4340bee3dbfd46f6dd5fdded43b79
  apply_skia_patches
}

write_skia_args() {
  local out="$1"
  case "$TAG" in
    macos-arm64)
      cat > "$out" <<EOF
is_debug = false
is_official_build = true
is_component_build = false
target_cpu = "arm64"
target_os = "mac"

skia_use_metal = true
skia_use_gl = false
skia_use_vulkan = false
skia_use_dawn = false
skia_use_direct3d = false
skia_use_x11 = false
skia_use_egl = false
skia_use_vma = false
skia_enable_ganesh = true
skia_enable_graphite = true
EOF
      ;;
    linux-x64|linux-arm64)
      # Ganesh GL on Linux: the shim resolves every GL entry point through
      # SDL_GL_GetProcAddress (GrGLMakeAssembledGLInterface) — no EGL/GLX/X11
      # deps in Skia, so the same lib works on Wayland/X11/headless llvmpipe.
      # Graphite Vulkan stays Phase 3a (needs vma + vulkan-headers externals).
      cat > "$out" <<EOF
is_debug = false
is_official_build = true
is_component_build = false
target_cpu = "$SKIA_TARGET_CPU"
target_os = "linux"
cc = "clang"
cxx = "clang++"

skia_use_gl = true
skia_use_egl = false
skia_use_x11 = false
skia_use_vulkan = false
skia_use_dawn = false
skia_use_metal = false
skia_use_direct3d = false
skia_use_vma = false
skia_enable_ganesh = true
skia_enable_graphite = false
EOF
      ;;
    windows-x64|windows-arm64)
      # Phase 3c: Dawn (D3D12 primary + Vulkan fallback) + Ganesh GL (WGL)
      # + raster. MSVC toolchain (cl.exe, /MT) — Skia's msvc toolchain is the
      # GN default on win; clang is used only when clang_win is set.
      cat > "$out" <<EOF
is_debug = false
is_official_build = true
is_component_build = false
target_cpu = "$SKIA_TARGET_CPU"
target_os = "win"

skia_use_direct3d = true
skia_use_dawn = true
skia_use_vulkan = false
skia_use_gl = true
skia_use_angle = false
skia_use_egl = false
skia_use_x11 = false
skia_use_metal = false
skia_use_vma = false
skia_enable_ganesh = true
skia_enable_graphite = true

# dawn_enable_vulkan defaults to false on Windows — the Vulkan fallback
# backend (dawn-vulkan) needs it forced on. D3D11 stays off.
dawn_enable_vulkan = true
dawn_enable_d3d11 = false

# jpeg_gainmaps would pull in the expat external — not fetched.
skia_use_jpeg_gainmaps = false
EOF
      ;;
  esac
  write_skia_args_common "$out"
  if [ "$TAG" = "linux-arm64" ]; then
    # Ubuntu arm64 clang defaults to -moutline-atomics: the .a calls
    # __aarch64_*_sync helpers that zig's bundled builtins don't provide —
    # inline the atomics instead. Appends to common's lists (GN forbids
    # re-assigning a nonempty list).
    cat >> "$out" <<'EOF'

extra_cflags += ["-mno-outline-atomics"]
extra_cflags_cc += ["-mno-outline-atomics"]
EOF
  fi
}

# Shared tail (icu/harfbuzz/freetype/png/zlib + module toggles) — identical
# for the native and wasm builds.
write_skia_args_common() {
  local out="$1"
  cat >> "$out" <<'EOF'

skia_use_icu = true
skia_use_client_icu = false
skia_use_icu4x = false
skia_use_libgrapheme = false
skia_use_system_icu = false
skia_use_harfbuzz = true
skia_use_system_harfbuzz = false
skia_use_freetype = true
skia_use_system_freetype2 = false
skia_use_libpng = true
skia_use_system_libpng = false
skia_use_zlib = true
skia_use_system_zlib = false
skia_use_libjpeg_turbo = false
skia_use_libjpeg_turbo_decode = false
skia_use_libjpeg_turbo_encode = false
skia_use_dng_sdk = false
skia_use_libwebp = false
skia_use_libwebp_decode = false
skia_use_libwebp_encode = false
skia_use_no_webp_encode = true
skia_use_wuffs = false
skia_use_expat = false
skia_use_fontconfig = false
skia_use_partition_alloc = false

skia_enable_skottie = false
skia_enable_skshaper = true
skia_enable_skparagraph = true
skia_enable_pdf = false
skia_enable_tools = false
EOF
  if [ "$SKIA_TARGET_OS" = "win" ]; then
    # No GCC-style flags: the MSVC toolchain (cl.exe) rejects -Wno-error and
    # libc++ does not exist on Windows (MSVC STL + /MT runtime instead).
    :
  else
    cat >> "$out" <<'EOF'

extra_cflags = [ "-Wno-error" ]
# Linux: compile Skia against libc++ to match zig's bundled libc++ at link time
# (CI installs libc++-dev). macOS + wasm: libc++ is the default anyway.
extra_cflags_cc = [ "-Wno-error", "-stdlib=libc++" ]
EOF
  fi
}

# Phase 3g wasm args (target_cpu = "wasm" implies target_os = "wasm",
# gn/BUILDCONFIG.gn). Graphite-Dawn over emdawnwebgpu → navigator.gpu is the
# primary backend; Ganesh WebGL2 stays compiled in as the fallback. Skia
# requires skia_enable_graphite whenever skia_use_dawn (gn/skia.gni assert).
# skia_use_webgpu pulls in the wgpu:: Surface/Device helpers used by
# src/gpu/graphite/dawn on __EMSCRIPTEN__. On wasm there is no dawn_native
# library — patch 005 turns //third_party/dawn into a header-free config so
# the WebGPU C API comes from Emscripten's -sUSE_WEBGPU at the app link.
# The wasm toolchain compiles with emcc/em++ from skia_emsdk_dir and emits
# lib<name>.wasm.a (gn/toolchain/BUILD.gn).
write_skia_args_wasm() {
  local out="$1"
  cat > "$out" <<EOF
is_debug = false
is_official_build = true
is_component_build = false
target_cpu = "wasm"

skia_emsdk_dir = "$DEPS/emsdk"
skia_emdawnwebgpu_dir = "$DEPS/emdawnwebgpu_pkg"

skia_use_webgl = true
skia_use_webgpu = true
skia_use_vulkan = false
skia_use_metal = false
skia_use_dawn = true
skia_use_direct3d = false
skia_use_x11 = false
skia_use_egl = false
skia_use_vma = false
skia_enable_ganesh = true
skia_enable_graphite = true
skia_enable_fontmgr_custom_embedded = true
skia_enable_fontmgr_custom_directory = true
EOF
  write_skia_args_common "$out"
}

build_skia() {
  local out="$SKIA/out/$TAG"
  if [ "$OS" = "Windows" ]; then
    if [ -f "$out/skia.lib" ]; then
      log "skia already built for $TAG"
      return 0
    fi
  elif [ -f "$out/libskia.a" ]; then
    log "skia already built for $TAG"
    return 0
  fi
  if [ "$OS" = "Windows" ]; then load_msvc_env; fi
  fetch_skia
  # Windows needs the Dawn externals (skia_use_dawn) — Dawn is built via
  # CMake inside the GN build, which hard-requires all of them.
  if [ "$SKIA_TARGET_OS" = "win" ]; then fetch_dawn; fi
  mkdir -p "$out"
  write_skia_args "$out/args.gn"
  local gn
  if [ -n "${KLAXON_GN:-}" ]; then
    gn="$KLAXON_GN" # e.g. Ubuntu arm64: bin/fetch-gn ships an x64-only binary
  else
    if [ ! -x "$SKIA/bin/gn" ] && [ ! -f "$SKIA/bin/gn.exe" ]; then
      log "fetch gn binary (bin/fetch-gn)"
      (cd "$SKIA" && python3 bin/fetch-gn)
    fi
    gn="$SKIA/bin/gn"
    [ -f "$SKIA/bin/gn.exe" ] && gn="$SKIA/bin/gn.exe"
  fi
  log "gn gen out/$TAG"
  (cd "$SKIA" && "$gn" gen "out/$TAG")
  log "ninja ($JOBS jobs) — the long step, ~15-45 min on first run (Dawn adds ~10-20)"
  CMAKE_BUILD_PARALLEL_LEVEL=$(( JOBS > 2 ? JOBS - 2 : 1 )) \
    ninja -C "$out" -j "$JOBS" skia modules/skparagraph:skparagraph modules/skshaper:skshaper
  if [ "$SKIA_TARGET_OS" = "win" ]; then
    # ICU data file — must sit next to the exe at runtime (skparagraph).
    local icudtl
    icudtl="$(find "$SKIA/third_party/externals/icu" -name icudtl.dat 2>/dev/null | head -1)"
    # find searches only externals/icu so the source is never the destination
    # (a prior run's copy in $out made cp self-copy → Git Bash hard-fails).
    [ -n "$icudtl" ] && cp -f "$icudtl" "$out/icudtl.dat"
    ls -la "$out"/*.lib
  else
    ls -la "$out"/*.a
  fi
}

# --- SDL3 -------------------------------------------------------------------

build_sdl3() {
  local src="$DEPS/SDL"
  local build="$src/build-$TAG"
  if [ -f "$build/libSDL3.a" ]; then
    log "SDL3 already built (build-$TAG)"
    return 0
  fi
  git_clone_at "$src" "$SDL3_URL" "$SDL3_PIN"
  log "cmake SDL3 ($TAG, static, trimmed)"
  local gen_args=()
  if [ "$OS" = "Windows" ]; then
    load_msvc_env
    # /MT: a /MD static lib carries /DEFAULTLIB:MSVCRT, which collides with
    # the static CRT the final exe links (build.zig win_libs).
    gen_args=(-G Ninja -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded)
  fi
  # Trimmed: camera/sensors are V2 platform services, SDL_GPU is unused (Skia renders).
  # Audio + haptics stay ON (v1 platform services, ADR-0005).
  # gen_args[@]+... : expand only when non-empty — bash 3.2 (macOS) treats an
  # empty "${arr[@]}" under set -u as unbound.
  cmake -S "$src" -B "$build" ${gen_args[@]+"${gen_args[@]}"} -DCMAKE_BUILD_TYPE=Release \
    -DSDL_SHARED=OFF -DSDL_STATIC=ON \
    -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL_TESTS=OFF \
    -DSDL_CAMERA=OFF -DSDL_SENSOR=OFF \
    -DSDL_GPU=OFF -DSDL_RENDER_GPU=OFF -DSDL_RENDER_VULKAN=OFF
  cmake --build "$build" --parallel "$JOBS"
  if [ "$OS" = "Windows" ]; then
    ls -la "$build"/SDL3-static.lib
  else
    ls -la "$build"/libSDL3.a
  fi
}

# --- WAMR -------------------------------------------------------------------
# fast-interp only: no JIT, no AOT (iOS-compatible), instruction metering on.
# Plugin runtime for klaxon-plugin-sdk — the framework itself does not link it.

build_wamr() {
  local src="$DEPS/wamr"
  local build="$src/build-$TAG"
  if [ -f "$build/libiwasm.a" ]; then
    log "wamr already built (build-$TAG)"
    return 0
  fi
  git_clone_at "$src" "$WAMR_URL" "$WAMR_PIN"
  log "cmake WAMR ($TAG, fast-interp)"
  local gen_args=()
  if [ "$OS" = "Windows" ]; then
    load_msvc_env
    gen_args=(-G Ninja -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded)
  fi
  cmake -S "$src/product-mini/platforms/$WAMR_PLATFORM" -B "$build" ${gen_args[@]+"${gen_args[@]}"} \
    -DCMAKE_BUILD_TYPE=Release \
    -DWAMR_BUILD_TARGET="$WAMR_TARGET" \
    -DWAMR_BUILD_INTERP=1 -DWAMR_BUILD_FAST_INTERP=1 \
    -DWAMR_BUILD_JIT=0 -DWAMR_BUILD_AOT=0 \
    -DWAMR_BUILD_LIBC_BUILTIN=0 -DWAMR_BUILD_LIBC_WASI=0 \
    -DWAMR_BUILD_SIMD=0 -DWAMR_BUILD_BULK_MEMORY=1 -DWAMR_BUILD_REF_TYPES=1 \
    -DWAMR_BUILD_INSTRUCTION_METERING=1
  cmake --build "$build" --parallel "$JOBS"
  # The vmlib target is renamed on output (set_target_properties OUTPUT_NAME iwasm).
  find "$build" -maxdepth 1 -name 'lib*.a' -exec ls -la {} +
}

# --- web-wasm (Phase 3f + 3g) -----------------------------------------------
# Heavy (~1-2 GB): NOT a default component. One emsdk, pinned to Skia's
# bin/activate-emsdk version — Skia's wasm objects and the app's emcc link
# (build.zig, `web` step) must use the same toolchain (plan §2).

build_emsdk() {
  local dir="$DEPS/emsdk"
  if [ -f "$dir/.emsdk-pin" ] && [ "$(cat "$dir/.emsdk-pin")" = "$EMSDK_PIN" ] \
    && [ -x "$dir/upstream/emscripten/emcc" ]; then
    log "emsdk already installed ($EMSDK_PIN)"
    return 0
  fi
  git_clone_at "$dir" "$EMSDK_URL" "$EMSDK_PIN"
  log "emsdk install + activate $EMSDK_PIN (large download)"
  (cd "$dir" && ./emsdk install "$EMSDK_PIN" && ./emsdk activate "$EMSDK_PIN")
  printf '%s\n' "$EMSDK_PIN" > "$dir/.emsdk-pin"
}

build_skia_wasm() {
  local out="$SKIA/out/web-wasm"
  if [ -f "$out/libskia.wasm.a" ]; then
    # Args drift (e.g. flipping skia_use_dawn) must force a rebuild — compare
    # the args we'd write with the ones the build was generated from.
    local want
    want="$(mktemp)"
    write_skia_args_wasm "$want"
    if cmp -s "$want" "$out/args.gn"; then
      rm -f "$want"
      log "skia wasm already built (out/web-wasm)"
      return 0
    fi
    rm -f "$want"
    log "skia wasm args changed — wiping out/web-wasm for a clean rebuild"
    rm -rf "$out"
  fi
  build_emsdk
  fetch_skia
  # bin/activate-emsdk drives third_party/externals/emsdk — symlink it at the
  # single repo-level emsdk (one toolchain for Skia objects + the app link).
  local emsdk_ext="$SKIA/third_party/externals/emsdk"
  if [ -d "$emsdk_ext" ] && [ ! -L "$emsdk_ext" ]; then
    die "$emsdk_ext exists — remove it so the build uses the single emsdk at $DEPS/emsdk"
  fi
  mkdir -p "$SKIA/third_party/externals"
  ln -sfn "$DEPS/emsdk" "$emsdk_ext"
  mkdir -p "$out"
  write_skia_args_wasm "$out/args.gn"
  if [ -n "${KLAXON_GN:-}" ]; then
    GN="$KLAXON_GN"
  else
    if [ ! -x "$SKIA/bin/gn" ]; then
      log "fetch gn binary (bin/fetch-gn)"
      (cd "$SKIA" && python3 bin/fetch-gn)
    fi
    GN="$SKIA/bin/gn"
  fi
  log "activate emsdk for skia (bin/activate-emsdk)"
  (cd "$SKIA" && python3 bin/activate-emsdk)
  log "gn gen out/web-wasm"
  (cd "$SKIA" && "$GN" gen out/web-wasm)
  log "ninja ($JOBS jobs) — the long step, ~15-45 min on first run"
  ninja -C "$out" -j "$JOBS" skia modules/skparagraph:skparagraph modules/skshaper:skshaper
  ls -la "$out"/*.wasm.a
}

build_sdl3_wasm() {
  local src="$DEPS/SDL"
  local build="$src/build-web-wasm"
  if [ -f "$build/libSDL3.a" ]; then
    log "SDL3 wasm already built (build-web-wasm)"
    return 0
  fi
  build_emsdk
  git_clone_at "$src" "$SDL3_URL" "$SDL3_PIN"
  log "emcmake SDL3 (web-wasm, static, trimmed, no pthreads)"
  # emcmake/emmake come from the activated emsdk.
  (
    export EMSDK="$DEPS/emsdk"
    export PATH="$DEPS/emsdk/upstream/emscripten:$DEPS/emsdk:$PATH"
    # Trimmed like the native build + SDL_PTHREADS=OFF (single-threaded wasm).
    emcmake cmake -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=Release \
      -DSDL_SHARED=OFF -DSDL_STATIC=ON \
      -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL_TESTS=OFF \
      -DSDL_CAMERA=OFF -DSDL_SENSOR=OFF \
      -DSDL_GPU=OFF -DSDL_RENDER_GPU=OFF -DSDL_RENDER_VULKAN=OFF \
      -DSDL_PTHREADS=OFF
    emmake cmake --build "$build" --parallel "$JOBS"
  )
  ls -la "$build"/libSDL3.a
}

# --- web-wasm: embedded default font ----------------------------------------
# Generates kx_skia/src/kx_font_wasm.h — DejaVu Sans embedded in the wasm
# binary so text renders in the browser (Devin issue #3 on PR #45). The header
# is generated, NOT committed (gitignored). Contract with
# kx_skia/src/kx_skia_wasm.cpp (picked up via __has_include, same directory):
#   static const unsigned char kKxDefaultFontData[] = { ...ttf bytes... };
#   static const size_t kKxDefaultFontSize = sizeof(kKxDefaultFontData);

# emdawnwebgpu package (Dawn release): standard-spec webgpu/webgpu_cpp headers
# + webgpu.cpp runtime impl + library_webgpu*.js libs. Skia's graphite-dawn
# sources compile against these headers on wasm (patches 005+007 route the
# old-spec __EMSCRIPTEN__ forks to the standard branch); build.zig compiles
# webgpu.cpp and links the JS libs. Emsdk 4.0.7 predates the remote port
# (needs 4.0.10+), so the pkg is fetched directly — same content, pinned.
EMDAWN_PKG_VER="v20261009.190412"
EMDAWN_PKG_URL="https://github.com/google/dawn/releases/download/${EMDAWN_PKG_VER}/emdawnwebgpu_pkg-${EMDAWN_PKG_VER}.zip"

fetch_emdawnwebgpu() {
  local dir="$DEPS/emdawnwebgpu_pkg"
  if [ -f "$dir/emdawnwebgpu.port.py" ] && [ -f "$dir/VERSION.txt" ]; then
    log "emdawnwebgpu pkg already installed ($EMDAWN_PKG_VER)"
    return 0
  fi
  local zip="$DEPS/emdawnwebgpu_pkg.zip"
  if [ ! -f "$zip" ]; then
    log "download emdawnwebgpu_pkg $EMDAWN_PKG_VER (~1 MB)"
    curl -fsSL -o "$zip" "$EMDAWN_PKG_URL" || die "failed to download emdawnwebgpu pkg"
  fi
  rm -rf "$dir"
  mkdir -p "$dir"
  python3 - "$zip" "$dir" <<'PYEOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
PYEOF
  [ -f "$dir/emdawnwebgpu.port.py" ] || die "emdawnwebgpu pkg extract incomplete"
}

FONT_ZIP_URL="https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_2_37/dejavu-fonts-ttf-2.37.zip"
FONT_ZIP_MEMBER="dejavu-fonts-ttf-2.37/ttf/DejaVuSans.ttf"

generate_font_header() {
  local out="$ROOT/kx_skia/src/kx_font_wasm.h"
  if [ -f "$out" ]; then
    log "kx_font_wasm.h already generated"
    return 0
  fi
  local font_dir="$DEPS/fonts"
  local ttf="$font_dir/DejaVuSans.ttf"
  mkdir -p "$font_dir"
  if [ ! -f "$ttf" ]; then
    # DejaVu Sans 2.37 (Bitstream Vera license / public domain — embeddable).
    # The upstream git repo ships no raw ttf (source-only); the release zip
    # does. Extraction uses python3's zipfile — unzip is not a prerequisite.
    local zip="$font_dir/dejavu-fonts-ttf-2.37.zip"
    if [ ! -f "$zip" ]; then
      log "download DejaVu Sans 2.37 release zip (~5 MB)"
      curl -fsSL -o "$zip" "$FONT_ZIP_URL" || die "failed to download DejaVuSans.ttf"
    fi
    log "extract $(basename "$ttf") from release zip"
    python3 - "$zip" "$FONT_ZIP_MEMBER" "$ttf" <<'PYEOF'
import sys, zipfile
zip_path, member, dst = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(zip_path) as z:
    with z.open(member) as src, open(dst, "wb") as out:
        out.write(src.read())
PYEOF
  fi
  log "generate kx_font_wasm.h from $(basename "$ttf") ($(wc -c < "$ttf") bytes)"
  # Atomic write: generate to a temp file then move — an interrupted run
  # must not leave a partial header that the idempotence check would skip.
  local tmp_out="$out.tmp"
  python3 - "$ttf" "$tmp_out" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    data = f.read()
with open(dst, "w") as f:
    f.write("// kx_font_wasm.h — generated by scripts/fetch-deps.sh\n")
    f.write("// Embedded default font (DejaVu Sans 2.37) for the WASM and Windows Skia backends.\n")
    f.write("// Regenerate: rm kx_skia/src/kx_font_wasm.h && scripts/fetch-deps.sh\n")
    f.write("#pragma once\n")
    f.write("#include <cstddef>\n")
    f.write("#include <cstdint>\n\n")
    f.write("static const unsigned char kKxDefaultFontData[] = {\n")
    for i in range(0, len(data), 16):
        chunk = data[i:i+16]
        f.write("    " + ",".join(f"0x{b:02x}" for b in chunk) + ",\n")
    f.write("};\n")
    f.write("static const size_t kKxDefaultFontSize = sizeof(kKxDefaultFontData);\n")
PYEOF
  mv "$tmp_out" "$out"
  ls -la "$out"
}

build_web_wasm() {
  build_emsdk
  fetch_emdawnwebgpu
  build_skia_wasm
  build_sdl3_wasm
  generate_font_header
}

# --- android-arm64 (Phase 3d) ------------------------------------------------
# Heavy: NOT a default component. Requires the Android NDK — detected via
# $ANDROID_NDK_HOME or the newest $ANDROID_HOME/ndk/<version>. Any supported
# host works (macOS arm64 dev host, Linux CI).

detect_ndk() {
  if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ]; then echo "$ANDROID_NDK_HOME"; return; fi
  if [ -n "${ANDROID_HOME:-}" ]; then
    local ndk_dir="$ANDROID_HOME/ndk"
    if [ -d "$ndk_dir" ]; then
      ls -1 "$ndk_dir" | sort -V | tail -1 | while read v; do echo "$ndk_dir/$v"; done | tail -1
      return
    fi
  fi
  die "Android NDK not found — set ANDROID_NDK_HOME or ANDROID_HOME"
}

write_skia_args_android() {
  local out="$1" ndk="$2"
  cat > "$out" <<EOF
is_debug = false
is_official_build = true
is_component_build = false
target_cpu = "arm64"
target_os = "android"
ndk = "$ndk"
ndk_api = 29

skia_use_gl = true
skia_use_vulkan = true
skia_use_metal = false
skia_use_dawn = false
skia_use_direct3d = false
skia_use_x11 = false
skia_use_egl = false
skia_use_vma = true
skia_enable_ganesh = true
skia_enable_graphite = true
skia_enable_fontmgr_android = false
EOF
  write_skia_args_common "$out"
}

build_skia_android() {
  local out="$SKIA/out/android-arm64"
  if [ -f "$out/libskia.a" ]; then
    log "skia already built for android-arm64"
    return 0
  fi
  local ndk
  ndk="$(detect_ndk)"
  fetch_skia
  # skia_use_vma=true compiles VulkanMemoryAllocatorWrapper.cpp against
  # vk_mem_alloc.h from this external (pin from Skia's DEPS at $SKIA_PIN).
  # Vulkan headers come from Skia's bundled include/third_party/vulkan.
  git_clone_at "$SKIA/third_party/externals/vulkanmemoryallocator" \
    "$CHROMIUM/external/github.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator.git" \
    eb744ea7a2b17040121b4bbb4d6f9e8a77e3cae7
  mkdir -p "$out"
  write_skia_args_android "$out/args.gn" "$ndk"
  if [ -n "${KLAXON_GN:-}" ]; then
    GN="$KLAXON_GN"
  else
    if [ ! -x "$SKIA/bin/gn" ]; then
      log "fetch gn binary (bin/fetch-gn)"
      (cd "$SKIA" && python3 bin/fetch-gn)
    fi
    GN="$SKIA/bin/gn"
  fi
  log "gn gen out/android-arm64"
  (cd "$SKIA" && "$GN" gen "out/android-arm64")
  log "ninja ($JOBS jobs) — the long step, ~15-45 min on first run"
  ninja -C "$out" -j "$JOBS" skia modules/skparagraph:skparagraph modules/skshaper:skshaper
  ls -la "$out"/*.a
}

build_sdl3_android() {
  local src="$DEPS/SDL"
  local build="$src/build-android-arm64"
  if [ -f "$build/libSDL3.so" ]; then
    log "SDL3 android-arm64 already built (build-android-arm64)"
    return 0
  fi
  local ndk
  ndk="$(detect_ndk)"
  git_clone_at "$src" "$SDL3_URL" "$SDL3_PIN"
  log "cmake SDL3 (android-arm64, shared, trimmed)"
  # Same trims as the native build, but a shared lib: the app loads
  # libSDL3.so from the APK. android.toolchain.cmake drives the NDK clang.
  cmake -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF \
    -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL_TESTS=OFF \
    -DSDL_CAMERA=OFF -DSDL_SENSOR=OFF \
    -DSDL_GPU=OFF -DSDL_RENDER_GPU=OFF -DSDL_RENDER_VULKAN=OFF
  cmake --build "$build" --parallel "$JOBS"
  ls -la "$build"/libSDL3.so
}

build_android_arm64() {
  detect_ndk >/dev/null # fail fast when the NDK is missing
  build_skia_android
  build_sdl3_android
}

# --- ios (Phase 3e) ----------------------------------------------------------
# Heavy: NOT a default component. macOS arm64 + Xcode only. Four artifacts:
# Skia device + simulator, SDL3 device + simulator (static libs linked by the
# Xcode project into the app / the simulator binary).

write_skia_args_ios() {
  local out="$1" sysroot="$2" sim="$3"
  if [ "$sim" = "1" ]; then
    # Simulator: explicit sysroot (xcrun --sdk iphonesimulator).
    # ios_min_target feeds Skia's -miphonesimulator-version-min and is forwarded
    # to the Dawn CMake build (see scripts/patches/); the extra_* flags appended
    # below repeat the deployment target in the -mios-simulator-version-min
    # spelling. ios_use_simulator is not Skia's default for target_cpu="arm64".
    cat > "$out" <<EOF
is_debug = false
is_official_build = true
is_component_build = false
target_cpu = "arm64"
target_os = "ios"
ios_use_simulator = true
xcode_sysroot = "$sysroot"
ios_min_target = "15.0"

skia_use_metal = true
skia_use_gl = true
skia_use_vulkan = false
skia_use_dawn = true
skia_use_direct3d = false
skia_use_x11 = false
skia_use_egl = false
skia_use_vma = false
skia_enable_ganesh = true
skia_enable_graphite = true
EOF
  else
    # Device: xcode_sysroot left unset — Skia resolves it via
    # gn/find_xcode_sysroot.py with the iphoneos SDK (gn/skia/BUILD.gn).
    cat > "$out" <<EOF
is_debug = false
is_official_build = true
is_component_build = false
target_cpu = "arm64"
target_os = "ios"
ios_min_target = "15.0"

skia_use_metal = true
skia_use_gl = true
skia_use_vulkan = false
skia_use_dawn = true
skia_use_direct3d = false
skia_use_x11 = false
skia_use_egl = false
skia_use_vma = false
skia_enable_ganesh = true
skia_enable_graphite = true
EOF
  fi
  write_skia_args_common "$out"
  if [ "$sim" = "1" ]; then
    # gn rejects a second `=` on an arg already set (common writes
    # extra_cflags/_cc above) — append with += instead. extra_ldflags is
    # unset by common, so `=` is correct there.
    cat >> "$out" <<'EOF'

extra_cflags += ["-mios-simulator-version-min=15.0"]
extra_cflags_cc += ["-mios-simulator-version-min=15.0"]
extra_ldflags = ["-mios-simulator-version-min=15.0"]
EOF
  fi
}

build_skia_ios() {
  local out="$SKIA/out/ios-arm64"
  if [ -f "$out/libskia.a" ]; then
    log "skia already built for ios-arm64"
    return 0
  fi
  fetch_skia
  fetch_dawn
  mkdir -p "$out"
  write_skia_args_ios "$out/args.gn" "" 0
  if [ -n "${KLAXON_GN:-}" ]; then
    GN="$KLAXON_GN"
  else
    if [ ! -x "$SKIA/bin/gn" ]; then
      log "fetch gn binary (bin/fetch-gn)"
      (cd "$SKIA" && python3 bin/fetch-gn)
    fi
    GN="$SKIA/bin/gn"
  fi
  log "gn gen out/ios-arm64"
  (cd "$SKIA" && "$GN" gen "out/ios-arm64")
  log "ninja ($JOBS jobs) — the long step; Dawn's CMake build adds ~10-20 min on first run"
  # build_dawn.py runs an inner ninja for Dawn; cap it (CMAKE_BUILD_PARALLEL_LEVEL)
  # so outer + inner clang processes stay within a 16 GB host's memory budget.
  CMAKE_BUILD_PARALLEL_LEVEL=$(( JOBS > 2 ? JOBS - 2 : 1 )) \
    ninja -C "$out" -j "$JOBS" skia modules/skparagraph:skparagraph modules/skshaper:skshaper
  ls -la "$out"/*.a
}

build_skia_ios_sim() {
  local out="$SKIA/out/ios-sim-arm64"
  if [ -f "$out/libskia.a" ]; then
    log "skia already built for ios-sim-arm64"
    return 0
  fi
  local sysroot
  sysroot="$(xcrun --sdk iphonesimulator --show-sdk-path)"
  fetch_skia
  fetch_dawn
  mkdir -p "$out"
  write_skia_args_ios "$out/args.gn" "$sysroot" 1
  if [ -n "${KLAXON_GN:-}" ]; then
    GN="$KLAXON_GN"
  else
    if [ ! -x "$SKIA/bin/gn" ]; then
      log "fetch gn binary (bin/fetch-gn)"
      (cd "$SKIA" && python3 bin/fetch-gn)
    fi
    GN="$SKIA/bin/gn"
  fi
  log "gn gen out/ios-sim-arm64"
  (cd "$SKIA" && "$GN" gen "out/ios-sim-arm64")
  log "ninja ($JOBS jobs) — the long step; Dawn's CMake build adds ~10-20 min on first run"
  # build_dawn.py runs an inner ninja for Dawn; cap it (CMAKE_BUILD_PARALLEL_LEVEL)
  # so outer + inner clang processes stay within a 16 GB host's memory budget.
  CMAKE_BUILD_PARALLEL_LEVEL=$(( JOBS > 2 ? JOBS - 2 : 1 )) \
    ninja -C "$out" -j "$JOBS" skia modules/skparagraph:skparagraph modules/skshaper:skshaper
  ls -la "$out"/*.a
}

build_sdl3_ios() {
  local src="$DEPS/SDL"
  local build="$src/build-ios-arm64"
  if [ -f "$build/libSDL3.a" ]; then
    log "SDL3 ios-arm64 already built (build-ios-arm64)"
    return 0
  fi
  git_clone_at "$src" "$SDL3_URL" "$SDL3_PIN"
  log "cmake SDL3 (ios-arm64 device, static, trimmed)"
  cmake -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DSDL_SHARED=OFF -DSDL_STATIC=ON \
    -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL_TESTS=OFF \
    -DSDL_CAMERA=OFF -DSDL_SENSOR=OFF \
    -DSDL_GPU=OFF -DSDL_RENDER_GPU=OFF -DSDL_RENDER_VULKAN=OFF
  cmake --build "$build" --parallel "$JOBS"
  ls -la "$build"/libSDL3.a
}

build_sdl3_ios_sim() {
  local src="$DEPS/SDL"
  local build="$src/build-ios-sim-arm64"
  if [ -f "$build/libSDL3.a" ]; then
    log "SDL3 ios-sim-arm64 already built (build-ios-sim-arm64)"
    return 0
  fi
  git_clone_at "$src" "$SDL3_URL" "$SDL3_PIN"
  log "cmake SDL3 (ios-sim-arm64, static, trimmed)"
  cmake -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DSDL_SHARED=OFF -DSDL_STATIC=ON \
    -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL_TESTS=OFF \
    -DSDL_CAMERA=OFF -DSDL_SENSOR=OFF \
    -DSDL_GPU=OFF -DSDL_RENDER_GPU=OFF -DSDL_RENDER_VULKAN=OFF
  cmake --build "$build" --parallel "$JOBS"
  ls -la "$build"/libSDL3.a
}

build_ios() {
  if [ "$OS:$ARCH" != "Darwin:arm64" ]; then
    die "ios component requires a macOS arm64 host with Xcode (got $OS/$ARCH)"
  fi
  build_skia_ios
  build_skia_ios_sim
  build_sdl3_ios
  build_sdl3_ios_sim
}

# --- main -------------------------------------------------------------------

# Guard: sourcing this script (e.g. to call generate_font_header in a test)
# must not run the component build.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  COMPONENTS=("$@")
  if [ "${#COMPONENTS[@]}" -eq 0 ]; then
    COMPONENTS=(skia sdl3 wamr)
  fi

  mkdir -p "$DEPS"

  # Fast path: prebuilt artifacts — each component maps to a bundle; the
  # first component of a bundle downloads it (idempotent: stamped + the
  # per-component builders below skip whatever already exists).
  bundles_done=" "
  for component in "${COMPONENTS[@]}"; do
    bundle="$(component_bundle "$component")"
    case "$bundles_done" in
      *" $bundle "*) ;;
      *)
        bundles_done="$bundles_done$bundle "
        satisfied "$component" || try_artifact "$bundle" || true
        ;;
    esac
  done

  for component in "${COMPONENTS[@]}"; do
    case "$component" in
      skia) build_skia ;;
      sdl3) build_sdl3 ;;
      wamr) build_wamr ;;
      web-wasm) build_web_wasm ;;
      android-arm64) build_android_arm64 ;;
      ios) build_ios ;;
      *) die "unknown component '$component' (expected: skia | sdl3 | wamr | web-wasm | android-arm64 | ios)" ;;
    esac
  done

  # Windows embeds the same DejaVu default font as web-wasm (icon/symbol
  # coverage + deterministic metrics across platforms).
  case "$TAG" in
    windows-*) generate_font_header ;;
  esac

  log "done — artifacts in $DEPS ($TAG)"
  du -sh "$DEPS" 2>/dev/null || true
fi
