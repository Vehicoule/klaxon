#!/bin/bash
# run.sh — build + run the Compose Multiplatform comparison benchmark runner
# (roadmap 4c.4/4c.6).
#
# Usage: bench/runners/compose/run.sh [scene]
#   scene   run one scene (hello, scroll_10k, ..., list_create_1k, shapes_ramp,
#           overdraw_stack, input_latency, ...); no argument = all 33
#           (the 9 bench.zig scenes + the 24 bench-scenes.md schema-v2 scenes).
#
# Builds the fat jar with the Gradle wrapper (OpenJDK 21 from Homebrew —
# /usr/bin/java is a broken stub on this machine), then runs it headless:
# androidx.compose.ui.scene.CanvasLayersComposeScene renders into a CPU raster
# Skiko surface — no window, no GPU, no vsync; the harness drives an unpaced
# frame loop, the closest Compose analog of Klaxon's headless bench.
#
# Tier-2 windowed mode: `run.sh --windowed [scene]` runs on a REAL JFrame +
# org.jetbrains.skiko.SkiaLayer on Metal. Each frame is driven by a
# synchronous SkiaLayer.paint() (render + flush + present, vsync disabled so
# the present doesn't block — the timed span covers work only, the same
# contract as Klaxon's last_frame_wait_ns subtraction). Report goes to
# bench/results/tier2-macos-metal/compose/ with "backend": "skiko-metal".
#
# The runner prints the JSON report to stdout and writes it to
# bench/results/compose/<ISO8601-timestamp>.json (same schema as `klaxon bench`).
# Progress + verification chatter goes to stderr, so the JSON stream on stdout
# stays clean.
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT="$(cd ../../.. && pwd)"

WINDOWED=0
if [ "${1:-}" = "--windowed" ]; then
  WINDOWED=1
  shift
fi

# JAVA_HOME: Homebrew openjdk@21 on macOS (system /usr/bin/java can be a
# broken stub); on Linux fall back to the distro JDK via `readlink java`.
if [ -z "${JAVA_HOME:-}" ]; then
  if [ -d /opt/homebrew/opt/openjdk@21 ]; then
    JAVA_HOME=/opt/homebrew/opt/openjdk@21
  else
    JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
  fi
fi
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

# Build chatter goes to stderr so the JSON report on stdout stays clean.
./gradlew --console=plain fatJar >&2

export KLAXON_BENCH_BIN="${PWD}/build/libs/klaxon-bench-compose-all.jar"
if [ "$WINDOWED" = "1" ]; then
  export KLAXON_BENCH_WINDOWED=1
  export KLAXON_BENCH_OUT_DIR="${REPO_ROOT}/bench/results/tier2-macos-metal/compose"
else
  export KLAXON_BENCH_OUT_DIR="${REPO_ROOT}/bench/results/compose"
fi
mkdir -p "${KLAXON_BENCH_OUT_DIR}"

if [ "$WINDOWED" = "1" ]; then
  # Real window — no headless flag; the JFrame needs a GUI session.
  java -Xmx2g -jar "${KLAXON_BENCH_BIN}" "$@"
else
  java -Xmx2g -Djava.awt.headless=true -jar "${KLAXON_BENCH_BIN}" "$@"
fi
