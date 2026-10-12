#!/bin/bash
# package-windows-msi.sh — build + package a Klaxon app into a WiX .msi (Windows x64).
#
# Usage: scripts/package-windows-msi.sh [app-name] [output-dir] [options]
#   app-name   — one of: hello, gallery, navigator, i18n, a11y (default: gallery)
#   output-dir — where to place the .msi (default: ./dist)
#   --version V   — product version baked into the .msi
#                   (default: newest git tag, else 0.1.0; normalized to a.b.c)
#   --no-build    — skip `zig build` (reuse the exe already in zig-out/bin)
#   --dry-run     — print the resolved plan + the exact tool commands; build
#                   nothing, write nothing
#
# Produces: <output-dir>/klaxon-<app>-windows-x64.msi
#
# WiX source: packaging/windows/klaxon.wxs (v3 syntax + <?define?> knobs, so
# one file serves every toolchain). Two toolchains are supported, first match
# wins:
#
#   1) WiX v4/v5 .NET tool — `wix`/`wix.exe` on PATH
#        install: dotnet tool install -g wix          (verify: wix --version)
#      The .wxs is copied to a scratch dir and `wix convert`-ed to v4 syntax
#      (wix v4+ refuses the v3 namespace), then `wix build -arch x64`.
#
#   2) WiX v3 — `candle(.exe)` + `light(.exe)` on PATH
#        install: choco install wixtoolset    (or unpack wix311-binaries.zip
#                 and put it on PATH)
#      Direct: candle -arch x64 → light.
#
# CI wiring: the windows-latest job is owned by another in-flight PR and is
# intentionally NOT touched here. Once it lands it only needs:
#     dotnet tool install -g wix
#     scripts/package-windows-msi.sh gallery ./dist
set -euo pipefail

# ---------- args ----------
APP_NAME=""
OUTPUT_DIR=""
VERSION_ARG=""
NO_BUILD=false
DRY_RUN=false

usage() { sed -n '2,15p' "$0"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version)   VERSION_ARG="${2:?--version needs a value}"; shift 2 ;;
        --version=*) VERSION_ARG="${1#*=}"; shift ;;
        --no-build)  NO_BUILD=true; shift ;;
        --dry-run)   DRY_RUN=true; shift ;;
        -h|--help)   usage; exit 0 ;;
        -*)          echo "Unknown option: $1"; usage; exit 1 ;;
        *)
            if [ -z "${APP_NAME}" ]; then APP_NAME="$1"
            elif [ -z "${OUTPUT_DIR}" ]; then OUTPUT_DIR="$1"
            else echo "Unexpected argument: $1"; usage; exit 1
            fi
            shift ;;
    esac
done

APP_NAME="${APP_NAME:-gallery}"
OUTPUT_DIR="${OUTPUT_DIR:-./dist}"
MSI_NAME="klaxon-${APP_NAME}-windows-x64.msi"

case "${APP_NAME}" in
    hello|gallery|navigator|i18n|a11y) ;;
    *) echo "Unknown app: ${APP_NAME}"; echo "Valid: hello, gallery, navigator, i18n, a11y"; exit 1 ;;
esac

EXE_NAME="${APP_NAME}.exe"
# Title-case for "Klaxon <App>" (Product name, install dir, shortcut).
APP_TITLE="$(printf '%s' "${APP_NAME}" | cut -c1 | tr '[:lower:]' '[:upper:]')${APP_NAME:1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WXS="${REPO_ROOT}/packaging/windows/klaxon.wxs"

# Same stage dir as package-windows.sh — the .msi payload is identical to the
# portable .zip's contents (exe + optional runtime files).
STAGE_DIR="${OUTPUT_DIR}/Klaxon-${APP_NAME}-windows-x64"
WIX_WORK="${OUTPUT_DIR}/.wix-${APP_NAME}"        # candle .wixobj / wix convert scratch

# ---------- product version: --version > git tag > 0.1.0, normalized a.b.c ----------
VERSION="${VERSION_ARG}"
if [ -z "${VERSION}" ]; then
    # Newest git tag wins, but only if it actually carries a major.minor
    # version — this repo also has non-version tags (deps-<sha>).
    CAND=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^[vV]//; s/[^0-9.].*$//' || true)
    case "${CAND}" in
        [0-9]*.[0-9]*) VERSION="${CAND}" ;;
        *)             VERSION="0.1.0" ;;
    esac
fi
VERSION=$(printf '%s' "${VERSION}" | sed 's/^[vV]//; s/[^0-9.].*$//')
IFS='.' read -r v1 v2 v3 _rest <<< "${VERSION}"
VERSION="${v1:-0}.${v2:-0}.${v3:-0}"

# ---------- UpgradeCode: one fixed base UUID, derived deterministically per app ----------
# A single shared code would make installing "Klaxon Gallery" remove "Klaxon
# Hello" (same product family → major upgrade). md5(base:app) is stable across
# machines and rebuilds, so every app gets its own reproducible GUID.
BASE_UPGRADE_CODE="EE54060F-0A3A-4A97-96A0-ACD2235BC6D4"
md5_hex() {
    if command -v md5sum >/dev/null 2>&1; then printf '%s' "$1" | md5sum | cut -c1-32
    elif command -v md5 >/dev/null 2>&1;    then printf '%s' "$1" | md5 -q
    else printf '%s' "$1" | shasum -a 256 | cut -c1-32   # last resort: sha256, truncated
    fi
}
H=$(printf '%s' "$(md5_hex "${BASE_UPGRADE_CODE}:${APP_NAME}")" | tr '[:lower:]' '[:upper:]')
UPGRADE_CODE="${H:0:8}-3${H:13:3}-8${H:17:3}-${H:20:12}"   # v3-variant formatting (cosmetic)

# ---------- path conversion for native tools (Git Bash/MSYS2/WSL → C:\...) ----------
CONVERT=""
if command -v cygpath >/dev/null 2>&1; then CONVERT=cygpath; fi
if command -v wslpath >/dev/null 2>&1; then CONVERT=wslpath; fi
win_path() { if [ -n "${CONVERT}" ]; then ${CONVERT} -w "$1"; else printf '%s' "$1"; fi; }

# ---------- toolchain detection ----------
find_tool() { for t in "$@"; do command -v "${t}" >/dev/null 2>&1 && { command -v "${t}"; return 0; }; done; return 1; }

WIX="$(find_tool wix wix.exe || true)"
CANDLE="$(find_tool candle candle.exe || true)"
LIGHT="$(find_tool light light.exe || true)"

MODE=""
if [ -n "${WIX}" ] && "${WIX}" --version >/dev/null 2>&1; then
    MODE="wix4+"
elif [ -n "${CANDLE}" ] && [ -n "${LIGHT}" ]; then
    MODE="wix3"
fi

NO_TOOLCHAIN=false
if [ -z "${MODE}" ]; then
    if [ "${DRY_RUN}" = true ]; then
        # No tool installed — still show the plan (the preferred v4+ shape).
        NO_TOOLCHAIN=true; MODE="wix4+"; WIX="wix"
    else
        echo "Error: no WiX toolchain found. Install one of:"
        echo "  WiX v4/v5:  dotnet tool install -g wix     (then: wix --version)"
        echo "  WiX v3:     choco install wixtoolset     (candle.exe + light.exe on PATH)"
        exit 1
    fi
fi

# ---------- build ----------
if [ "${DRY_RUN}" = false ] && [ "${NO_BUILD}" = false ]; then
    echo "==> zig build"
    zig build
fi

EXE_SRC="zig-out/bin/${EXE_NAME}"
if [ "${DRY_RUN}" = false ] && [ ! -f "${EXE_SRC}" ]; then
    echo "Error: executable not found at ${EXE_SRC} (build first, or drop --no-build)"
    exit 1
fi

# ---------- stage the payload (exe + optional runtime files) ----------
HAS_ICU=no; HAS_DXC=no
SKIA_OUT="deps/skia/out/windows-x64"
DXC_BIN=""
for d in \
    "/c/Program Files (x86)/Windows Kits/10/bin"/*/x64 \
    "C:/Program Files (x86)/Windows Kits/10/bin"/*/x64; do
    [ -f "${d}/dxcompiler.dll" ] && DXC_BIN="${d}" && break
done
[ -f "${SKIA_OUT}/icudtl.dat" ] && HAS_ICU=yes
[ -n "${DXC_BIN}" ] && HAS_DXC=yes

if [ "${DRY_RUN}" = false ]; then
    rm -rf "${STAGE_DIR}"
    mkdir -p "${STAGE_DIR}"
    cp "${EXE_SRC}" "${STAGE_DIR}/"
    if [ "${HAS_ICU}" = yes ]; then
        cp "${SKIA_OUT}/icudtl.dat" "${STAGE_DIR}/"
    else
        echo "Warning: icudtl.dat not found under ${SKIA_OUT} — .msi will lack ICU data"
    fi
    if [ "${HAS_DXC}" = yes ]; then
        cp "${DXC_BIN}/dxcompiler.dll" "${DXC_BIN}/dxil.dll" "${STAGE_DIR}/"
    else
        echo "Warning: dxcompiler.dll/dxil.dll not found — .msi will lack the D3D shader compiler"
    fi
    mkdir -p "${OUTPUT_DIR}"
fi

# ---------- resolved defines ----------
# Native WiX tools need absolute, Windows-style paths — a relative or
# MSYS-style /c/... path inside the .wxs Source attributes would not resolve.
case "${STAGE_DIR}" in
    /*|[A-Za-z]:*) STAGE_ABS="${STAGE_DIR}" ;;
    *)             STAGE_ABS="${PWD}/${STAGE_DIR}" ;;
esac
STAGE_ABS="$(printf '%s' "${STAGE_ABS}" | sed 's|/\./|/|g')"
STAGE_WIN="$(win_path "${STAGE_ABS}")"
ROOT_WIN="$(win_path "${REPO_ROOT}")"

DEFINES=(
    "AppName=${APP_NAME}"
    "AppTitle=${APP_TITLE}"
    "AppExe=${EXE_NAME}"
    "ProductVersion=${VERSION}"
    "UpgradeCode=${UPGRADE_CODE}"
    "StageDir=${STAGE_WIN}"
    "RepoRoot=${ROOT_WIN}"
    "HasIcu=${HAS_ICU}"
    "HasDxc=${HAS_DXC}"
)

MSI_PATH="${OUTPUT_DIR}/${MSI_NAME}"
MSI_WIN="$(win_path "${MSI_PATH}")"         # native tools need Windows-style paths
WIX_WORK_WIN="$(win_path "${WIX_WORK}")"

# ---------- dry run: print the plan ----------
if [ "${DRY_RUN}" = true ]; then
    echo "==> Dry run — nothing was built or written"
    [ "${NO_TOOLCHAIN}" = true ] && echo "    note: no WiX toolchain on PATH — plan shows the wix v4+ shape; candle/light (v3) is also supported"
    echo "    app:          ${APP_NAME} (\"Klaxon ${APP_TITLE}\")"
    echo "    version:      ${VERSION}"
    echo "    upgrade code: ${UPGRADE_CODE}  (derived from ${BASE_UPGRADE_CODE})"
    echo "    toolchain:    ${MODE} ($([ "${MODE}" = "wix4+" ] && echo "${WIX}" || echo "${CANDLE} + ${LIGHT}"))"
    echo "    wxs:          ${WXS}"
    echo "    stage dir:    ${STAGE_DIR}  (icudtl.dat: ${HAS_ICU}, dxc: ${HAS_DXC})"
    echo "    output:       ${MSI_PATH}"
    echo ""
    if [ "${MODE}" = "wix3" ]; then
        echo "    would run:"
        printf '      %s -nologo -arch x64' "${CANDLE}"
        for d in "${DEFINES[@]}"; do printf ' -d%s' "${d}"; done
        printf ' -out %s/klaxon.wixobj %s\n' "${WIX_WORK_WIN}" "${WXS}"
        echo "      ${LIGHT} -nologo -out ${MSI_WIN} ${WIX_WORK_WIN}/klaxon.wixobj"
    else
        echo "    would run:"
        echo "      ${WIX} convert ${WXS} ${WIX_WORK}/klaxon-v4.wxs"
        printf '      %s build -nologo -arch x64' "${WIX}"
        for d in "${DEFINES[@]}"; do printf ' -d %s' "${d}"; done
        printf ' %s -o %s\n' "${WIX_WORK}/klaxon-v4.wxs" "${MSI_WIN}"
    fi
    exit 0
fi

# ---------- compile + link ----------
rm -rf "${WIX_WORK}"
mkdir -p "${WIX_WORK}"

if [ "${MODE}" = "wix3" ]; then
    echo "==> WiX v3: candle + light"
    CANDLE_DEFS=()
    for d in "${DEFINES[@]}"; do CANDLE_DEFS+=("-d${d}"); done
    "${CANDLE}" -nologo -arch x64 "${CANDLE_DEFS[@]}" \
        -out "${WIX_WORK_WIN}/klaxon.wixobj" "${WXS}"
    "${LIGHT}" -nologo -out "${MSI_WIN}" "${WIX_WORK_WIN}/klaxon.wixobj"
else
    echo "==> WiX v4/v5: wix convert + wix build ($("${WIX}" --version 2>/dev/null | head -1))"
    # wix v4+ cannot read the v3 namespace — convert a scratch copy first.
    V4_WXS="${WIX_WORK}/klaxon-v4.wxs"
    if ! "${WIX}" convert "${WXS}" "${V4_WXS}" 2>/dev/null; then
        # older v4 builds only support in-place: convert <file>
        cp "${WXS}" "${V4_WXS}"
        "${WIX}" convert "${V4_WXS}"
    fi
    WIX_DEFS=()
    for d in "${DEFINES[@]}"; do WIX_DEFS+=("-d" "${d}"); done
    "${WIX}" build -nologo -arch x64 "${WIX_DEFS[@]}" "${V4_WXS}" -o "${MSI_WIN}"
fi

MSI_SIZE=$(du -h "${MSI_PATH}" | cut -f1)
echo ""
echo "==> Done: ${MSI_PATH} (${MSI_SIZE})"
echo "    Per-user install — no elevation. Payload: ${EXE_NAME}, LICENSE, NOTICE"
echo "    + Start Menu shortcut (icudtl.dat: ${HAS_ICU}, dxc: ${HAS_DXC})"
