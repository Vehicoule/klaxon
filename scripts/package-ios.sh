#!/usr/bin/env bash
# package-ios.sh — build + package the Klaxon gallery as an iOS .app / .ipa (Phase 3e).
#
# Usage:
#   scripts/package-ios.sh [sim|device] [--ipa] [--backend <name>]
#
#   sim     Build for iOS simulator (default). Produces zig-out/ios/Gallery.app
#           (unsigned — `xcrun simctl install` takes it as-is; gates/device.sh
#           relies on this path).
#   device  Build for iOS device. Produces zig-out/ios/Gallery.app, signed with
#           $KX_IOS_SIGN_IDENTITY (default "-" = ad-hoc).
#   --ipa   Also produce a .ipa → dist/Klaxon-Gallery-ios-<sim|device>.ipa
#           (Payload/<App>.app zip — the real .ipa layout sideload tools expect).
#   --backend  Rendering backend: graphite-metal (default) | ganesh-gles | raster.
#
# Signing (honest status):
#   - sim     No signature needed. The .ipa is an artifact container only —
#             simulators install .app bundles, not .ipas.
#   - device  Ad-hoc (`codesign -s -`) .ipas are NOT installable on hardware.
#             For a development-installable .ipa set:
#               KX_IOS_SIGN_IDENTITY="Apple Development: <name> (<team>)"
#               KX_IOS_PROVISION=/path/to/<app>.mobileprovision   (embedded as
#               Payload/<App>.app/embedded.mobileprovision)
#             TestFlight/App Store distribution additionally requires an
#             iOS Distribution certificate + App Store profile and an
#             xcodebuild -exportArchive flow — this repo has no .xcodeproj, so
#             the Payload-zip .ipa is the development/sideload path.
#
# Requirements:
#   - macOS with Xcode (xcrun, iPhoneSimulator/iPhoneOS SDKs)
#   - Zig 0.17 (brew install zig)
#   - deps built: scripts/fetch-deps.sh ios
set -euo pipefail
cd "$(dirname "$0")/.."

command -v zig >/dev/null 2>&1 || { echo "Error: zig not found — install Zig 0.17 (brew install zig)"; exit 1; }
command -v xcrun >/dev/null 2>&1 || { echo "Error: xcrun not found — install Xcode (xcode-select --install / Xcode.app)"; exit 1; }

TARGET="sim"
IPA=0
BACKEND_FLAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        sim|device) TARGET="$1" ;;
        --ipa) IPA=1 ;;
        --backend) BACKEND_FLAG="-Dios-backend=${2:?--backend requires a value}"; shift ;;
        --backend=*) BACKEND_FLAG="-Dios-backend=${1#--backend=}" ;;
        -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1"; echo "Usage: scripts/package-ios.sh [sim|device] [--ipa] [--backend <name>]"; exit 1 ;;
    esac
    shift
done

ZIG="${ZIG:-zig}"
APP_NAME="Gallery"
OUT_DIR="zig-out/ios"
DIST_DIR="dist"
APP_DIR="$OUT_DIR/$APP_NAME.app"
SIGN_IDENTITY="${KX_IOS_SIGN_IDENTITY:--}"

echo "==> Building iOS gallery ($TARGET${BACKEND_FLAG:+ $BACKEND_FLAG})"
if [ "$TARGET" = "sim" ]; then
    $ZIG build -Dtarget=aarch64-ios.15.0-simulator -Doptimize=ReleaseSmall $BACKEND_FLAG ios-gallery
else
    $ZIG build -Dtarget=aarch64-ios.15.0 -Doptimize=ReleaseSmall $BACKEND_FLAG ios-gallery
fi

echo "==> Packaging $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
cp "$OUT_DIR/gallery" "$APP_DIR/$APP_NAME"
cp assets/Info-ios.plist "$APP_DIR/Info.plist"

# Optional provisioning profile → embedded.mobileprovision (device installs).
if [ -n "${KX_IOS_PROVISION:-}" ]; then
    if [ ! -f "$KX_IOS_PROVISION" ]; then
        echo "Error: KX_IOS_PROVISION set but file not found: $KX_IOS_PROVISION"; exit 1
    fi
    cp "$KX_IOS_PROVISION" "$APP_DIR/embedded.mobileprovision"
    echo "    embedded.mobileprovision <- $KX_IOS_PROVISION"
fi

if [ "$TARGET" = "device" ]; then
    command -v codesign >/dev/null 2>&1 || { echo "Error: codesign not found — install Xcode (xcode-select --install / Xcode.app)"; exit 1; }
    echo "==> Signing (identity: $SIGN_IDENTITY)"
    codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR"
fi

if [ "$IPA" = "1" ]; then
    command -v zip >/dev/null 2>&1 || { echo "Error: zip not found — install Info-ZIP (brew install zip)"; exit 1; }
    echo "==> Creating .ipa (Payload/ layout)"
    IPA_NAME="Klaxon-Gallery-ios-${TARGET}.ipa"
    IPA_PATH="$DIST_DIR/$IPA_NAME"
    STAGE="$OUT_DIR/.ipa-stage"
    mkdir -p "$DIST_DIR"
    rm -rf "$STAGE" "$IPA_PATH"
    mkdir -p "$STAGE/Payload"
    cp -R "$APP_DIR" "$STAGE/Payload/$APP_NAME.app"
    # zip -X: strip extra file attributes; Payload/ must be the zip root.
    IPA_ABS="$PWD/$IPA_PATH"
    (cd "$STAGE" && zip -Xrq "$IPA_ABS" Payload)
    rm -rf "$STAGE"
    # Keep a copy next to the .app for local tooling that expects it there.
    cp "$IPA_PATH" "$OUT_DIR/$APP_NAME.ipa"
    echo "    -> $IPA_PATH"
    echo "    -> $OUT_DIR/$APP_NAME.ipa"
fi

echo "==> Done: $APP_DIR"
if [ "$TARGET" = "sim" ]; then
    echo "    Install: xcrun simctl install booted $APP_DIR"
elif [ "$SIGN_IDENTITY" = "-" ]; then
    echo "    NOTE: ad-hoc signed — NOT installable on hardware. For a development"
    echo "    .ipa set KX_IOS_SIGN_IDENTITY + KX_IOS_PROVISION (see header comment)."
else
    echo "    Install: Xcode Devices window / Apple Configurator 2, or sideload the .ipa."
fi
