#!/usr/bin/env bash
# Fetches upstream Compose sources into .ref/ — the auditable reference for
# the widgets' verbatim ports (draw/measure logic).
#
# The ref is PINNED: the vendored snapshot must be reproducible, and widget
# headers record which upstream they were ported against. The pin lives in
# .ref/LOCK (sha + resolved date); this script re-reads it as its default.
# Override for one shot:  REF=<sha|branch> ./scripts/fetch-m3e-ref.sh
# Alternate output (drift checks):  OUT=.ref-next REF=androidx-main ./scripts/fetch-m3e-ref.sh
# See scripts/m3e-drift.sh for the upstream-drift report.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/.ref/LOCK"
PINNED_SHA=677148640cfcf2d4f07826cc1c949f2e9e95f7cc # androidx-main, 2026-10-17
REF="${REF:-$(sed -n 's/^sha=//p' "$LOCK" 2>/dev/null)}"
REF="${REF:-$PINNED_SHA}"
OUT="${OUT:-$ROOT/.ref}"
API="https://api.github.com/repos/androidx/androidx/contents"
RAW="https://raw.githubusercontent.com/androidx/androidx/$REF"
M3="compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3"
RIPPLE="compose/material/material-ripple/src/commonMain/kotlin/androidx/compose/material/ripple"
INTERACT="compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/interaction"
ANIM="compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation"
ok=0; fail=0
fetch() { # url dest
  [ -s "$2" ] && [ -z "${FORCE:-}" ] && { ok=$((ok+1)); return; } # already vendored
  mkdir -p "$(dirname "$2")"
  for try in 1 2 3; do
    curl -sf "$1" -o "$2" && { ok=$((ok+1)); return; }
    sleep 1
  done
  echo "FAIL $1"; fail=$((fail+1))
}
# fetch_dir <repo-path> <dest-dir> — every .kt in the directory listing.
# (Listing piped via a file: a `| while read` subshell would lose the
# ok/fail counters.)
fetch_dir() {
  local list; list=$(mktemp -t m3e-fetch)
  curl -sf "$API/$1?ref=$REF" | python3 -c "
import json,sys
for x in json.load(sys.stdin):
    if x['type'] == 'file' and x['name'].endswith('.kt'): print(x['name'])
" > "$list"
  while read -r f; do fetch "$RAW/$1/$f" "$2/$f"; done < "$list"
  rm -f "$list"
}

# --- material3 widget files Klaxon ports ---------------------------------
WIDGETS=(
  AlertDialog.kt AppBar.kt Badge.kt BottomSheet.kt Button.kt ButtonGroup.kt
  Card.kt Checkbox.kt Chip.kt DatePicker.kt DatePickerDialog.kt Divider.kt
  DragHandle.kt FloatingActionButton.kt FloatingActionButtonMenu.kt
  IconButton.kt ListItem.kt LoadingIndicator.kt Menu.kt ModalBottomSheet.kt
  NavigationBar.kt NavigationDrawer.kt NavigationItem.kt NavigationRail.kt
  OutlinedTextField.kt ProgressIndicator.kt RadioButton.kt Scrim.kt
  SearchBar.kt SegmentedButton.kt SheetDefaults.kt Slider.kt Snackbar.kt
  SplitButton.kt Switch.kt Tab.kt TabRow.kt TextField.kt TimePicker.kt
  ToggleButton.kt Tooltip.kt WavyProgressIndicator.kt
  # interaction/elevation machinery the ports now consume
  # (applyTonalElevation/surfaceColorAtElevation live in ColorScheme.kt;
  # ElevationOverlay.kt no longer exists upstream)
  Surface.kt ColorScheme.kt InteractiveComponentSize.kt
  # previously vendored — kept so existing ports' header citations resolve
  # (BottomAppBar.kt / ModalWideNavigationRail.kt / root DialogTokens.kt were
  # deleted upstream: BottomAppBar lives in AppBar.kt, ModalWideNavigationRail
  # in WideNavigationRail.kt, DialogTokens under tokens/)
  Scaffold.kt WideNavigationRail.kt WideNavigationRailState.kt
  ExposedDropdownMenu.kt FloatingToolbar.kt TimePickerDialog.kt
  AppBarColumn.kt AppBarDsl.kt AppBarRow.kt
)
for f in "${WIDGETS[@]}"; do fetch "$RAW/$M3/$f" "$OUT/material3/$f"; done
# PullToRefresh + the carousel sources exist under subdirs upstream; both the
# canonical layout and the legacy flat `carousel-X.kt` copies are vendored
# (widget headers cite both spellings).
fetch "$RAW/$M3/pulltorefresh/PullToRefresh.kt" "$OUT/material3/PullToRefresh.kt"
fetch "$RAW/$M3/pulltorefresh/PullToRefresh.kt" "$OUT/material3/pulltorefresh/PullToRefresh.kt"
for f in Carousel.kt Keylines.kt KeylineList.kt CarouselState.kt Arrangement.kt KeylineSnapPosition.kt Strategy.kt; do
  fetch "$RAW/$M3/carousel/$f" "$OUT/material3/carousel/$f"
  fetch "$RAW/$M3/carousel/$f" "$OUT/material3/carousel-$f"
done
for f in LinearWavyProgressModifiers.kt CircularWavyProgressModifiers.kt; do
  fetch "$RAW/$M3/internal/$f" "$OUT/material3/internal-$f"
done
fetch_dir "$M3/tokens" "$OUT/material3/tokens"

# --- the indication/interaction layer (ripple, state layer, interactions) --
fetch_dir "$RIPPLE" "$OUT/material-ripple"
fetch_dir "$INTERACT" "$OUT/foundation-interaction"
# --- enter/exit transition machinery (AnimatedVisibility equivalents) -----
for f in AnimatedVisibility.kt EnterExitTransition.kt; do
  fetch "$RAW/$ANIM/$f" "$OUT/animation/$f"
done

echo "ref=$REF fetched=$ok failed=$fail"
# Refresh the lock only for the canonical output dir.
if [ "$OUT" = "$ROOT/.ref" ] && [ "$fail" -eq 0 ]; then
  {
    echo "sha=$REF"
    echo "resolved=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$LOCK"
fi
