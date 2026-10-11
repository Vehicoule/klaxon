#!/bin/bash
# run.sh — build + run the Compose Multiplatform comparison benchmark runner
# (roadmap 4c.4).
#
# Usage: bench/runners/compose/run.sh [scene]
#   scene   run one scene (hello, scroll_10k, text_cjk, glass_blur, anim_100,
#           gallery, resize, input_ime, video_playback); no argument = all 9.
#
# Builds the fat jar with the Gradle wrapper (OpenJDK 21 from Homebrew —
# /usr/bin/java is a broken stub on this machine), then runs it headless:
# androidx.compose.ui.scene.CanvasLayersComposeScene renders into a CPU raster
# Skiko surface — no window, no GPU, no vsync; the harness drives an unpaced
# frame loop, the closest Compose analog of Klaxon's headless bench.
#
# The runner prints the JSON report to stdout and writes it to
# bench/results/compose/<ISO8601-timestamp>.json (same schema as `klaxon bench`).
# Progress + verification chatter goes to stderr, so the JSON stream on stdout
# stays clean.
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT="$(cd ../../.. && pwd)"

export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export PATH="$JAVA_HOME/bin:$PATH"

# Build chatter goes to stderr so the JSON report on stdout stays clean.
./gradlew --console=plain fatJar >&2

export KLAXON_BENCH_OUT_DIR="${REPO_ROOT}/bench/results/compose"
export KLAXON_BENCH_BIN="${PWD}/build/libs/klaxon-bench-compose-all.jar"
mkdir -p "${KLAXON_BENCH_OUT_DIR}"

java -Xmx2g -Djava.awt.headless=true -jar "${KLAXON_BENCH_BIN}" "$@"
