#!/usr/bin/env bash
# size-report.sh — where did the bytes go?
#
# Usage:
#   scripts/size-report.sh <binary> [more binaries...]
#
# Prints, per binary: file size, per-library-family totals (Skia / HarfBuzz /
# FreeType / ICU / zlib / SDL / shim / app), and the top symbols by size — so
# binary-size decisions land on MEASUREMENTS, not guesses.
#
# Motivation (Phase 4e.1, PERF-BUDGETS "Binary size hello < 5 Mo"):
# retail libmain.so measured 8.59 Mo. Graphite + Vulkan stay in the Android
# build (Graphite Vulkan is the planned primary backend on API >= 33,
# Impeller-Vulkan-style), so the remaining bytes must be accounted for before
# any other trim decision:
#
#   scripts/size-report.sh zig-out/lib/libmain.so   # after gradle assemble*
#   scripts/size-report.sh zig-out/bin/hello       # desktop, CI size gate
#
# Tool resolution: $ANDROID_NDK_HOME toolchain llvm-nm first (matches the
# NDK-built libmain.so), then llvm-nm / nm from PATH. Strip AFTER reporting —
# symbol sizes are what the report is about.
set -euo pipefail

die() { echo "size-report: $1" >&2; exit 1; }
[ $# -ge 1 ] || die "usage: scripts/size-report.sh <binary> [more binaries...]"

NM="${KX_SIZE_REPORT_NM:-}"
if [ -z "$NM" ]; then
  if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ]; then
    candidate="$(find "$ANDROID_NDK_HOME" -type f -name llvm-nm | head -1)"
    [ -n "$candidate" ] && NM="$candidate"
  fi
fi
if [ -z "$NM" ]; then
  for c in llvm-nm nm; do
    command -v "$c" >/dev/null 2>&1 && { NM="$c"; break; }
  done
fi
[ -n "$NM" ] || die "no nm tool found (install one, or set KX_SIZE_REPORT_NM=/path/to/llvm-nm)"

# Family buckets by symbol prefix (works on both mangled C++ and C names —
# mangled C++ names embed the class/namespace token, e.g. _ZN2Sk..., so the
# prefix families are recognizable without demangling).
family_of() {
  local n="$1"
  case "$n" in
    *Sk*|*skgpu*|*skia*|*Gr[A-Z]*|*SkSL*|*skresource*|*skgraphite*) echo "skia" ;;
    *hb*|*HB_*|*harfbuzz*)                                        echo "harfbuzz" ;;
    *FT_*|*cff_*|*tt_*|*ot_*|*sfnt*|*freetype*)                    echo "freetype" ;;
    *u_*|*icu*|*ures*|*ucol*|*ubrk*)                                echo "icu" ;;
    *png*|*zlib*|*inflate*|*deflate*|*crc32*)                       echo "png-zlib" ;;
    *SDL*|*SDL_*)                                                   echo "sdl" ;;
    *kx*)                                                           echo "kx-shim" ;;
    *)                                                              echo "app+other" ;;
  esac
}

for bin in "$@"; do
  [ -f "$bin" ] || die "not a file: $bin"
  echo "================================================================"
  echo "size-report: $bin"
  echo "================================================================"
  # wc -c resolves symlinks (ls -la would report the link's own size).
  size_bytes="$(wc -c < "$bin" | tr -d ' ')"
  awk -v b="$size_bytes" 'BEGIN{printf "  file size   : %d bytes (%.2f MiB)\n", b, b/1048576}'
  echo
  # nm --print-size --size-sort: "addr size type name" per line (type first
  # letter uppercase = defined). Extract once; detect the two unusable cases:
  # a stripped release binary has no symbols at all, and some nm builds (macOS
  # system nm on Mach-O) report symbols but no sizes — both would otherwise
  # print empty/all-zero reports with no explanation.
  sym_list="$("$NM" --print-size --size-sort --radix=d "$bin" 2>/dev/null \
    | awk '$3 ~ /^[A-Z]/ && $2+0 > 0 { print $2, $4 }')"
  if [ -z "$sym_list" ]; then
    echo "  (no sized symbols — the binary looks stripped, or this nm reports"
    echo "   no sizes for its format (e.g. macOS nm on Mach-O). The breakdown"
    echo "   needs the UNSTRIPPED build read by llvm-nm: zig-out/lib/libmain.so"
    echo "   before install-strip, or set KX_SIZE_REPORT_NM to llvm-nm. The file"
    echo "   size above is the post-strip budget number and stays valid.)"
    echo
    continue
  fi
  echo "--- per-library-family total (defined symbols) ---"
  # Bucket by family, sum sizes, sort desc.
  echo "$sym_list" \
    | while read -r sz name; do echo "$(family_of "$name") $sz"; done \
    | awk '{
        total[$1] += $2; count[$1] += 1;
      }
      END {
        for (f in total) printf "%12d bytes  %6d symbols  %s\n", total[f], count[f], f;
      }' | sort -rn
  echo
  echo "--- top 25 symbols by size ---"
  echo "$sym_list" | awk '{ printf "%10d bytes  %s\n", $1, $2 }' | tail -25
  echo
done
