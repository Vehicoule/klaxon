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

# Verify that a captured PNG exists, is non-empty, reconstructs scanline filters,
# and has non-black multi-color UI content in the central 60% app viewport
# (ignoring top/bottom OS status and navigation bars).
verify_screenshot() {
    local img="$1"
    [ -s "$img" ] || fail "Screenshot missing or empty: $img"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$img" <<'PY' || fail "Screenshot is solid black or corrupt: $img"
import struct, sys, zlib

with open(sys.argv[1], "rb") as f:
    data = f.read()
if data[:8] != b"\x89PNG\r\n\x1a\n":
    sys.exit(1)
pos = 8
idat = bytearray()
width = height = bit_depth = color_type = interlace = 0
while pos + 8 <= len(data):
    length, ctype = struct.unpack(">I4s", data[pos:pos+8])
    chunk = data[pos+8:pos+8+length]
    pos += 12 + length
    if ctype == b"IHDR":
        width, height, bit_depth, color_type, _, _, interlace = struct.unpack(">IIBBBBB", chunk[:13])
    elif ctype == b"IDAT":
        idat.extend(chunk)
    elif ctype == b"IEND":
        break
raw = zlib.decompress(bytes(idat))
if width <= 0 or height <= 0 or bit_depth != 8 or interlace != 0:
    sys.exit(1)
bpp = {0: 1, 2: 3, 4: 2, 6: 4}.get(color_type, 0)
if bpp == 0:
    sys.exit(1)
row_bytes = width * bpp
stride = 1 + row_bytes
if len(raw) < height * stride:
    sys.exit(1)

def paeth(a, b, c):
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c

prev = bytearray(row_bytes)
cur = bytearray(row_bytes)
y0, y1 = int(height * 0.2), max(int(height * 0.8), int(height * 0.2) + 1)
x0, x1 = int(width * 0.2), max(int(width * 0.8), int(width * 0.2) + 1)
total_px = 0
non_black_px = 0
colors = set()

for y in range(height):
    base = y * stride
    ftype = raw[base]
    scan = raw[base + 1 : base + 1 + row_bytes]
    if ftype == 0:
        cur[:] = scan
    elif ftype == 1:
        for i in range(row_bytes):
            left = cur[i - bpp] if i >= bpp else 0
            cur[i] = (scan[i] + left) & 0xFF
    elif ftype == 2:
        for i in range(row_bytes):
            cur[i] = (scan[i] + prev[i]) & 0xFF
    elif ftype == 3:
        for i in range(row_bytes):
            left = cur[i - bpp] if i >= bpp else 0
            cur[i] = (scan[i] + ((left + prev[i]) >> 1)) & 0xFF
    elif ftype == 4:
        for i in range(row_bytes):
            left = cur[i - bpp] if i >= bpp else 0
            up = prev[i]
            up_left = prev[i - bpp] if i >= bpp else 0
            cur[i] = (scan[i] + paeth(left, up, up_left)) & 0xFF
    else:
        sys.exit(1)
    if y0 <= y < y1:
        for x in range(x0, x1):
            total_px += 1
            off = x * bpp
            if bpp >= 3:
                r, g, b = cur[off], cur[off + 1], cur[off + 2]
            else:
                r = g = b = cur[off]
            if r > 16 or g > 16 or b > 16:
                non_black_px += 1
            if len(colors) < 8:
                colors.add((r >> 4, g >> 4, b >> 4))
    prev[:] = cur

if total_px == 0 or non_black_px * 100 < total_px or len(colors) < 2:
    sys.exit(1)
PY
    fi
}

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

    echo "==> Clearing logcat and launching app"
    $ADB logcat -c || true
    $ADB shell am start -n com.klaxon.gallery/.KlaxonActivity
    sleep 5

    echo "==> Logcat + process liveness"
    $ADB logcat -d > "$OUT_DIR/android-logcat.txt" 2>&1 || true
    if grep -qE "SIGSEGV|SIGABRT|FATAL|Force finishing|ANR in com\.klaxon\.gallery" "$OUT_DIR/android-logcat.txt"; then
        fail "App crashed (see $OUT_DIR/android-logcat.txt)"
    fi
    $ADB shell pidof com.klaxon.gallery >/dev/null 2>&1 || fail "App process com.klaxon.gallery is not running"

    echo "==> Screenshot"
    $ADB shell screencap -p /sdcard/kx.png
    $ADB pull /sdcard/kx.png "$OUT_DIR/android.png"
    verify_screenshot "$OUT_DIR/android.png"

    echo "PASS: Android emulator"
}

# --- Android device -----------------------------------------------------------
android_device() {
    local apk="android/app/build/outputs/apk/debug/app-debug.apk"
    [ -f "$apk" ] || { echo "==> Building APK"; $ZIG build -Dtarget=aarch64-linux-android android-lib; (cd android && ./gradlew assembleDebug); }
    $ADB devices | awk 'NR>1 && $2=="device" {found=1} END {exit !found}' || fail "No Android device connected"
    $ADB install -r "$apk"
    $ADB logcat -c || true
    $ADB shell am start -n com.klaxon.gallery/.KlaxonActivity
    sleep 5
    $ADB logcat -d > "$OUT_DIR/android-device-logcat.txt" 2>&1 || true
    if grep -qE "SIGSEGV|SIGABRT|FATAL|Force finishing|ANR in com\.klaxon\.gallery" "$OUT_DIR/android-device-logcat.txt"; then
        fail "App crashed on device (see $OUT_DIR/android-device-logcat.txt)"
    fi
    $ADB shell pidof com.klaxon.gallery >/dev/null 2>&1 || fail "App process com.klaxon.gallery is not running on device"
    $ADB shell screencap -p /sdcard/kx.png
    $ADB pull /sdcard/kx.png "$OUT_DIR/android-device.png"
    verify_screenshot "$OUT_DIR/android-device.png"
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
    sim_id=$(xcrun simctl list devices available | grep -i "iPhone" | grep "Booted" | head -1 | grep -oE '[0-9A-F-]{36}' || true)
    if [ -z "$sim_id" ]; then
        sim_id=$(xcrun simctl list devices available | grep -i "iPhone" | grep "Shutdown" | head -1 | grep -oE '[0-9A-F-]{36}' || true)
        [ -n "$sim_id" ] || fail "No iPhone simulator available"
        xcrun simctl boot "$sim_id"
        sleep 3
    fi

    echo "==> Installing + launching"
    xcrun simctl install "$sim_id" zig-out/ios/Gallery.app
    xcrun simctl launch "$sim_id" com.klaxon.gallery
    sleep 5

    echo "==> Logs + process liveness"
    xcrun simctl spawn "$sim_id" log show --predicate 'process == "Gallery"' --last 1m > "$OUT_DIR/ios-log.txt" 2>&1 || true
    if grep -qE "SIGSEGV|SIGABRT|EXC_BAD_ACCESS|Fatal error|Terminating app" "$OUT_DIR/ios-log.txt"; then
        fail "App crashed on iOS simulator (see $OUT_DIR/ios-log.txt)"
    fi
    xcrun simctl spawn "$sim_id" launchctl list | grep -q "com.klaxon.gallery" || fail "App com.klaxon.gallery is not running on iOS simulator"

    echo "==> Screenshot"
    xcrun simctl io "$sim_id" screenshot "$OUT_DIR/ios.png"
    verify_screenshot "$OUT_DIR/ios.png"

    echo "PASS: iOS simulator"
}

case "$CMD" in
    android-emu)    android_emu ;;
    android-device) android_device ;;
    ios-sim)        ios_sim ;;
    *) echo "Usage: $0 {android-emu|android-device|ios-sim} [output-dir]"; exit 1 ;;
esac
