#!/bin/bash
# run.sh — build + run the Qt comparison benchmark runner (roadmap 4c.4).
#
# Usage: bench/runners/qt/run.sh [scene]
#   scene   run one scene (hello, scroll_10k, text_cjk, glass_blur, anim_100,
#           gallery, resize, input_ime, video_playback); no argument = all 9.
#
# Builds the runner (Qt 6 via Homebrew), then runs it headless
# (QT_QPA_PLATFORM=offscreen + QT_QUICK_BACKEND=software — CPU raster, no
# window, no vsync; the closest Qt analog of Klaxon's headless bench).
#
# The runner prints the JSON report to stdout and writes it to
# bench/results/qt/<ISO8601-timestamp>.json (same schema as `klaxon bench`).
# Per-scene render verification (pixel hashes, IME text, list state) goes to
# stderr, so the JSON stream on stdout stays clean.
#   CMAKE_PREFIX_PATH      Qt location (default /opt/homebrew)
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT="$(cd ../../.. && pwd)"

export CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH:-/opt/homebrew}"

# Build chatter goes to stderr so the JSON report on stdout stays clean.
cmake -B build -DCMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH}" -DCMAKE_BUILD_TYPE=Release >&2
cmake --build build -j >&2

export QT_QPA_PLATFORM=offscreen
export QT_QUICK_BACKEND=software
export QSG_RENDER_LOOP=basic
export KLAXON_BENCH_OUT_DIR="${REPO_ROOT}/bench/results/qt"
mkdir -p "${KLAXON_BENCH_OUT_DIR}"

"${REPO_ROOT}/bench/runners/qt/build/klaxon_bench_qt" "$@"
