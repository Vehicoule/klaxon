#!/usr/bin/env bash
# package-ios.sh — build + package the Klaxon gallery as an iOS .app (Phase 3e).
#
# Usage:
#   scripts/package-ios.sh [sim|device] [--ipa]
#
#   sim     Build for iOS simulator (default). Produces zig-out/ios/Gallery.app.
#   device  Build for iOS device. Produces zig-out/ios/Gallery.app (ad-hoc signed).
#   --ipa   Also produce a .ipa (zip of the .app) for device installs.
#
# Requirements:
#   - macOS with Xcode (xcrun, iPhoneSimulator/iPhoneOS SDKs)
#   - Zig 0.17
#   - deps built: scripts/fetch-deps.sh ios
#   - For device: a valid signing identity (codesign)
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-sim}"
IPA=0
for arg in "$@"; do
    [ "$arg" = "--ipa" ] && IPA=1
done

ZIG="${ZIG:-zig}"
APP_NAME="Gallery"
BUNDLE_ID="com.klaxon.gallery"
OUT_DIR="zig-out/ios"
APP_DIR="$OUT_DIR/$APP_NAME.app"

echo "==> Building iOS gallery ($TARGET)"
if [ "$TARGET" = "sim" ]; then
    $ZIG build -Dtarget=aarch64-ios.15.0-simulator -Doptimize=ReleaseSmall ios-gallery
else
    $ZIG build -Dtarget=aarch64-ios.15.0 -Doptimize=ReleaseSmall ios-gallery
fi

echo "==> Packaging $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
cp "$OUT_DIR/gallery" "$APP_DIR/$APP_NAME"
cp assets/Info-ios.plist "$APP_DIR/Info.plist"

if [ "$TARGET" = "device" ]; then
    echo "==> Ad-hoc signing"
    codesign --force --sign - "$APP_DIR"
fi

if [ "$IPA" = "1" ]; then
    echo "==> Creating .ipa"
    IPA_PATH="$OUT_DIR/$APP_NAME.ipa"
    rm -f "$IPA_PATH"
    cd "$OUT_DIR"
    zip -rq "$APP_NAME.ipa" "$APP_NAME.app"
    cd - > /dev/null
    echo "    -> $IPA_PATH"
fi

echo "==> Done: $APP_DIR"
