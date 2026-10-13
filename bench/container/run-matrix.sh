#!/bin/bash
# run-matrix.sh — host-side orchestrator: one full suite run per framework,
# per container resource config.
#
#   bench/container/run-matrix.sh                    # all frameworks × all configs
#   bench/container/run-matrix.sh klaxon qt          # subset of frameworks
#   BENCH_CONFIGS="c2m4" bench/container/run-matrix.sh klaxon
#
# Matrix: frameworks {klaxon,qt,compose,flutter} × configs
#   full  — 8 cpus, 16G   (generous quota)
#   c2m4  — 2 cpus, 4G    (constrained "low-end device" profile)
#
# NOTE: Apple `container` 1.5.0 (macOS 27.2) hangs VM boot on ANY volume
# mount (-v/--mount, even named volumes) and `container cp` requires a
# running container. So the source is baked into klaxon-bench-src (see
# Dockerfile.src) and results come back on stdout between KXRESULTS markers,
# which this script extracts into bench/results/container-<cfg>/<fw>/ — the
# two-level <config>/<framework>/ layout bench-report.py reads.
#
# If a `container run` wedges (known: the CLI can queue behind a stuck
# invocation), the per-run timeout kills it and the matrix continues; rerun
# the failed cell later. Never leave a hung `container` client alive — it
# poisons subsequent runs.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${BENCH_IMAGE:-klaxon-bench-src}"
FLUTTER_IMAGE="${BENCH_FLUTTER_IMAGE:-klaxon-bench-flutter}"
RESULTS="${REPO_ROOT}/bench/results"
LOG_DIR="${RESULTS}/_logs"
mkdir -p "$LOG_DIR"

FRAMEWORKS=("$@")
[ ${#FRAMEWORKS[@]} -eq 0 ] && FRAMEWORKS=(klaxon qt compose flutter)

CONFIGS="${BENCH_CONFIGS:-full c2m4}"
RUN_TIMEOUT="${BENCH_RUN_TIMEOUT:-3600}"   # seconds per framework run

cfg_caps() {
  case "$1" in
    full) echo "--cpus 8 --memory 16G" ;;
    c2m4) echo "--cpus 2 --memory 4G" ;;
    *)    echo "--cpus 8 --memory 16G" ;;
  esac
}

# Extract KXRESULTS-BEGIN..END payload from a run log into $outdir.
# Payload lines: "---FILE:<relpath>" then the file body until next marker.
extract_results() {
  local log="$1" outdir="$2"
  python3 - "$log" "$outdir" <<'PYEOF'
import os, sys
log, outdir = sys.argv[1], sys.argv[2]
cur, buf = None, []
count = 0
def flush():
    global count
    if cur is not None:
        dest = os.path.join(outdir, cur)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, 'w') as fh:
            fh.write(''.join(buf))
        count += 1
with open(log, 'rb') as fh:
    in_block = False
    for raw in fh:
        line = raw.decode('utf-8', 'replace').rstrip('\n')
        if line == '===KXRESULTS-BEGIN===':
            in_block = True; continue
        if line == '===KXRESULTS-END===':
            flush(); break
        if not in_block:
            continue
        if line.startswith('---FILE:'):
            flush()
            cur, buf = line[len('---FILE:'):], []
        else:
            buf.append(line + '\n')
print(f"extracted {count} files → {outdir}")
PYEOF
}

rc=0
for cfg in $CONFIGS; do
  caps="$(cfg_caps "$cfg")"
  out="${RESULTS}/container-${cfg}"
  mkdir -p "$out"
  for fw in "${FRAMEWORKS[@]}"; do
    img="$IMAGE"
    [ "$fw" = flutter ] && img="$FLUTTER_IMAGE"
    echo "=== [$cfg] $fw (image $img) ===" >&2
    log="${LOG_DIR}/container-${cfg}-${fw}-$(date +%H%M%S).log"
    timeout "$RUN_TIMEOUT" container run --rm $caps \
      --env "BENCH_CFG=container-${cfg}" \
      "$img" "$fw" >"$log" 2>"$log.err"
    if grep -q '===KXRESULTS-END===' "$log"; then
      extract_results "$log" "$out"
    else
      echo "!!! $fw@$cfg: no KXRESULTS block (see $log / $log.err)" >&2
      rc=1
    fi
  done
done

echo "=== matrix done → $RESULTS (rc=$rc) ===" >&2
exit $rc
