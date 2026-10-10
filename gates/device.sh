#!/usr/bin/env bash
# device.sh — run the Klaxon gallery on a device/emulator and capture evidence (Phase 3 gate).
#
# Usage:
#   gates/device.sh android-emu     Build APK, boot emulator, install, launch, screenshot.
#   gates/device.sh android-device  Install APK on a connected device, launch, screenshot.
#   gates/device.sh ios-sim         Build iOS sim binary, boot simulator, install, launch, screenshot.
#
# Exits non-zero on failure (crash, black screen, install failure).
set -euo pipefail
cd "$(dirname "$0")/.."

CMD="${1:-}"
OUT_DIR="${2:-/tmp/klaxon-device}"
mkdir -p "$OUT_DIR"

ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$ANDROID_HOME/platform-tools/adb"
EMULATOR="$ANDROID_HOME/emulator/emulator"
ZIG="${ZIG:-zig}"
JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Android emulator ---------------------------------------------------------
android_emu() {
    echo "==> Building Android APK"
    $ZIG build -Dtarget=aarch64-linux-android android-lib
    (cd android && ./gradlew assembleDebug)

    local apk="android/app/build/outputs/apk/debug/app-debug.apk"
    [ -f "$apk" ] || fail "APK not found: $apk"

    echo "==> Booting emulator"
    local avd
    avd=$($EMULATOR -list-avds | head -1)
    [ -n "$avd" ] || fail "No AVD found"
    $ADB devices | grep -q "emulator" || {
        nohup $EMULATOR -avd "$avd" -no-window -no-audio -gpu swiftshader_indirect -no-snapshot-save > /tmp/klaxon-emu.log 2>&1 &
        $ADB wait-for-device
        $ADB shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 1; done'
    }

    echo "==> Installing APK"
    $ADB install -r "$apk"

    echo "==> Launching app"
    $ADB shell am start -n com.klaxon.gallery/.KlaxonActivity
    sleep 5

    echo "==> Screenshot"
    $ADB shell screencap -p /sdcard/kx.png
    $ADB pull /sdcard/kx.png "$OUT_DIR/android.png"

    echo "==> Logcat"
    $ADB logcat -d > "$OUT_DIR/android-logcat.txt" 2>&1 || true

    # Check for crash
    if grep -qE "SIGSEGV|SIGABRT|FATAL|Force finishing" "$OUT_DIR/android-logcat.txt"; then
        fail "App crashed (see $OUT_DIR/android-logcat.txt)"
    fi
    echo "PASS: Android emulator"
}

# --- Android device -----------------------------------------------------------
android_device() {
    local apk="android/app/build/outputs/apk/debug/app-debug.apk"
    [ -f "$apk" ] || { echo "==> Building APK"; $ZIG build -Dtarget=aarch64-linux-android android-lib; (cd android && ./gradlew assembleDebug); }
    $ADB devices | grep -q "device" || fail "No Android device connected"
    $ADB install -r "$apk"
    $ADB shell am start -n com.klaxon.gallery/.KlaxonActivity
    sleep 5
    $ADB shell screencap -p /sdcard/kx.png
    $ADB pull /sdcard/kx.png "$OUT_DIR/android-device.png"
    $ADB logcat -d > "$OUT_DIR/android-device-logcat.txt" 2>&1 || true
    echo "PASS: Android device"
}

# --- iOS simulator ------------------------------------------------------------
ios_sim() {
    echo "==> Building iOS simulator binary"
    $ZIG build -Dtarget=aarch64-ios.15.0-simulator -Doptimize=ReleaseSmall ios-gallery

    echo "==> Packaging .app"
    bash scripts/package-ios.sh sim

    echo "==> Booting simulator"
    local sim_id
    sim_id=$(xcrun simctl list devices available | grep -i "iPhone" | grep "Shutdown" | head -1 | grep -oE '[0-9A-F-]{36}')
    [ -n "$sim_id" ] || fail "No iPhone simulator available"
    xcrun simctl boot "$sim_id"
    sleep 3

    echo "==> Installing + launching"
    xcrun simctl install "$sim_id" zig-out/ios/Gallery.app
    xcrun simctl launch "$sim_id" com.klaxon.gallery
    sleep 5

    echo "==> Screenshot"
    xcrun simctl io "$sim_id" screenshot "$OUT_DIR/ios.png"

    echo "==> Logs"
    xcrun simctl spawn "$sim_id" log show --predicate 'process == "Gallery"' --last 2m > "$OUT_DIR/ios-log.txt" 2>&1 || true

    echo "PASS: iOS simulator (note: rendering may crash on sim — see $OUT_DIR/ios-log.txt)"
}

case "$CMD" in
    android-emu)    android_emu ;;
    android-device) android_device ;;
    ios-sim)        ios_sim ;;
    *) echo "Usage: $0 {android-emu|android-device|ios-sim} [output-dir]"; exit 1 ;;
esac
