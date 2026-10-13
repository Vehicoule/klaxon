#!/bin/bash
# run.sh — build (if needed) and run the Flutter comparison bench runner
# (roadmap Phase 4c.4 + bench-scenes.md v2 + the linux headless tier).
#
# Usage: bench/runners/flutter/run.sh [scene ...]
#   No arguments  -> run all 33 canonical scenes, one process per scene.
#   One or more scene names -> run just those scenes.
#
# Platforms:
#   macOS  — `flutter build macos --release`, runs the .app directly.
#   Linux  — `flutter build linux --release`, runs the GTK bundle under
#            Xvfb when no display is attached (xvfb-run), forcing Mesa's
#            software rasterizer (LIBGL_ALWAYS_SOFTWARE=1) — the
#            containerized raster tier. If DISPLAY is already set (e.g.
#            inside an Xvfb session or a real desktop), the binary runs
#            directly.
#
# The first invocation builds the release binary (downloads engine
# artifacts on first use — takes a while). Each scene run prints the
# Klaxon-compatible JSON report to stdout and writes it to
# bench/results/flutter/<ISO8601-timestamp>.json (the runner resolves the
# directory relative to the repo root, which is the CWD for every run;
# override with KLAXON_BENCH_OUT_DIR).
#
# Linux deps (Debian/Ubuntu): flutter SDK on PATH (or FLUTTER=...),
#   clang, cmake, ninja-build, pkg-config, libgtk-3-dev, xvfb + xauth
#   (xvfb-run needs it), mesa (libgl1-mesa-dri). See README.md
#   "Linux headless".
set -euo pipefail

RUNNER_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$RUNNER_DIR/../../.." && pwd)"
OS="$(uname -s)"

if [ -n "${FLUTTER:-}" ]; then
  FLUTTER_BIN="$FLUTTER"
elif command -v flutter >/dev/null 2>&1; then
  FLUTTER_BIN="$(command -v flutter)"
elif [ -x /opt/homebrew/share/flutter/bin/flutter ]; then
  FLUTTER_BIN=/opt/homebrew/share/flutter/bin/flutter
else
  echo "run.sh: flutter not found (set FLUTTER=/path/to/flutter)" >&2
  exit 1
fi

# Runner invocation: on Linux with no display, wrap the binary in xvfb-run
# so GTK gets a virtual X server; LIBGL_ALWAYS_SOFTWARE keeps GL on Mesa's
# llvmpipe (no GPU in the container). LAUNCHER is an array so it splices
# correctly into the run line.
LAUNCHER=()
case "$OS" in
  Darwin)
    EXE="$RUNNER_DIR/build/macos/Build/Products/Release/klaxon_bench.app/Contents/MacOS/klaxon_bench"
    BUILD_CMD=(build macos --release)
    ;;
  Linux)
    BUILD_CMD=(build linux --release)
    # `flutter build linux` lays the bundle out under the target arch dir
    # (x64 / arm64). Resolve whichever release bundle exists.
    EXE=""
    for b in "$RUNNER_DIR"/build/linux/*/release/bundle/klaxon_bench; do
      if [ -x "$b" ]; then EXE="$b"; break; fi
    done
    if [ -z "${DISPLAY:-}" ]; then
      if command -v xvfb-run >/dev/null 2>&1; then
        LAUNCHER=(xvfb-run -a -s "-screen 0 800x600x24")
        export LIBGL_ALWAYS_SOFTWARE=1
      else
        echo "run.sh: no DISPLAY and xvfb-run not found —" \
             "install xvfb or run inside an X session" >&2
        exit 1
      fi
    fi
    ;;
  *)
    echo "run.sh: unsupported OS '$OS' (macOS and Linux only)" >&2
    exit 1
    ;;
esac

if [ -z "$EXE" ] || [ ! -x "$EXE" ]; then
  echo "run.sh: building klaxon_bench (first build downloads engine artifacts)..." >&2
  (cd "$RUNNER_DIR" && "$FLUTTER_BIN" "${BUILD_CMD[@]}")
fi

# Re-resolve the linux binary after the first build.
if [ "$OS" = "Linux" ] && [ ! -x "$EXE" ]; then
  for b in "$RUNNER_DIR"/build/linux/*/release/bundle/klaxon_bench; do
    if [ -x "$b" ]; then EXE="$b"; break; fi
  done
fi
if [ ! -x "$EXE" ]; then
  echo "run.sh: built binary not found (expected at $EXE)" >&2
  exit 1
fi

mkdir -p "$REPO_ROOT/bench/results/flutter"

if [ "$#" -gt 0 ]; then
  SCENES="$*"
else
  SCENES="hello scroll_10k text_cjk glass_blur anim_100 gallery resize input_ime video_playback list_create_1k list_replace_1k list_update_10th list_swap_rows list_remove_row list_clear_1k shapes_ramp paths_ramp text_ramp images_ramp overdraw_stack elevation_grid relayout_storm mount_churn scroll_anim text_rich chart_live clip_path theme_switch backdrop_scroll input_latency pointer_storm semantics_build app_switch"
fi

for scene in $SCENES; do
  echo "run.sh: scene $scene" >&2
  # ${LAUNCHER[@]+...} — bash 3.2-safe empty-array expansion under set -u.
  (cd "$REPO_ROOT" && ${LAUNCHER[@]+"${LAUNCHER[@]}"} "$EXE" "$scene")
done
