#!/usr/bin/env bash
# m3e-drift.sh — reports upstream drift between the vendored .ref/ snapshot
# and androidx-main HEAD. The vendored refs are pinned (.ref/LOCK); widget
# ports were written against that pin, so a changed file here means the
# corresponding widget's port may be stale — check docs/M3E-PORT.md's
# widget→source table for who consumes it.
#
# Usage: scripts/m3e-drift.sh        (leaves .ref-next/ for inspection)
# Exit code is 0 either way; this is a report, not a gate.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NEXT="$ROOT/.ref-next"
PIN="$(sed -n 's/^sha=//p' "$ROOT/.ref/LOCK" 2>/dev/null)"
echo "== pinned: ${PIN:-<none>}"

LATEST=$(curl -sf "https://api.github.com/repos/androidx/androidx/commits?path=compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3&sha=androidx-main&per_page=1" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['sha'])")
echo "== androidx-main last material3-touching commit: $LATEST"
[ "$LATEST" = "$PIN" ] && echo "   (same commit — still diffing content: other dirs may have moved)"

rm -rf "$NEXT"
OUT="$NEXT" REF=androidx-main "$ROOT/scripts/fetch-m3e-ref.sh" >/dev/null

echo; echo "== changed / new files (vendored vs androidx-main) =="
diff -qr "$ROOT/.ref" "$NEXT" 2>/dev/null | grep -v "^Only in $NEXT/LOCK\|^Only in .*LOCK$" | while read -r line; do
  echo "  $line"
done

echo; echo "== affected ported widgets (docs/M3E-PORT.md consumers) =="
diff -qr "$ROOT/.ref" "$NEXT" 2>/dev/null | sed -n 's/^.*ref[^ ]*\/\([^/ ]*\.kt\).*$/\1/p' | sort -u | while read -r f; do
  base="${f%.kt}"
  hit=$(grep -l "$base" "$ROOT"/src/widgets/*.zig 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')
  echo "  $f → ${hit:-(no widget reference found)}"
done
echo; echo "inspect: git diff --no-index .ref .ref-next   (then rm -rf .ref-next)"
