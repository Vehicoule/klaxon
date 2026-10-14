material-color-utilities (material-foundation)
commit 5b3618b16fdc3825e21d5679bafd144662088ea1 (2026-08-21)
https://github.com/material-foundation/material-color-utilities
Vendored: cpp/ subtree only (+ LICENSE). Apache-2.0.

Vendor patches (re-apply on re-vendoring):
- cpp/quantize/wsmeans.cc: absl::flat_hash_map -> std::unordered_map
- cpp/utils/utils.cc: absl::StrCat+absl::Hex -> snprintf (HexFromArgb)
Rationale: absl is not vendored; upstream's only two non-test absl
touchpoints are trivially replaceable. Without the patch the includes
silently resolve to an ambient absl install (e.g. Homebrew) — a
non-reproducible link failure. *_test.cc files keep their gtest includes
and are never compiled (see mcu_sources in build.zig).
