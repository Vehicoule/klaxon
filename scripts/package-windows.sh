#!/bin/bash
# package-windows.sh — build + package a Klaxon app into a portable .zip (Windows x64).
#
# Usage: scripts/package-windows.sh [app-name] [output-dir]
#   app-name   — one of: hello, gallery, navigator, i18n, a11y (default: gallery)
#   output-dir — where to place the zip (default: ./dist)
#
# Produces: <output-dir>/Klaxon-<app>-windows-x64.zip
# The zip is self-contained: <app>.exe plus the runtime files the Skia/Dawn
# backend needs (icudtl.dat, dxcompiler.dll, dxil.dll). SDL3 is linked
# statically, so no SDL3.dll ships.
set -euo pipefail

APP_NAME="${1:-gallery}"
OUTPUT_DIR="${2:-./dist}"
ZIP_NAME="Klaxon-${APP_NAME}-windows-x64.zip"
STAGE_DIR="${OUTPUT_DIR}/Klaxon-${APP_NAME}-windows-x64"

case "${APP_NAME}" in
    hello|gallery|navigator|i18n|a11y) ;;
    *) echo "Unknown app: ${APP_NAME}"; echo "Valid: hello, gallery, navigator, i18n, a11y"; exit 1 ;;
esac

EXE_NAME="${APP_NAME}.exe"

# Plain `zig build`: the app steps (gallery/navigator/...) are run-steps that
# would LAUNCH the demo — fine interactively, fatal on a headless packager.
# The default step installs every exe to zig-out/bin; pick ours by name.
echo "==> zig build"
zig build

EXE_SRC="zig-out/bin/${EXE_NAME}"
if [ ! -f "${EXE_SRC}" ]; then
    echo "Error: executable not found at ${EXE_SRC}"
    exit 1
fi

EXE_SIZE=$(du -h "${EXE_SRC}" | cut -f1)
echo "==> Executable: ${EXE_SRC} (${EXE_SIZE})"

rm -rf "${STAGE_DIR}" "${OUTPUT_DIR}/${ZIP_NAME}"
mkdir -p "${STAGE_DIR}"
cp "${EXE_SRC}" "${STAGE_DIR}/"

# Runtime files for the D3D12/Dawn backend and ICU text stack. Both are
# optional at runtime — the backend list walks raster → gl first, so the app
# still runs without them — but ship them so graphite-dawn works out of the box.
SKIA_OUT="deps/skia/out/windows-x64"
[ -f "${SKIA_OUT}/icudtl.dat" ] && cp "${SKIA_OUT}/icudtl.dat" "${STAGE_DIR}/" || \
    echo "Warning: icudtl.dat not found under ${SKIA_OUT} (ICU data; run scripts/fetch-deps.sh)"

DXC_BIN=""
for d in \
    "/c/Program Files (x86)/Windows Kits/10/bin"/*/x64 \
    "C:/Program Files (x86)/Windows Kits/10/bin"/*/x64; do
    [ -f "${d}/dxcompiler.dll" ] && DXC_BIN="${d}" && break
done
if [ -n "${DXC_BIN}" ]; then
    cp "${DXC_BIN}/dxcompiler.dll" "${DXC_BIN}/dxil.dll" "${STAGE_DIR}/"
else
    echo "Warning: dxcompiler.dll/dxil.dll not found (Windows SDK D3D shader compiler) — D3D12 backend will fall back"
fi

# Zip it. Prefer zip(1); else PowerShell's Compress-Archive — but only when
# a path converter exists (cygpath on Git Bash/MSYS2, wslpath on WSL) and
# the converted paths carry no quote that could break -Command parsing.
echo "==> Creating ${ZIP_NAME}..."
CONVERT=""
if command -v cygpath >/dev/null 2>&1; then CONVERT=cygpath; fi
if command -v wslpath >/dev/null 2>&1; then CONVERT=wslpath; fi

if command -v zip >/dev/null 2>&1; then
    (cd "${STAGE_DIR}" && zip -qr "../${ZIP_NAME}" .)
elif command -v powershell.exe >/dev/null 2>&1 && [ -n "${CONVERT}" ]; then
    STAGE_WIN=$(${CONVERT} -w "${STAGE_DIR}")
    ZIP_WIN=$(${CONVERT} -w "${OUTPUT_DIR}/${ZIP_NAME}")
    case "${STAGE_WIN}${ZIP_WIN}" in
        *"'"*) echo "Error: path contains a quote — cannot pass to PowerShell -Command"; exit 1 ;;
    esac
    powershell.exe -NoProfile -Command \
        "Compress-Archive -Path '${STAGE_WIN}\*' -DestinationPath '${ZIP_WIN}' -Force" >/dev/null
else
    echo "Error: no zip tool found (need zip, or powershell.exe + cygpath/wslpath)"
    exit 1
fi

ZIP_SIZE=$(du -h "${OUTPUT_DIR}/${ZIP_NAME}" | cut -f1)
echo ""
echo "==> Done: ${OUTPUT_DIR}/${ZIP_NAME} (${ZIP_SIZE})"
echo "    Contents: ${EXE_NAME}, icudtl.dat, dxcompiler.dll, dxil.dll"
