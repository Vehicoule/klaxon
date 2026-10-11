#!/bin/bash
# bench.sh — run the Klaxon benchmarks (Phase 4c.3) and save the JSON report.
#
# Usage: scripts/bench.sh [zig build options...]
#   Any extra arguments are forwarded to `zig build bench`, e.g.:
#     scripts/bench.sh -Dbench-frames=1200
#     scripts/bench.sh -Dbench-scene=scroll_10k
#     scripts/bench.sh -Dbench-output=bench/results/custom.json
#
# Produces: bench/results/$(date +%Y%m%d-%H%M%S).json
# The report is also printed to stdout (zig build's own chatter goes to stderr).
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="bench/results"
mkdir -p "${OUT_DIR}"
OUT_FILE="${OUT_DIR}/$(date +%Y%m%d-%H%M%S).json"

zig build bench "$@" | tee "${OUT_FILE}"
