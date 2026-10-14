#!/usr/bin/env bash
# bench-ios-sim.sh — build, install and run the 33-scene tier-2 bench on an
# iOS simulator, then pull the JSON report into bench/results/.
#
# Usage: scripts/bench-ios-sim.sh [--backend <name>] [--frames N]
#                                 [--only <scene>] [--skip <a,b,...>]
#                                 [--timeout <secs>] [--keep-app]
#
#   --backend  auto (default) | graphite-metal | raster | ganesh-gles |
#              ganesh-metal — passed to the app as a launch arg; the report
#              lands in bench/results/tier2-ios-<short-backend>/klaxon/
#              (graphite-metal → metal, ganesh-gles → gles — same naming as
#              tier2-macos-metal / tier2-android-gles).
#   --frames   measured frames per scene (default 600 = zig build bench
#              -Dbench-frames default; list_ops/ramp keep their own counts).
#   --only / --skip   scene filters (crash isolation without a rebuild).
#   --timeout  suite wall-clock budget (default 900 s).
#   --keep-app leave the app running after the report lands (default:
#              terminate it; the .app stays installed for re-runs).
#
# iOS has no `adb setprop` channel, so the suite is a SEPARATE .app:
# bench/runners/ios/bench_ios_main.zig exports the four SDL main callbacks
# (the same surface platform_ios.zig ships for the gallery — anchored by
# kx_skia/src/kx_ios_sdl_main.c) and drives bench.zig's catalogue one scene
# per SDL_AppIterate. Build flow (outside build.zig, so a bare zig CLI):
#
#   zig build -Dtarget=aarch64-ios.15.0-simulator ios-gallery
#     → libkx_skia_ios.a + the iOS deps graph (only needed for the shim lib)
#   zig translate-c src/sdl_c.h + kx_skia/include/kx_skia.h
#     → zig-out/ios-bench/gen/{sdl_c,kx_c}.zig  (same as b.addTranslateC)
#   zig build-lib bench_ios_main.zig → zig-out/ios-bench/libkx_ios_bench.a
#   xcrun clang++ <same link recipe as build.zig's ios-gallery step>
#     → zig-out/ios-bench/Bench → packaged as zig-out/ios-bench/Bench.app
#
# The app writes bench.json to SDL_GetPrefPath("klaxon","bench") (= the
# container's Library/Application Support/klaxon/bench/) and exits;
# simctl get_app_container recovers it on the host.
#
# Requirements: Xcode (xcrun), a downloaded iOS sim runtime + device,
# Zig 0.17, deps built (scripts/fetch-deps.sh ios).
set -euo pipefail
cd "$(dirname "$0")/.."

command -v zig >/dev/null 2>&1 || { echo "Error: zig not found — install Zig 0.17 (brew install zig)"; exit 1; }
command -v xcrun >/dev/null 2>&1 || { echo "Error: xcrun not found — install Xcode"; exit 1; }

BACKEND="auto"
FRAMES=600
TIMEOUT=900
ONLY=""
SKIP=""
KEEP_RUNNING=0
while [ $# -gt 0 ]; do
    case "$1" in
        --backend) BACKEND="${2:?--backend requires a value}"; shift ;;
        --backend=*) BACKEND="${1#--backend=}" ;;
        --frames) FRAMES="${2:?--frames requires a value}"; shift ;;
        --frames=*) FRAMES="${1#--frames=}" ;;
        --only) ONLY="${2:?--only requires a value}"; shift ;;
        --only=*) ONLY="${1#--only=}" ;;
        --skip) SKIP="${2:?--skip requires a value}"; shift ;;
        --skip=*) SKIP="${1#--skip=}" ;;
        --timeout) TIMEOUT="${2:?--timeout requires a value}"; shift ;;
        --timeout=*) TIMEOUT="${1#--timeout=}" ;;
        --keep-app) KEEP_RUNNING=1 ;;
        -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
    shift
done

ZIG="${ZIG:-zig}"
OUT_DIR="zig-out/ios-bench"
GEN_DIR="$OUT_DIR/gen"
APP_DIR="$OUT_DIR/Bench.app"
BUNDLE_ID="com.klaxon.bench"

SDK_PATH=$(xcrun --sdk iphonesimulator --show-sdk-path)

# --- 1. the iOS deps graph + libkx_skia_ios.a (the ObjC++ shim archive is
#        produced by build.zig's ios-gallery step — reused as-is).
echo "==> zig build ios-gallery (deps + libkx_skia_ios.a)"
$ZIG build -Dtarget=aarch64-ios.15.0-simulator -Doptimize=ReleaseSmall ios-gallery
[ -f zig-out/lib/libkx_skia_ios.a ] || { echo "Error: zig-out/lib/libkx_skia_ios.a missing"; exit 1; }

# --- 2. translate-c modules for the ios-sim target (same inputs as
#        build.zig's addTranslateC calls).
echo "==> zig translate-c (sdl_c + kx_c)"
mkdir -p "$GEN_DIR"
$ZIG translate-c -target aarch64-ios.15.0-simulator \
    -I deps/SDL/include -I "$SDK_PATH" src/sdl_c.h > "$GEN_DIR/sdl_c.zig"
$ZIG translate-c -target aarch64-ios.15.0-simulator \
    -I kx_skia/include -I "$SDK_PATH" kx_skia/include/kx_skia.h > "$GEN_DIR/kx_c.zig"

# --- 3. the bench app static lib: bench_ios_main.zig as the module root,
#        src/bench.zig as the `bench` module (it re-pulls the rest of src/
#        via relative imports), sdl_c/kx_c as translate-c modules.
echo "==> zig build-lib bench_ios_main.zig"
$ZIG build-lib -target aarch64-ios.15.0-simulator -O small -lc \
    --dep bench --dep sdl_c \
    -Mroot=bench/runners/ios/bench_ios_main.zig \
    --dep sdl_c --dep kx_c \
    -Mbench=src/bench.zig \
    -Msdl_c="$GEN_DIR/sdl_c.zig" \
    -Mkx_c="$GEN_DIR/kx_c.zig" \
    --name kx_ios_bench \
    -femit-bin="$OUT_DIR/libkx_ios_bench.a"

# --- 4. final link — the same xcrun clang++ recipe as build.zig's iOS
#        link step, minus libgallery.a (this lib provides the SDL_App*
#        callbacks instead).
echo "==> xcrun clang++ link → $OUT_DIR/Bench"
SKIA_LIBS="libfreetype2.a libharfbuzz.a libicu.a libpng.a libskcms.a libskia.a libskparagraph.a libskshaper.a libskunicode_core.a libskunicode_icu.a libzlib.a"
SKIA_ARGS=()
for l in $SKIA_LIBS; do SKIA_ARGS+=("deps/skia/out/ios-sim-arm64/$l"); done
xcrun clang++ -isysroot "$SDK_PATH" -std=c++20 -arch arm64 \
    -mios-simulator-version-min=15.0 \
    "$OUT_DIR/libkx_ios_bench.a" \
    zig-out/lib/libkx_skia_ios.a \
    deps/SDL/build-ios-sim-arm64/libSDL3.a \
    "${SKIA_ARGS[@]}" \
    -framework UIKit -framework Foundation -framework CoreGraphics \
    -framework CoreText -framework QuartzCore -framework Metal \
    -framework IOSurface -framework OpenGLES -framework CoreVideo \
    -framework AudioToolbox -framework AVFoundation -framework CoreAudio \
    -framework CoreHaptics -framework GameController \
    -framework UniformTypeIdentifiers -framework CoreBluetooth \
    -o "$OUT_DIR/Bench"

# --- 5. package Bench.app (same shape as scripts/package-ios.sh sim).
echo "==> Packaging $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
cp "$OUT_DIR/Bench" "$APP_DIR/Bench"
cp bench/runners/ios/Info.plist "$APP_DIR/Info.plist"

# --- 6. boot a simulator: reuse a booted iPhone, else boot the first
#        available one (same selection as gates/device.sh).
SIM_ID=$(xcrun simctl list devices available | grep -i "iPhone" | grep "Booted" | head -1 | grep -oE '[0-9A-F-]{36}' || true)
if [ -z "$SIM_ID" ]; then
    SIM_ID=$(xcrun simctl list devices available | grep -i "iPhone" | head -1 | grep -oE '[0-9A-F-]{36}' || true)
    [ -n "$SIM_ID" ] || { echo "Error: no iPhone simulator available (install a runtime: xcodebuild -downloadPlatform iOS)"; exit 1; }
    echo "==> Booting simulator $SIM_ID"
    xcrun simctl boot "$SIM_ID" || true
    sleep 3
fi
echo "==> Simulator: $SIM_ID"

echo "==> Installing $APP_DIR"
xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" 2>/dev/null || true # stale run
xcrun simctl install "$SIM_ID" "$APP_DIR"

# Fresh report path (known upfront — created on launch).
DATA_DIR=$(xcrun simctl get_app_container "$SIM_ID" "$BUNDLE_ID" data)
REPORT="$DATA_DIR/Library/Application Support/klaxon/bench/bench.json"
rm -f "$REPORT"

ARGS=(--backend="$BACKEND" --frames="$FRAMES")
[ -n "$ONLY" ] && ARGS+=("--only=$ONLY")
[ -n "$SKIP" ] && ARGS+=("--skip=$SKIP")
echo "==> Launching $BUNDLE_ID ${ARGS[*]}"
# `simctl launch` returns once the app has launched (it does NOT wait for
# the app to exit) and prints "<bundle>: <pid>" — the pid is a HOST pid
# (sim apps are host processes), so `kill -0` is a reliable liveness check.
# Poll for the report file; if the app exits without writing it, fail with
# the log tail + crash report listing.
LAUNCH_OUT=$(xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" "${ARGS[@]}" 2>&1) || true
echo "$LAUNCH_OUT" | sed 's/^/    /'
APP_PID=$(echo "$LAUNCH_OUT" | grep -oE '[0-9]+[[:space:]]*$' || true)

app_alive() {
    [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null
}

dump_failure_logs() {
    echo "--- app log tail (process Bench):"
    xcrun simctl spawn "$SIM_ID" log show --last 5m \
        --predicate 'process == "Bench"' 2>/dev/null | tail -40 || true
    echo "--- crash reports (sim Diagnostics):"
    ls -t "$HOME/Library/Developer/CoreSimulator/Devices/$SIM_ID/data/Library/Logs/DiagnosticReports/" 2>/dev/null | head -5 || true
}

deadline=$((SECONDS + TIMEOUT))
misses=0
while [ ! -f "$REPORT" ]; do
    if [ -n "$APP_PID" ]; then
        if app_alive; then
            misses=0
        else
            misses=$((misses + 1))
            if [ "$misses" -ge 3 ]; then
                sleep 2 # let the fs settle — the report write races the check
                break
            fi
        fi
    fi
    if [ $SECONDS -ge $deadline ]; then
        echo "Error: suite timed out after ${TIMEOUT}s"
        dump_failure_logs
        xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" || true
        exit 1
    fi
    sleep 2
done

if [ ! -f "$REPORT" ]; then
    echo "Error: app exited without a report at $REPORT (crash?)"
    dump_failure_logs
    exit 1
fi

# --- 7. pull + archive the report under the tier naming the other
#        platforms use (backend field in the JSON is the resolved one).
BACKEND_NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["backend"])' "$REPORT" 2>/dev/null || echo "$BACKEND")
SHORT=$(echo "$BACKEND_NAME" | sed -e 's/graphite-//' -e 's/ganesh-//')
TIER="tier2-ios-$SHORT"
STAMP=$(date +%Y%m%dT%H%M%S)
DEST="bench/results/$TIER/klaxon"
mkdir -p "$DEST"
cp "$REPORT" "$DEST/$TIER-$STAMP.json"
echo "==> Report: $DEST/$TIER-$STAMP.json (backend: $BACKEND_NAME)"

if [ "$KEEP_RUNNING" != "1" ]; then
    xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" 2>/dev/null || true
fi

python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
print("    scenes: %d, backend: %s, binary_size_bytes: %d" % (
    len(d["scenes"]), d["backend"], d["binary_size_bytes"]))
missing = [s["name"] for s in d["scenes"] if s.get("fps") is None]
if missing: print("    WARNING scenes without metrics:", missing)
' "$DEST/$TIER-$STAMP.json"
