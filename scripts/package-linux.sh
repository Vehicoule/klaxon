#!/usr/bin/env bash
# package-linux.sh — build + package a Klaxon app for Linux (Phase 3a.2 / 5b).
#
# Usage:
#   scripts/package-linux.sh [app] [arch] [formats...] [options]
#
#   app      — one of: hello, gallery, navigator, i18n, a11y (default: gallery)
#   arch     — x64 | arm64 (also accepts x86_64|amd64, aarch64).
#              Default: uname -m mapped (x86_64→x64, aarch64→arm64).
#   formats  — any of: appimage, deb, rpm, flatpak (default: all four)
#
# Options:
#   --output DIR   — artifact directory (default: ./dist)
#   --version V    — package version (default: v* git tag, else 0.1.0+git.<sha>)
#   --no-build     — reuse zig-out/bin/<app> (skip zig build)
#   --dry-run      — print the plan (tools, artifacts) and exit
#   -h, --help     — this help
#
# Produces (in --output):
#   Klaxon-<app>-<ver>-linux-<arch>.AppImage
#   klaxon-<app>_<ver>_<amd64|arm64>.deb
#   klaxon-<app>-<ver>-1.<x86_64|aarch64>.rpm
#   Klaxon-<app>-<ver>-linux-<arch>.flatpak   (needs flatpak-builder + flatpak)
#   org.klaxon.<App>.yml                      (Flatpak manifest — always emitted)
#
# Runtime dependency model: Klaxon apps are statically linked — Skia, WAMR
# and SDL3 are all static archives; libc++ is Zig's bundled build. The only
# dynamic NEEDED entries are the glibc family (libc/libm/libdl/libpthread,
# ld-linux) and libstdc++/libgcc when present. SDL3 dlopen()s the display
# stack (libX11/libwayland-client/libxkbcommon/...) at runtime, so those are
# NOT in `ldd` output — they are expected from the host (or the Flatpak
# runtime) and are only Recommends: in the .deb.
#
# For AppImage/Flatpak we run `ldd zig-out/bin/<app>` and copy every NON-core
# shared library into the bundle (usr/lib resp. /app/lib), so anything the
# linker pulled beyond glibc still ships. On a normal Klaxon build the list
# is empty — the bundles end up glibc-only like the AppImage spec intends.
#
# Tool requirements (per format; checked before building):
#   deb      dpkg-deb          apt install dpkg          / brew install dpkg
#   rpm      rpmbuild          apt install rpm           / brew install rpm
#   appimage appimagetool      auto-downloaded per-arch into deps/tools/ when
#                              absent (uses linuxdeploy instead when present)
#   flatpak  flatpak-builder   apt install flatpak-builder — optional: the
#            (+ flatpak)       manifest yml is emitted to dist/ regardless;
#                              flatpak(1) is needed only for the .flatpak
#                              single-file bundle.
#
# Must run on Linux for real packaging (appimagetool is a Linux binary;
# dpkg/rpm are expected on the target distro / CI). --dry-run works anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."

# ---------------------------------------------------------------- helpers ---
log()  { echo "==> $*"; }
warn() { echo "Warning: $*" >&2; }
die()  { echo "Error: $*" >&2; exit 1; }

# need_tool <cmd> <apt-pkg> <brew-pkg>
need_tool() {
    command -v "$1" >/dev/null 2>&1 && return 0
    die "'$1' not found — install it with: apt install $2   (or: brew install $3)"
}

# ------------------------------------------------------------------- args ---
APP_NAME=""
ARCH=""
declare -a FORMATS=()
OUTPUT_DIR="./dist"
VERSION=""
DO_BUILD=1
DRY_RUN=0

usage() { awk '/^#!/{next} /^#/{sub(/^# ?/, ""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
    case "$1" in
        hello|gallery|navigator|i18n|a11y)
            [ -z "${APP_NAME}" ] || die "two app names given: ${APP_NAME} and $1"
            APP_NAME="$1" ;;
        x64|x86_64|amd64|arm64|aarch64)
            [ -z "${ARCH}" ] || die "two arches given: ${ARCH} and $1"
            ARCH="$1" ;;
        appimage|deb|rpm|flatpak)
            FORMATS+=("$1") ;;
        all)
            FORMATS+=(appimage deb rpm flatpak) ;;
        --output)   OUTPUT_DIR="${2:?--output needs a dir}"; shift ;;
        --output=*) OUTPUT_DIR="${1#--output=}" ;;
        --version)  VERSION="${2:?--version needs a value}"; shift ;;
        --version=*) VERSION="${1#--version=}" ;;
        --no-build) DO_BUILD=0 ;;
        --dry-run)  DRY_RUN=1 ;;
        -h|--help)  usage; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
    shift
done

APP_NAME="${APP_NAME:-gallery}"
if [ -z "${ARCH}" ]; then
    case "$(uname -m)" in
        x86_64|amd64)  ARCH="x64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) die "unsupported host arch $(uname -m) — pass x64 or arm64 explicitly" ;;
    esac
fi
# Normalize arch → canonical x64|arm64 plus per-ecosystem spellings.
case "${ARCH}" in
    x64|x86_64|amd64)
        ARCH="x64"
        ZIG_TARGET="x86_64-linux-gnu";  DEB_ARCH="amd64"
        RPM_ARCH="x86_64";              AI_ARCH="x86_64"
        FLATPAK_ARCH="x86_64" ;;
    arm64|aarch64)
        ARCH="arm64"
        ZIG_TARGET="aarch64-linux-gnu"; DEB_ARCH="arm64"
        RPM_ARCH="aarch64";             AI_ARCH="aarch64"
        FLATPAK_ARCH="aarch64" ;;
    *) die "unknown arch: ${ARCH} (want x64|arm64)" ;;
esac
[ ${#FORMATS[@]} -gt 0 ] || FORMATS=(appimage deb rpm flatpak)

IS_LINUX=0
[ "$(uname -s)" = "Linux" ] && IS_LINUX=1

# ----------------------------------------------------------------- version ---
if [ -z "${VERSION}" ]; then
    if git describe --tags --match 'v[0-9]*' >/dev/null 2>&1; then
        # v1.2.3-4-gabc123 → 1.2.3-4-gabc123 (valid Debian upstream version).
        VERSION="$(git describe --tags --match 'v[0-9]*' | sed 's/^v//')"
    elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        VERSION="0.1.0+git.$(git rev-parse --short=7 HEAD)"
    else
        VERSION="0.1.0"
    fi
fi
case "${VERSION}" in [0-9]*) ;; *) die "version '${VERSION}' must start with a digit (deb/rpm requirement)" ;; esac
RPM_VERSION="$(printf '%s' "${VERSION}" | tr '-' '.')"   # rpm Version: no '-'
PKG_NAME="klaxon-${APP_NAME}"
# org.klaxon.<App> — bash 3.2-safe capitalization (no ${var^}, no GNU sed \u).
APP_TITLE="$(printf '%s' "${APP_NAME}" | cut -c1 | tr '[:lower:]' '[:upper:]')$(printf '%s' "${APP_NAME}" | cut -c2-)"
APP_ID="org.klaxon.${APP_TITLE}"
DESKTOP_NAME="${PKG_NAME}.desktop"
# Per-format staging root; set (absolute) in main after the dry-run exit.
STAGE_BASE=""

# ------------------------------------------------------------------- tools ---
APPIMAGETOOL=""
find_appimagetool() {
    if command -v appimagetool >/dev/null 2>&1; then
        APPIMAGETOOL="appimagetool"; return 0
    fi
    local cached="deps/tools/appimagetool-${AI_ARCH}.AppImage"
    if [ -x "${cached}" ]; then APPIMAGETOOL="${cached}"; return 0; fi
    [ "${DRY_RUN}" = 1 ] && return 1
    log "appimagetool not found — downloading ${AI_ARCH} build to ${cached}"
    mkdir -p deps/tools
    local url="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${AI_ARCH}.AppImage"
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --retry 3 -o "${cached}" "${url}" || die "appimagetool download failed (${url})"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "${cached}" "${url}" || die "appimagetool download failed (${url})"
    else
        die "need curl or wget to fetch appimagetool (or: apt install appimagetool / put it in PATH)"
    fi
    chmod +x "${cached}"
    APPIMAGETOOL="${cached}"
}

wants() { local f; for f in ${FORMATS[@]+"${FORMATS[@]}"}; do [ "$f" = "$1" ] && return 0; done; return 1; }

preflight() {
    wants deb      && need_tool dpkg-deb dpkg dpkg
    wants rpm      && need_tool rpmbuild rpm rpm
    wants appimage && { command -v linuxdeploy >/dev/null 2>&1 || command -v appimagetool >/dev/null 2>&1 || \
        log "appimagetool absent — will download to deps/tools/ when the appimage step runs"; }
    # flatpak-builder is optional — the manifest is always a deliverable.
    return 0
}

# ------------------------------------------------------------- payload bits --
ICON_SRC=""
find_icon() {
    local c
    for c in assets/klaxon.png assets/icon.png assets/logo.png web/icon.png \
             android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png; do
        [ -f "$c" ] && { ICON_SRC="$c"; return 0; }
    done
    return 1
}

# write_desktop_file <path> — generates the freedesktop entry.
write_desktop_file() {
    {
        echo "[Desktop Entry]"
        echo "Type=Application"
        echo "Name=Klaxon ${APP_TITLE}"
        echo "GenericName=Klaxon demo"
        echo "Comment=Klaxon UI framework demo (${APP_NAME})"
        echo "Exec=${APP_NAME}"
        echo "Terminal=false"
        echo "Categories=Development;Graphics;"
        [ -n "${ICON_SRC}" ] && echo "Icon=klaxon"
    } > "$1"
}

# CORE_LIBS — glibc/rtld basenames we never bundle (they must match the host).
CORE_LIB_RE='^(linux-vdso|ld-linux|ld-musl|ld64|libc\.so|libm\.so|libmvec\.so|libdl\.so|libpthread\.so|librt\.so|libutil\.so|libresolv|libnsl|libnss|libgcc_s|libc\+\+|libstdc\+\+)'

# collect_runtime_libs <destdir> — `ldd` the binary, copy non-core .so's.
# Linux only; empty result is expected (Klaxon is statically linked).
collect_runtime_libs() {
    local dest="$1"
    [ "${IS_LINUX}" = 1 ] || return 0
    command -v ldd >/dev/null 2>&1 || { warn "ldd not found — skipping shared-lib bundling"; return 0; }
    mkdir -p "${dest}"
    local lib base
    # ldd exits non-zero on fully-static binaries — harmless, bundle nothing.
    { ldd "zig-out/bin/${APP_NAME}" 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^\/.*\.so/) print $i }' \
        | while IFS= read -r lib; do
            base="$(basename "${lib}")"
            echo "${base}" | grep -Eq "${CORE_LIB_RE}" && continue
            cp -L "${lib}" "${dest}/${base}"
            echo "    bundled non-core lib: ${base}"
        done; } || true
    rmdir "${dest}" 2>/dev/null || true   # drop the dir when nothing was bundled
    return 0
}

# install_payload <fsroot> — usr/bin + usr/share/{applications,pixmaps} +
# usr/lib/<pkg> layout shared by the .deb and .rpm payload trees.
# When non-core shared libs exist they go to /usr/lib/<pkg>/ and the real
# binary sits next to them, behind a small LD_LIBRARY_PATH wrapper in /usr/bin
# (the normal case is zero bundled libs → the binary goes straight to bin/).
install_payload() {
    local root="$1"
    local libdest="${root}/usr/lib/${PKG_NAME}"
    mkdir -p "${root}/usr/bin" "${root}/usr/share/applications"
    collect_runtime_libs "${libdest}"
    if [ -d "${libdest}" ] && [ -n "$(ls -A "${libdest}" 2>/dev/null)" ]; then
        mkdir -p "${libdest}/bin"
        cp "zig-out/bin/${APP_NAME}" "${libdest}/bin/${APP_NAME}"
        cat > "${root}/usr/bin/${APP_NAME}" <<EOF
#!/bin/sh
LD_LIBRARY_PATH="/usr/lib/${PKG_NAME}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" exec "/usr/lib/${PKG_NAME}/bin/${APP_NAME}" "\$@"
EOF
        chmod 755 "${root}/usr/bin/${APP_NAME}"
    else
        cp "zig-out/bin/${APP_NAME}" "${root}/usr/bin/${APP_NAME}"
        chmod 755 "${root}/usr/bin/${APP_NAME}"
        rmdir "${root}/usr/lib" 2>/dev/null || true   # no libs → no empty usr/lib
    fi
    write_desktop_file "${root}/usr/share/applications/${DESKTOP_NAME}"
    if [ -n "${ICON_SRC}" ]; then
        mkdir -p "${root}/usr/share/pixmaps"
        cp "${ICON_SRC}" "${root}/usr/share/pixmaps/klaxon.png"
    fi
}

# ------------------------------------------------------------------ formats -
ARTIFACTS=()
note_artifact() { ARTIFACTS+=("$1"); log "produced: $1"; }

build_deb() {
    need_tool dpkg-deb dpkg dpkg
    local stage="${STAGE_BASE}/deb"
    local root="${stage}/root"
    rm -rf "${stage}"
    mkdir -p "${root}/DEBIAN"
    install_payload "${root}"

    local inst_size
    inst_size=$(du -sk "${root}" | cut -f1)
    cat > "${root}/DEBIAN/control" <<EOF
Package: ${PKG_NAME}
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${DEB_ARCH}
Maintainer: Klaxon developers <noreply@klaxon.dev>
Installed-Size: ${inst_size}
Depends: libc6
Recommends: libx11-6 | libwayland-client0
Description: Klaxon ${APP_NAME} demo application
 Klaxon is a cross-platform UI framework written in Zig. This package
 contains the '${APP_NAME}' demo app (statically linked; the display
 stack is loaded at runtime — see Recommends).
EOF

    local deb="${OUTPUT_DIR}/${PKG_NAME}_${VERSION}_${DEB_ARCH}.deb"
    rm -f "${deb}"
    dpkg-deb --build --root-owner-group "${root}" "${deb}"
    note_artifact "${deb}"
}

build_rpm() {
    need_tool rpmbuild rpm rpm
    local stage="${STAGE_BASE}/rpm"
    local payload="${stage}/payload"
    rm -rf "${stage}"
    mkdir -p "${payload}" "${stage}/rpmbuild"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
    install_payload "${payload}"

    # %files manifest from the staged tree (paths as seen inside buildroot).
    # Files/links + %dir for dirs only we own (usr/lib/<pkg>) — system dirs
    # stay owned by the filesystem package.
    (cd "${payload}" && {
        find . -mindepth 1 \( -type f -o -type l \) | sed 's|^\.||'
        { find "./usr/lib/${PKG_NAME}" -type d 2>/dev/null || true; } | sed 's|^\.|%dir |'
    } | sort -u) > "${stage}/files.list"

    local spec="${stage}/rpmbuild/SPECS/${PKG_NAME}.spec"
    cat > "${spec}" <<EOF
%global debug_package %{nil}
%global _missing_build_ids_terminate_build 0
Name:           ${PKG_NAME}
Version:        ${RPM_VERSION}
Release:        1%{?dist}
Summary:        Klaxon ${APP_NAME} demo application
License:        Apache-2.0
URL:            https://github.com/Vehicoule/Klaxon
Requires:       glibc

%description
Klaxon is a cross-platform UI framework written in Zig. This package
contains the '${APP_NAME}' demo app (statically linked; the X11/Wayland
client libraries are dlopen'd at runtime and must come from the system).

%install
mkdir -p %{buildroot}
cp -a %{klaxon_payload}/. %{buildroot}/

%files -f %{klaxon_files}
%defattr(-,root,root,-)
EOF

    local topdir="${stage}/rpmbuild"
    rpmbuild -bb --target "${RPM_ARCH}" \
        --define "_topdir ${topdir}" \
        --define "_rpmdir ${OUTPUT_DIR}" \
        --define "klaxon_payload ${payload}" \
        --define "klaxon_files ${stage}/files.list" \
        "${spec}"
    # _rpmdir gains an arch subdir (<out>/<arch>/name.rpm) — flatten into dist/.
    local rpm
    rpm=$(find "${OUTPUT_DIR}" -name "${PKG_NAME}-${RPM_VERSION}-1.${RPM_ARCH}.rpm" | head -1)
    [ -n "${rpm}" ] || die "rpmbuild produced no ${PKG_NAME}-${RPM_VERSION}-1.${RPM_ARCH}.rpm under ${OUTPUT_DIR}"
    if [ "${rpm}" != "${OUTPUT_DIR}/$(basename "${rpm}")" ]; then
        mv "${rpm}" "${OUTPUT_DIR}/$(basename "${rpm}")"
        rpm="${OUTPUT_DIR}/$(basename "${rpm}")"
        rmdir "${OUTPUT_DIR}/${RPM_ARCH}" 2>/dev/null || true
    fi
    note_artifact "${rpm}"
}

build_appimage() {
    local stage="${STAGE_BASE}/appimage"
    local appdir="${stage}/AppDir"
    rm -rf "${stage}"
    mkdir -p "${appdir}/usr/bin" "${appdir}/usr/lib"

    if command -v linuxdeploy >/dev/null 2>&1; then
        # Preferred: linuxdeploy fills the AppDir (deps, desktop, icon).
        # The icon must be named klaxon.png — linuxdeploy checks it against
        # the desktop entry's Icon=klaxon.
        local dsk="${stage}/${DESKTOP_NAME}"
        write_desktop_file "${dsk}"
        local args=(--appdir "${appdir}" --executable "zig-out/bin/${APP_NAME}" --desktop-file "${dsk}")
        if [ -n "${ICON_SRC}" ]; then
            cp "${ICON_SRC}" "${stage}/klaxon.png"
            args+=(--icon-file "${stage}/klaxon.png")
        fi
        linuxdeploy "${args[@]}"
    else
        # Portable route: hand-laid AppDir (binary + libs + desktop + icon).
        cp "zig-out/bin/${APP_NAME}" "${appdir}/usr/bin/${APP_NAME}"
        collect_runtime_libs "${appdir}/usr/lib"
        local dsk="${stage}/${DESKTOP_NAME}"
        write_desktop_file "${dsk}"
        cp "${dsk}" "${appdir}/${DESKTOP_NAME}"
        mkdir -p "${appdir}/usr/share/applications"
        cp "${dsk}" "${appdir}/usr/share/applications/${DESKTOP_NAME}"
        if [ -n "${ICON_SRC}" ]; then
            cp "${ICON_SRC}" "${appdir}/klaxon.png"
        fi
        cat > "${appdir}/AppRun" <<EOF
#!/bin/sh
HERE="\$(dirname "\$(readlink -f "\$0")")"
export LD_LIBRARY_PATH="\${HERE}/usr/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\${HERE}/usr/bin/${APP_NAME}" "\$@"
EOF
        chmod +x "${appdir}/AppRun"
    fi

    find_appimagetool
    local out="${OUTPUT_DIR}/Klaxon-${APP_NAME}-${VERSION}-linux-${ARCH}.AppImage"
    rm -f "${out}"
    # APPIMAGE_EXTRACT_AND_RUN lets the tool run without FUSE (CI/containers).
    APPIMAGE_EXTRACT_AND_RUN=1 ARCH="${AI_ARCH}" "${APPIMAGETOOL}" "${appdir}" "${out}"
    note_artifact "${out}"
}

build_flatpak() {
    local stage="${STAGE_BASE}/flatpak"
    local srcdir="${stage}/src"
    rm -rf "${stage}"
    mkdir -p "${srcdir}"
    cp "zig-out/bin/${APP_NAME}" "${srcdir}/${APP_NAME}"
    write_desktop_file "${srcdir}/${DESKTOP_NAME}"
    [ -n "${ICON_SRC}" ] && cp "${ICON_SRC}" "${srcdir}/klaxon.png"
    collect_runtime_libs "${srcdir}/libs"

    local manifest="${stage}/${APP_ID}.yml"
    {
        echo "app-id: ${APP_ID}"
        echo "runtime: org.freedesktop.Platform"
        echo "runtime-version: '24.08'"
        echo "sdk: org.freedesktop.Sdk"
        echo "command: ${APP_NAME}"
        echo "finish-args:"
        echo "  - --share=ipc"
        echo "  - --socket=wayland"
        echo "  - --socket=fallback-x11"
        echo "  - --device=dri"
        if [ -d "${srcdir}/libs" ] && [ -n "$(ls -A "${srcdir}/libs" 2>/dev/null)" ]; then
            echo "  - --env=LD_LIBRARY_PATH=/app/lib"
        fi
        echo "modules:"
        echo "  - name: ${PKG_NAME}"
        echo "    buildsystem: simple"
        echo "    build-commands:"
        echo "      - install -Dm755 ${APP_NAME} /app/bin/${APP_NAME}"
        echo "      - install -Dm644 ${DESKTOP_NAME} /app/share/applications/${DESKTOP_NAME}"
        [ -n "${ICON_SRC}" ] && \
            echo "      - install -Dm644 klaxon.png /app/share/icons/hicolor/192x192/apps/klaxon.png"
        if [ -d "${srcdir}/libs" ] && [ -n "$(ls -A "${srcdir}/libs" 2>/dev/null)" ]; then
            echo "      - 'mkdir -p /app/lib && cp libs/*.so* /app/lib/'"
        fi
        echo "    sources:"
        echo "      - type: dir"
        # Absolute path → the manifest in dist/ stays usable as long as the
        # staging tree (dist/.stage/) exists; it is regenerated every run.
        echo "        path: ${srcdir}"
    } > "${manifest}"

    cp "${manifest}" "${OUTPUT_DIR}/${APP_ID}.yml"
    note_artifact "${OUTPUT_DIR}/${APP_ID}.yml"

    if ! command -v flatpak-builder >/dev/null 2>&1; then
        warn "flatpak-builder not found (apt install flatpak-builder) — manifest emitted, bundle skipped"
        return 0
    fi
    (cd "${stage}" && flatpak-builder --force-clean --arch="${FLATPAK_ARCH}" \
        --repo=repo build "${APP_ID}.yml")

    if command -v flatpak >/dev/null 2>&1; then
        local out="${OUTPUT_DIR}/Klaxon-${APP_NAME}-${VERSION}-linux-${ARCH}.flatpak"
        rm -f "${out}"
        (cd "${stage}" && flatpak build-bundle repo "${out}" "${APP_ID}")
        note_artifact "${out}"
    else
        warn "flatpak(1) not found (apt install flatpak) — ostree repo at ${stage}/repo, no .flatpak bundle"
    fi
}

# -------------------------------------------------------------------- plan --
dry_run() {
    cat <<EOF
==> package-linux dry-run
  app:       ${APP_NAME}        (zig-out/bin/${APP_NAME})
  arch:      ${ARCH}            (zig target ${ZIG_TARGET})
  version:   ${VERSION}
  output:    ${OUTPUT_DIR}
  formats:   ${FORMATS[*]}
  icon:      ${ICON_SRC:-none found — Icon= lines/pixmaps skipped}
  tools:
    dpkg-deb        $(command -v dpkg-deb        || echo 'MISSING — apt install dpkg / brew install dpkg')
    rpmbuild        $(command -v rpmbuild        || echo 'MISSING — apt install rpm / brew install rpm')
    linuxdeploy     $(command -v linuxdeploy     || echo 'absent — portable AppDir route')
    appimagetool    $(command -v appimagetool    || { [ -x "deps/tools/appimagetool-${AI_ARCH}.AppImage" ] && echo "deps/tools/appimagetool-${AI_ARCH}.AppImage" || echo "will download → deps/tools/appimagetool-${AI_ARCH}.AppImage"; })
    flatpak-builder $(command -v flatpak-builder || echo 'absent — manifest still emitted, bundle skipped')
EOF
    wants appimage && echo "  would produce: ${OUTPUT_DIR}/Klaxon-${APP_NAME}-${VERSION}-linux-${ARCH}.AppImage"
    wants deb      && echo "  would produce: ${OUTPUT_DIR}/${PKG_NAME}_${VERSION}_${DEB_ARCH}.deb"
    wants rpm      && echo "  would produce: ${OUTPUT_DIR}/${PKG_NAME}-${RPM_VERSION}-1.${RPM_ARCH}.rpm"
    wants flatpak  && echo "  would produce: ${OUTPUT_DIR}/${APP_ID}.yml (+ .flatpak bundle if flatpak-builder+flatpak present)"
}

# -------------------------------------------------------------------- main ---
# KLAXON_PACKAGE_LINUX_LIB=1 → source the functions only (lets tests exercise
# build_deb/build_rpm/... off-Linux with stub tools on PATH).
if [ "${KLAXON_PACKAGE_LINUX_LIB:-0}" != "1" ]; then
    find_icon || true

    if [ "${DRY_RUN}" = 1 ]; then
        dry_run
        exit 0
    fi

    [ "${IS_LINUX}" = 1 ] || die "packaging must run on Linux (dpkg/rpm/appimagetool/flatpak-builder). Use --dry-run to preview on this host."

    # Resolve output dir to an absolute path — flatpak-builder / rpmbuild get
    # called from staging dirs, so every emitted path must be absolute.
    mkdir -p "${OUTPUT_DIR}"
    OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"
    STAGE_BASE="${OUTPUT_DIR}/.stage/${PKG_NAME}-${ARCH}"

    preflight

    if [ "${DO_BUILD}" = 1 ]; then
        log "zig build -Dtarget=${ZIG_TARGET} -Doptimize=ReleaseSmall"
        [ -d "deps/skia/out/linux-${ARCH}" ] || \
            warn "deps/skia/out/linux-${ARCH} missing — run: scripts/fetch-deps.sh linux-${ARCH}"
        zig build -Dtarget="${ZIG_TARGET}" -Doptimize=ReleaseSmall
    else
        log "--no-build: reusing zig-out/bin/${APP_NAME}"
    fi

    EXE_SRC="zig-out/bin/${APP_NAME}"
    [ -f "${EXE_SRC}" ] || die "executable not found at ${EXE_SRC}"
    log "executable: ${EXE_SRC} ($(du -h "${EXE_SRC}" | cut -f1))"
    [ -n "${ICON_SRC}" ] && log "icon: ${ICON_SRC}" || warn "no icon asset found — packages ship without an icon"

    wants deb      && build_deb
    wants rpm      && build_rpm
    wants appimage && build_appimage
    wants flatpak  && build_flatpak

    echo ""
    log "Done — ${APP_NAME} linux-${ARCH}:"
    for a in ${ARTIFACTS[@]+"${ARTIFACTS[@]}"}; do
        echo "    ${a}"
    done
fi
