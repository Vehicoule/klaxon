# Contributing to Klaxon

## Prerequisites

- **Zig 0.17.0** (pinned — other versions will fail on API drift).
  `brew install zig@0.17` or grab the exact tarball from ziglang.org.
- Native deps (Skia, SDL3, WAMR) live in `deps/` — they are NOT vendored:

```bash
scripts/fetch-deps.sh          # everything (~20-45 min first time)
scripts/fetch-deps.sh --help   # per-platform tags if you only need one
scripts/check-deps.sh          # quick sanity check of what's missing
```

## Build & run

```bash
zig build run            # hello-world (raster/GPU per host)
zig build gallery        # widget gallery
zig build navigator      # navigation demo
zig build i18n           # i18n demo (en/fr/ja/ar)
zig build a11y           # a11y demo
zig build web            # wasm bundle (needs fetch-deps web-wasm + emscripten)
zig build ios-gallery    # iOS static lib + .app
```

## Tests

```bash
zig build test           # everything (unit + widget)
zig build test-golden    # golden raster tests (custom runner, name-filtered)
```

Widget/golden tests live inside their module files (`src/widgets/*.zig`),
pulled in via `refAllDecls` — Zig 0.17's compile-time `--test-filter` only
matches root-module tests, so prefer `zig build test` over `--test-filter`.

## Benchmarks

```bash
zig build bench                          # all scenes, JSON to stdout
zig build bench -Dbench-scene=list_create_1k
zig build bench -Dbench-output=out.json  # also write JSON to a file
scripts/bench.sh                         # full suite + report
scripts/bench-report.py                  # regenerate bench/report.html
```

Scene semantics are contractual — `docs/specs/bench-scenes.md`. All four
runners (Klaxon / Flutter / Compose / Qt) must produce comparable numbers.

## Style

- `zig fmt` on touched files before pushing.
- Zero allocations per frame in paint paths; owned memory is freed in the
  vtable `deinit`. OOM is `catch @panic("klaxon: out of memory")` — never
  `catch {}`.
- Public C ABI changes are additive only — see `docs/adr/ADR-0009-c-abi-contract.md`.
- Widget API convention: `widget(allocator, data…, signal?, callbacks…, opts)` —
  `opts` last.
- Pointer events: `.move` only reaches a *captured* node. Plain hover is
  `.enter`/`.leave`/`.hover_move` — see `src/ui/input.zig` header.
- Touch targets honor the 48dp floor via `hit_bounds` when bounds are smaller.

## Layout of the tree

```
src/            framework (ui core, widgets, platform shims, host)
kx_skia/        C++ renderer shim (Skia + SDL) — the C ABI surface
web/            wasm JS libraries (a11y bridge, loaders)
bench/          benchmark results + report + foreign runners
scripts/        fetch-deps, packaging, bench, size-report
docs/           architecture, roadmap, specs, ADRs
```

## CI

`.github/workflows/ci.yml` — fmt + test + golden + bench-smoke on macOS and
Linux, plus android/ios/wasm build gates. A PR merges only when all jobs
are green and Devin review threads are resolved.
