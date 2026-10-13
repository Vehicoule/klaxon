#!/bin/sh
# Build + run the Qt6 conformance suite offscreen.
#
# Usage:
#   ./run.sh [--dir DIR|--file FILE|--test FILTER|--out FILE|--min-score N] [extra cmake args]
#
# Qt is located via CMAKE_PREFIX_PATH / Qt6_DIR. Pass extra cmake args to
# point at a custom Qt install:
#   ./run.sh -- -DCMAKE_PREFIX_PATH=/opt/qt/6.11/lib/cmake
set -e

cd "$(dirname "$0")"

CMAKE_ARGS=""
RUN_ARGS=""
sep=0
for a in "$@"; do
    if [ "$a" = "--" ]; then sep=1; continue; fi
    if [ "$sep" = "0" ]; then RUN_ARGS="$RUN_ARGS $a"; else CMAKE_ARGS="$CMAKE_ARGS $a"; fi
done

QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-offscreen}
export QT_QPA_PLATFORM

BUILD_DIR=build
cmake -S . -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release $CMAKE_ARGS
cmake --build "$BUILD_DIR" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

# Run from the repo root so --dir conformance/tests resolves like the Zig runner.
cd ../../..
exec "conformance/runners/qt/$BUILD_DIR/klaxon-qt-conformance" $RUN_ARGS
