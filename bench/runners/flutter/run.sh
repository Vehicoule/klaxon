#!/bin/bash
# run.sh — build (if needed) and run the Flutter comparison bench runner
# (roadmap Phase 4c.4).
#
# Usage: bench/runners/flutter/run.sh [scene ...]
#   No arguments  -> run all 9 canonical scenes, one process per scene.
#   One or more scene names -> run just those scenes.
#
# The first invocation runs `flutter build macos --release` (downloads ~1 GB of
# engine artifacts on first use — takes a while). Each scene run prints the
# Klaxon-compatible JSON report to stdout and writes it to
# bench/results/flutter/<ISO8601-timestamp>.json (the runner resolves the
# directory relative to the repo root, which is the CWD for every run).
set -euo pipefail

RUNNER_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$RUNNER_DIR/../../.." && pwd)"

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

APP="$RUNNER_DIR/build/macos/Build/Products/Release/klaxon_bench.app"
EXE="$APP/Contents/MacOS/klaxon_bench"

if [ ! -x "$EXE" ]; then
  echo "run.sh: building klaxon_bench (first build downloads ~1 GB of engine artifacts)..." >&2
  (cd "$RUNNER_DIR" && "$FLUTTER_BIN" build macos --release)
fi

mkdir -p "$REPO_ROOT/bench/results/flutter"

if [ "$#" -gt 0 ]; then
  SCENES="$*"
else
  SCENES="hello scroll_10k text_cjk glass_blur anim_100 gallery resize input_ime video_playback"
fi

for scene in $SCENES; do
  echo "run.sh: scene $scene" >&2
  (cd "$REPO_ROOT" && "$EXE" "$scene")
done
