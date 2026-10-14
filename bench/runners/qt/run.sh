#!/bin/bash
# run.sh — build + run the Qt comparison benchmark runner (roadmap 4c.4).
#
# Usage: bench/runners/qt/run.sh [scene]
#   scene   run one scene — the 9 Phase-4c.4 scenes (hello, scroll_10k,
#           text_cjk, glass_blur, anim_100, gallery, resize, input_ime,
#           video_playback) plus the 24 catalogue-v2 scenes (list_ops:
#           list_create_1k list_replace_1k list_update_10th list_swap_rows
#           list_remove_row list_clear_1k; ramp: shapes_ramp paths_ramp
#           text_ramp images_ramp; stress: overdraw_stack elevation_grid
#           relayout_storm mount_churn scroll_anim text_rich chart_live
#           clip_path theme_switch backdrop_scroll; system: input_latency
#           pointer_storm semantics_build app_switch); no argument = all 33.
#
# Builds the runner (Qt 6 via Homebrew), then runs it headless
# (QT_QPA_PLATFORM=offscreen + QT_QUICK_BACKEND=software — CPU raster, no
# window, no vsync; the closest Qt analog of Klaxon's headless bench).
#
# Tier-2 windowed mode: `run.sh --windowed [scene]` runs on a REAL cocoa
# window with the default RHI backend (Metal) and the threaded render loop.
# Frames are driven by update()+frameSwapped; timed work = the GUI span
# (tick -> afterSynchronizing) + the render span (beforeRenderPassRecording
# -> afterRendering — record + submit + present call), so the vsync wait
# inside the drawable acquire stays out of frame_ms, matching Klaxon's
# last_frame_wait_ns subtraction and Flutter's FrameTiming work spans.
# Report goes to bench/results/tier2-macos-metal/qt/ with "backend" tagged.
#
# The runner prints the JSON report to stdout and writes it to
# bench/results/qt/<ISO8601-timestamp>.json (same schema as `klaxon bench`).
# Per-scene render verification (pixel hashes, IME text, list state) goes to
# stderr, so the JSON stream on stdout stays clean.
#   CMAKE_PREFIX_PATH      Qt location (default /opt/homebrew)
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT="$(cd ../../.. && pwd)"

WINDOWED=0
if [ "${1:-}" = "--windowed" ]; then
  WINDOWED=1
  shift
fi

export CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH:-/opt/homebrew}"

# Build chatter goes to stderr so the JSON report on stdout stays clean.
cmake -B build -DCMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH}" -DCMAKE_BUILD_TYPE=Release >&2
cmake --build build -j >&2

if [ "$WINDOWED" = "1" ]; then
  unset QT_QPA_PLATFORM QT_QUICK_BACKEND QSG_RENDER_LOOP
  export KLAXON_BENCH_WINDOWED=1
  export KLAXON_BENCH_OUT_DIR="${REPO_ROOT}/bench/results/tier2-macos-metal/qt"
else
  export QT_QPA_PLATFORM=offscreen
  export QT_QUICK_BACKEND=software
  export QSG_RENDER_LOOP=basic
  export KLAXON_BENCH_OUT_DIR="${REPO_ROOT}/bench/results/qt"
fi
mkdir -p "${KLAXON_BENCH_OUT_DIR}"

"${REPO_ROOT}/bench/runners/qt/build/klaxon_bench_qt" "$@"
