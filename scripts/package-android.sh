#!/bin/bash
# package-android.sh — build + package the Klaxon gallery as .apk + .aab (Android arm64).
#
# Usage: scripts/package-android.sh [output-dir]
#   output-dir — where to place the artifacts (default: ./dist)
#
# Produces: <output-dir>/Klaxon-gallery-android-arm64.apk
#           <output-dir>/Klaxon-gallery-android-arm64.aab
#
# Pipeline (Phase 3d.5 / Phase 5b):
#   zig build -Dtarget=aarch64-linux-android android-lib → zig-out/lib/libgallery.a
#   Gradle (AGP 8 + CMake/NDK) links libmain.so (kx_skia shim + Skia + SDL3)
#   and packages: assembleRelease → app-release.apk, bundleRelease → app-release.aab.
#
# Signing: with KX_KEYSTORE (+ KX_KEYSTORE_PASSWORD / KX_KEY_ALIAS /
# KX_KEY_PASSWORD) set, Gradle signs the release artifacts for real;
# otherwise they carry the SDK debug key (installable locally, NOT
# uploadable to the Play Console — Play requires a real upload key).
# See the signingConfigs block in android/app/build.gradle.
#
# Requirements:
#   - JDK 17 (brew install --cask temurin, or actions/setup-java)
#   - Android SDK + NDK: ANDROID_HOME (or android/local.properties sdk.dir),
#     NDK 30.0.16248370 (pinned in app/build.gradle ndkVersion)
#   - Zig 0.17 (brew install zig)
#   - deps built: scripts/fetch-deps.sh android-arm64
set -euo pipefail
cd "$(dirname "$0")/.."

OUTPUT_DIR="${1:-./dist}"
ZIG="${ZIG:-zig}"

command -v "$ZIG" >/dev/null 2>&1 || { echo "Error: zig not found — install Zig 0.17 (brew install zig)"; exit 1; }

# Java: the macOS /usr/bin/java stub passes `command -v` but fails to run —
# actually execute it. JAVA_HOME (e.g. Android Studio's JBR) works too.
JAVA_OK=0
if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    JAVA_OK=1
elif command -v java >/dev/null 2>&1 && java -version >/dev/null 2>&1; then
    JAVA_OK=1
fi
if [ "$JAVA_OK" != "1" ]; then
    echo "Error: no working JDK — install JDK 17+ (brew install --cask temurin)"
    echo "       or point JAVA_HOME at one (Android Studio: /Applications/Android Studio.app/Contents/jbr/Contents/Home)"
    exit 1
fi

# Locate the Android SDK: ANDROID_HOME/ANDROID_SDK_ROOT, or local.properties.
SDK_DIR="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$SDK_DIR" ] && [ -f android/local.properties ]; then
    SDK_DIR=$(sed -n 's/^sdk\.dir=\(.*\)/\1/p' android/local.properties | tr -d '\\\\' | tr -d '\r')
fi
if [ -z "$SDK_DIR" ] || [ ! -d "$SDK_DIR" ]; then
    echo "Error: Android SDK not found — set ANDROID_HOME, or run:"
    echo "  sdkmanager \"platforms;android-35\" \"build-tools;35.0.0\" \"ndk;30.0.16248370\""
    exit 1
fi
echo "sdk.dir=$SDK_DIR" > android/local.properties

# Zig static lib consumed by the CMake/NDK link (CMakeLists.txt IMPORTED_LOCATION).
echo "==> zig build -Dtarget=aarch64-linux-android android-lib (ReleaseSmall)"
$ZIG build -Dtarget=aarch64-linux-android -Doptimize=ReleaseSmall android-lib
if [ ! -f zig-out/lib/libgallery.a ]; then
    echo "Error: zig-out/lib/libgallery.a not found after android-lib build"
    exit 1
fi

echo "==> Gradle assembleRelease + bundleRelease (arm64)"
(cd android && ./gradlew assembleRelease bundleRelease --console=plain -q)

APK_SRC="android/app/build/outputs/apk/release/app-release.apk"
AAB_SRC="android/app/build/outputs/bundle/release/app-release.aab"
for f in "$APK_SRC" "$AAB_SRC"; do
    [ -f "$f" ] || { echo "Error: expected Gradle output missing: $f"; exit 1; }
done

mkdir -p "$OUTPUT_DIR"
APK_DST="$OUTPUT_DIR/Klaxon-gallery-android-arm64.apk"
AAB_DST="$OUTPUT_DIR/Klaxon-gallery-android-arm64.aab"
cp "$APK_SRC" "$APK_DST"
cp "$AAB_SRC" "$AAB_DST"

# Post-checks with the SDK build-tools, when present. AGP already zipaligns
# release APKs during packaging; `zipalign -c` verifies. apksigner shows
# which key signed the artifacts (debug vs KX_KEYSTORE release key).
# Newest build-tools dir (numeric dotted-version sort — BSD sort has no -V).
BUILD_TOOLS=$(ls -d "$SDK_DIR"/build-tools/*/ 2>/dev/null \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 || true)
if [ -n "$BUILD_TOOLS" ]; then
    if [ -x "${BUILD_TOOLS}zipalign" ]; then
        echo "==> zipalign verify (APK)"
        "${BUILD_TOOLS}zipalign" -c -v 4 "$APK_DST" >/dev/null && echo "    zipalign OK" \
            || echo "Warning: zipalign check failed on $APK_DST"
    else
        echo "Note: zipalign not in ${BUILD_TOOLS} — install build-tools (sdkmanager \"build-tools;35.0.0\")"
    fi
    if [ -x "${BUILD_TOOLS}apksigner" ]; then
        echo "==> apksigner verify (APK)"
        "${BUILD_TOOLS}apksigner" verify --verbose --print-certs "$APK_DST" 2>&1 | sed 's/^/    /' || true
    fi
else
    echo "Note: no build-tools under $SDK_DIR — skipping zipalign/apksigner checks"
    echo "      (install: sdkmanager \"build-tools;35.0.0\")"
fi

echo ""
echo "==> Done:"
ls -lh "$APK_DST" "$AAB_DST" | awk '{print "    "$5"  "$9}'
if [ -z "${KX_KEYSTORE:-}" ]; then
    echo "    Signed with the SDK debug key (KX_KEYSTORE unset) — fine for"
    echo "    local installs; the Play Console upload needs a real upload key."
fi
