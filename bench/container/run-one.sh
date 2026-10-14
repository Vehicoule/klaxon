#!/bin/bash
# run-one.sh — in-container entry point: run ONE framework's bench suite.
#
#   run-one.sh <klaxon|qt|compose|flutter> [scene ...]
#
# /repo = the host Klaxon checkout (mounted read-only). We rsync it to /work
# so builds never write into the host checkout, then link /opt/klaxon-deps
# (baked into the image) as deps/. JSON results land on /work/bench/results
# and are copied to the /results mount at the end — same schema-v2 files the
# macOS runners produce, tagged with the container config in the filename.

set -euo pipefail

FW="${1:?usage: run-one.sh <klaxon|qt|compose|flutter> [scene ...]}"
shift || true

CFG="${BENCH_CFG:-default}"     # e.g. full / c2m4 — stamped into the report
TS="$(date -u +%Y%m%d-%H%M%S)"
# /results maps to bench/results/container-<cfg>/ on the host: files land at
# <cfg>/<fw>/<ts>.json — the two-level scheme bench-report.py reads, one
# matrix per resource config. Env envelopes go to /results/_env/.

echo "[run-one] $FW cfg=$CFG — staging repo" >&2
# deps/ holds platform binaries on the host — all excluded EXCEPT deps/mcu,
# the vendored material-color-utilities source the build now needs. The
# image's /opt/klaxon-deps supplies the linux binaries via per-entry links.
rsync -a --include='deps/' --include='deps/mcu/***' --exclude='deps/*' \
      --exclude .git --exclude bench/results \
      --exclude 'bench/runners/*/build' /repo/ /work/
mkdir -p /work/deps
for d in /opt/klaxon-deps/*; do
  [ -e "/work/deps/$(basename "$d")" ] || ln -sfn "$d" "/work/deps/$(basename "$d")"
done
mkdir -p "/work/bench/results/$FW" "/work/bench/results/_env" "/results/_env" 2>/dev/null || true

dump_env() {
  # Methodology fields — every result gets the machine envelope so runs are
  # comparable across configs (cpus/memory come from the container caps).
  {
    echo "{"
    echo "  \"config\": \"$CFG\","
    echo "  \"framework\": \"$FW\","
    echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"cpus_quota\": \"$(nproc)/$(cat /sys/fs/cgroup/cpu.max 2>/dev/null || echo -)\","
    echo "  \"memory_max\": \"$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo -)\","
    echo "  \"kernel\": \"$(uname -srm)\""
    echo "}"
  } > "/work/bench/results/_env/env-$FW-$CFG-$TS.json"
  cp "/work/bench/results/_env/env-$FW-$CFG-$TS.json" "/results/_env/" 2>/dev/null || true
}

case "$FW" in
  klaxon)
    cd /work
    zig build bench -Dbench-output="/work/bench/results/$FW/$CFG-$TS.json" ${@:+-Dbench-scene=$1}
    ;;
  qt)
    export KLAXON_BENCH_OUT_DIR="/work/bench/results/$FW"
    /work/bench/runners/qt/run.sh "$@"
    ;;
  compose)
    export KLAXON_BENCH_OUT_DIR="/work/bench/results/$FW"
    cd /work/bench/runners/compose && ./run.sh "$@"
    ;;
  flutter)
    export KLAXON_BENCH_OUT_DIR="/work/bench/results/$FW"
    # Host-cloned SDK mounted at /opt/flutter-host (fetch-flutter.sh). First
    # run precaches linux engine artifacts into the mount — network at run
    # time is fast (IPv6 ~22 MB/s vs buildkit's ~10 KB/s on IPv4 NAT).
    export PATH="/opt/flutter-host/bin:$PATH"
    git config --global --add safe.directory /opt/flutter-host 2>/dev/null || true
    if [ ! -d /opt/flutter-host/bin/cache/artifacts/engine ]; then
      flutter config --enable-linux-desktop >/dev/null 2>&1 || true
      flutter precache --linux >&2
    fi
    # run.sh auto-detects uname and wraps the GTK binary in xvfb-run itself.
    cd /work/bench/runners/flutter && ./run.sh "$@"
    ;;
  *) echo "run-one: unknown framework '$FW'" >&2; exit 2 ;;
esac

dump_env
# Collect whatever the runner wrote and expose it on the /results mount.
cp -a "/work/bench/results/$FW/." "/results/$FW/" 2>/dev/null || true
# Apple `container` 1.5.0 cannot mount host volumes (VM boot hangs) and cp
# needs a running container — so results also go out on stdout between
# markers; the host-side matrix script extracts them into files.
echo "===KXRESULTS-BEGIN==="
find /work/bench/results -name '*.json' -type f | sort | while read -r f; do
  echo "---FILE:${f#/work/bench/results/}"
  cat "$f"
done
echo "===KXRESULTS-END==="
echo "[run-one] $FW done → /results/$FW" >&2
