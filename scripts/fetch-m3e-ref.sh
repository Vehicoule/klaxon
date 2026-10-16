#!/usr/bin/env bash
# Fetches upstream Compose material3 sources into .ref/material3/ — the
# auditable reference for the widgets' verbatim ports (draw/measure logic).
# Source: androidx-main branch of androidx/androidx (GitHub mirror).
set -uo pipefail
API="https://api.github.com/repos/androidx/androidx/contents/compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3"
RAW="https://raw.githubusercontent.com/androidx/androidx/androidx-main/compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3"
OUT="$(cd "$(dirname "$0")/.." && pwd)/.ref/material3"
mkdir -p "$OUT"
ok=0; fail=0
fetch() { # url dest
  [ -s "$2" ] && { ok=$((ok+1)); return; } # already vendored
  for try in 1 2 3; do
    curl -sf "$1" -o "$2" && { ok=$((ok+1)); return; }
    sleep 1
  done
  echo "FAIL $1"; fail=$((fail+1))
}
# Whole token table + the widget files Klaxon ports.
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
)
for f in "${WIDGETS[@]}"; do fetch "$RAW/$f" "$OUT/$f"; done
fetch "$RAW/pulltorefresh/PullToRefresh.kt" "$OUT/PullToRefresh.kt"
for f in Carousel.kt Keylines.kt KeylineList.kt CarouselState.kt; do
  fetch "$RAW/carousel/$f" "$OUT/carousel-$f"
done
# every token file (the full M3 token table)
curl -sf "$API/tokens?ref=androidx-main" | python3 -c "
import json,sys
for x in json.load(sys.stdin):
    if x['name'].endswith('.kt'): print(x['name'])
" | while read -r f; do fetch "$RAW/tokens/$f" "$OUT/tokens/$f"; done
echo "fetched=$ok failed=$fail"
