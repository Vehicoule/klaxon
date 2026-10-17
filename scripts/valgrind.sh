#!/usr/bin/env bash
# valgrind.sh — run the headless smoke apps under valgrind memcheck
# (nightly, see .github/workflows/valgrind.yml). Linux only.
#
# Usage: scripts/valgrind.sh [app ...]
#   Any arguments replace the default app list, e.g.:
#     scripts/valgrind.sh hello
#
# Run `zig build` first. Prebuilt Skia/SDL3 are not valgrind-clean —
# ci/valgrind.supp carries their known-noise suppressions; extend it as
# reports arrive (re-run with --gen-suppressions=all to mint new entries).
# Exit status is the first failing app's valgrind status
# (--error-exitcode=1): memcheck errors or definite leaks.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v valgrind >/dev/null ||
  { echo "valgrind.sh: valgrind not found (linux-only — apt install valgrind)"; exit 2; }

SUPP="ci/valgrind.supp"
if [ "$#" -gt 0 ]; then APPS=("$@"); else APPS=(hello gallery navigator i18n a11y); fi

rc=0
for app in "${APPS[@]}"; do
  bin="zig-out/bin/$app"
  if [ ! -x "$bin" ]; then echo "skip $app — not built ($bin)"; continue; fi
  echo "=== valgrind $app ==="
  SDL_VIDEODRIVER=dummy valgrind \
    --tool=memcheck \
    --error-exitcode=1 \
    --leak-check=full \
    --errors-for-leak-kinds=definite \
    --suppressions="$SUPP" \
    -- "$bin" || rc=$?
done
exit "$rc"
