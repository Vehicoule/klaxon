#!/bin/bash
# run.sh — build + run the Compose side of the pixel-fidelity harness.
#
# Usage: fidelity/compose/run.sh [flags]
#   --scenes=<path>   scene matrix (default <repo>/fidelity/scenes.json)
#   --out=<dir>       image output dir (default <repo>/fidelity/out/compose)
#   --scene=<substr>  run only scenes whose id contains the substring
#
# Builds the fat jar with the Gradle wrapper (OpenJDK 21 from Homebrew —
# /usr/bin/java is a broken stub on this machine), then runs it headless:
# androidx.compose.ui.ImageComposeScene renders into a CPU raster Skiko
# surface — no window, no GPU, no vsync.
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT="$(cd ../.. && pwd)"

export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export PATH="$JAVA_HOME/bin:$PATH"

./gradlew --console=plain fatJar >&2

export KLAXON_FID_SCENES="${REPO_ROOT}/fidelity/scenes.json"
export KLAXON_FID_OUT="${REPO_ROOT}/fidelity/out/compose"
export KLAXON_FID_BIN="${PWD}/build/libs/klaxon-fidelity-compose-all.jar"
mkdir -p "${KLAXON_FID_OUT}"

java -Xmx2g -Djava.awt.headless=true -jar "${KLAXON_FID_BIN}" \
    --scenes="${KLAXON_FID_SCENES}" --out="${KLAXON_FID_OUT}" "$@"
