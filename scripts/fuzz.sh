#!/bin/bash
# fuzz.sh — run a Klaxon fuzz harness for a bounded time.
#
# Usage:
#   scripts/fuzz.sh --target text_edit --seconds 30
#   scripts/fuzz.sh --target tree_json --seconds 5
#   scripts/fuzz.sh --target all --seconds 20   # each target, in turn
#
# Under the hood: `zig build fuzz -Dfuzz-target=X --fuzz=<huge>` — the build
# runner compiles the harness with -ffuzz and drives it; this wrapper kills
# the build after --seconds. Exit 124 (timeout) means "time's up, no crash".
#
# Targets: text_edit | tree_json | arb | input | all
set -euo pipefail

cd "$(dirname "$0")/.."

TARGET=""
SECONDS_LIMIT=""
for ((i = 1; i <= $#; i++)); do
    case "${!i}" in
        --target) i=$((i + 1)); TARGET="${!i}" ;;
        --target=*) TARGET="${!i#--target=}" ;;
        --seconds) i=$((i + 1)); SECONDS_LIMIT="${!i}" ;;
        --seconds=*) SECONDS_LIMIT="${!i#--seconds=}" ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "fuzz.sh: unknown argument '${!i}'" >&2; exit 2 ;;
    esac
done

if [[ -z "${TARGET}" || -z "${SECONDS_LIMIT}" ]]; then
    echo "usage: scripts/fuzz.sh --target <text_edit|tree_json|arb|input|all> --seconds <N>" >&2
    exit 2
fi

# Run `zig build fuzz` under a wall-clock bound. `timeout` is GNU coreutils
# (absent on stock macOS), so fall back to a portable watchdog when needed.
run_bounded() {
    local target="$1" secs="$2"
    if command -v timeout >/dev/null 2>&1; then
        timeout --kill-after=5s "${secs}" zig build fuzz -Dfuzz-target="${target}" --fuzz=999999999
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout --kill-after=5s "${secs}" zig build fuzz -Dfuzz-target="${target}" --fuzz=999999999
    else
        zig build fuzz -Dfuzz-target="${target}" --fuzz=999999999 &
        local pid=$!
        ( sleep "${secs}"; kill -KILL "${pid}" 2>/dev/null || true ) &
        local watchdog=$!
        local status=0
        wait "${pid}" || status=$?
        kill "${watchdog}" 2>/dev/null || true
        wait "${watchdog}" 2>/dev/null || true
        # Killed by SIGKILL → 137; report as timeout like `timeout` would.
        [[ ${status} -eq 137 ]] && status=124
        return ${status}
    fi
}

fail=0
if [[ "${TARGET}" == "all" ]]; then
    targets=(text_edit tree_json arb input)
else
    targets=("${TARGET}")
fi

for t in "${targets[@]}"; do
    echo "=== fuzz ${t} (${SECONDS_LIMIT}s) ==="
    status=0
    run_bounded "${t}" "${SECONDS_LIMIT}" || status=$?
    case ${status} in
        0|124|137|143) echo "=== ${t}: ok (${SECONDS_LIMIT}s elapsed) ===" ;;
        *) echo "=== ${t}: FAILED (exit ${status}) — see fuzz report above ===" >&2; fail=1 ;;
    esac
done
exit ${fail}
