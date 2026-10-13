#!/bin/bash
# run.sh — build + run the Compose Multiplatform conformance runner.
#
# Usage: conformance/runners/compose/run.sh [flags]
#   --dir=<path>      tests directory (default <repo>/conformance/tests)
#   --file=<path>     run a single vector file
#   --test=<substr>   run only tests whose id contains the substring
#   --out=<path>      report path (default conformance/results/compose/results-<ts>.json)
#   --no-report       skip the report file (console only)
#   --min-score=<pct> exit 1 below the score (default 0)
#   --verbose         print every test, not just failures
#
# Builds the fat jar with the Gradle wrapper (OpenJDK 21 from Homebrew —
# /usr/bin/java is a broken stub on this machine), then runs it headless:
# androidx.compose.ui.scene.CanvasLayersComposeScene renders into a CPU
# raster Skiko surface — no window, no GPU, no vsync.
#
# The console summary goes to stdout (PASS/FAIL per test + per-domain tallies);
# the JSON report is written under conformance/results/compose/.
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT="$(cd ../../.. && pwd)"

export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export PATH="$JAVA_HOME/bin:$PATH"

./gradlew --console=plain fatJar >&2

export KLAXON_CONF_DIR="${REPO_ROOT}/conformance/tests"
export KLAXON_CONF_OUT_DIR="${REPO_ROOT}/conformance/results/compose"
export KLAXON_CONF_BIN="${PWD}/build/libs/klaxon-conformance-compose-all.jar"
mkdir -p "${KLAXON_CONF_OUT_DIR}"

java -Xmx2g -Djava.awt.headless=true -jar "${KLAXON_CONF_BIN}" --dir="${KLAXON_CONF_DIR}" "$@"
