#!/bin/bash
# run.sh — build + install + run the Jetpack Compose Android benchmark
# runner and pull its JSON report (Klaxon-compatible schema).
#
# Usage: bench/runners/compose-android/run.sh [device] [scene]
#   device   adb serial (default: first `adb devices` entry; e.g. emulator-5554)
#   scene    run a subset (e.g. hello, scroll_10k, shapes_ramp); no argument = all 9
#
# Build uses the Gradle wrapper with the Android Studio JBR (the macOS
# /usr/bin/java stub is broken); JAVA_HOME can be overridden via env.
# The report lands on-device in files/bench-compose.json (run-as) and
# /sdcard/Android/data/<pkg>/files/bench-compose.json (adb pull), and is
# also copied to bench/results/compose-android/<timestamp>.json.
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT="$(cd ../../.. && pwd)"

SERIAL="${1:-}"
SCENES="${2:-}"

# JAVA_HOME: Android Studio JBR on macOS; fall back to whatever `java` is.
if [ -z "${JAVA_HOME:-}" ]; then
  if [ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]; then
    JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  else
    JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
  fi
fi
export JAVA_HOME

if [ -z "$SERIAL" ]; then
  SERIAL="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
fi
[ -n "$SERIAL" ] || { echo "no adb device found" >&2; exit 1; }
echo "device: $SERIAL" >&2

./gradlew --console=plain assembleRelease >&2
APK=app/build/outputs/apk/release/app-release.apk
adb -s "$SERIAL" install -r "$APK" >&2
adb -s "$SERIAL" shell am force-stop com.klaxon.bench.compose >/dev/null 2>&1 || true
# Drop any previous report so the poll below can't return a stale file.
adb -s "$SERIAL" shell run-as com.klaxon.bench.compose rm -f files/bench-compose.json >/dev/null 2>&1 || true

if [ -n "$SCENES" ]; then
  adb -s "$SERIAL" shell am start \
    -n com.klaxon.bench.compose/bench.compose.BenchmarkActivity \
    -e scenes "$SCENES" >&2
else
  adb -s "$SERIAL" shell am start \
    -n com.klaxon.bench.compose/bench.compose.BenchmarkActivity >&2
fi

echo "running — watch progress: adb -s $SERIAL logcat -s KlaxonBench" >&2
# Poll for the report (suite writes it when the last scene finishes).
for _ in $(seq 1 120); do
  if adb -s "$SERIAL" shell run-as com.klaxon.bench.compose \
      cat files/bench-compose.json 2>/dev/null | grep -q '"timestamp"'; then
    break
  fi
  sleep 5
done

OUT_DIR="${REPO_ROOT}/bench/results/compose-android"
mkdir -p "$OUT_DIR"
TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
OUT="${OUT_DIR}/${TS}.json"
adb -s "$SERIAL" shell run-as com.klaxon.bench.compose cat files/bench-compose.json > "$OUT"
if ! grep -q '"timestamp"' "$OUT"; then
  echo "no report after timeout — check: adb -s $SERIAL logcat -s KlaxonBench" >&2
  rm -f "$OUT"
  exit 1
fi
echo "report: $OUT" >&2
cat "$OUT"
