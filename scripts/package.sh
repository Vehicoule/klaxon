#!/bin/bash
# package.sh — dispatch to the per-platform packaging script (Phase 5b matrix).
#
# Usage: scripts/package.sh [platform] [args...]
#   platform — macos | ios | android | web | windows | linux (default: host OS)
#   args     — forwarded verbatim to the platform script.
#
#   scripts/package.sh            # package for the host platform
#   scripts/package.sh web        # -> scripts/package-web.sh
#   scripts/package.sh ios device --ipa
#
# This is a thin dispatcher only — each platform script owns its own flags,
# output layout (dist/) and tool checks.
set -euo pipefail
cd "$(dirname "$0")/.."

platform="${1:-}"
if [ -z "$platform" ]; then
    case "$(uname -s)" in
        Darwin)            platform=macos ;;
        Linux)             platform=linux ;;
        MINGW*|MSYS*|CYGWIN*) platform=windows ;;
        *) echo "Error: cannot detect platform from uname=$(uname -s)"; exit 1 ;;
    esac
else
    shift
fi

case "$platform" in
    macos|ios|android|web|windows|linux) ;;
    *) echo "Unknown platform: $platform"
       echo "Valid: macos, ios, android, web, windows, linux"; exit 1 ;;
esac

script="scripts/package-${platform}.sh"
if [ ! -f "$script" ]; then
    echo "Error: $script does not exist yet — $platform packaging is not implemented"
    echo "       (see docs/ROADMAP.md Phase 5b for the packaging matrix status)"
    exit 1
fi
exec bash "$script" "$@"
