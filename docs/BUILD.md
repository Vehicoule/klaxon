# BUILD — build system, `klaxon` CLI, packaging

This document covers how Klaxon is built (the `zig build` monorepo flow and
the dependency model), the `klaxon` CLI (Phase 5a), and how an external
project consumes the framework.

## The `klaxon` CLI

`zig build cli` produces `zig-out/bin/klaxon` — a small launcher binary
(`tools/klaxon/main.zig`) with no SDL/Skia linkage. It shells out to the
project's own build scripts with stdio inherited; child exit codes propagate.

### Commands

| Command | What it runs | Notes |
|---|---|---|
| `klaxon create <name>` | scaffolds `./<name>` | Standalone project, klaxon as a path dependency (see below) |
| `klaxon run [-- args]` | `zig build run -- <args>` | Args after `--` reach the app verbatim |
| `klaxon build` | `zig build -Doptimize=ReleaseSmall` | Extra args go to `zig build` (e.g. `-Dtarget=...`) |
| `klaxon test` | `zig build test` + `zig build test-golden` | Stops at the first failure |
| `klaxon test-golden` | `zig build test-golden` | Klaxon repo only |
| `klaxon bench [scene]` | `zig build bench` (`-Dbench-scene=<scene>`) | Klaxon repo only; extra args go to `zig build` |
| `klaxon package [platform] [args]` | `scripts/package.sh` | Klaxon repo only; `macos|ios|android|web|windows|linux` (default: host) |
| `klaxon doctor` | environment check | Exit 1 when an essential item is missing |
| `klaxon gallery` | `zig build gallery` | Klaxon repo only |
| `klaxon deps` | `scripts/fetch-deps.sh` | Klaxon repo only; idempotent dep bootstrap |

### Project root discovery

Commands that run `zig build` execute in the **project root**: the nearest
parent directory of the cwd containing `build.zig` plus `src/main.zig` (or a
`.klaxon` marker file). `test-golden`, `bench`, `gallery`, `package` and
`deps` additionally require the klaxon repository itself (they map to in-repo
steps/scripts); they refuse with a clear error inside a consumer project.

The **klaxon checkout** is located by `klaxon doctor`/`deps`/`create` in this
order: `$KLAXON_HOME` → the klaxon repo walking up from cwd → the `.klaxon`
marker at the project root → the repo walking up from the executable's
directory. Set `KLAXON_HOME` when the binary lives outside the checkout.

### `klaxon doctor`

Checks and prints an `OK`/`MISSING`/`warn` table with a fix hint per missing
item:

- **Essential** (exit 1 when missing): `zig` 0.17.x, `deps/SDL3`,
  `deps/skia`, `deps/wamr` (mirrors `scripts/check-deps.sh`), and the host
  toolchain — `xcode-select` on macOS, `pkg-config` + `atk-1.0`/`atk-bridge-2.0`
  dev libs on Linux, `vswhere`/MSVC on Windows (best effort).
- **Optional** (warn only): emscripten (`emcc` on PATH or the vendored
  `deps/emsdk`), `ANDROID_SDK_ROOT`/`ANDROID_HOME`, `xcrun simctl` (iOS,
  macOS only).

## Consuming klaxon from an external project

`klaxon create <name>` writes this layout:

```
<name>/
├── build.zig.zon     # .klaxon = .{ .path = "<relative path to klaxon>" }
├── build.zig         # b.dependency("klaxon", ...) → klaxon.artifact("app")
├── .klaxon           # absolute klaxon checkout path (doctor/create lookups)
├── README.md
├── assets/
└── src/main.zig      # the app — imports the framework as @import("klaxon")
```

How it works:

1. The consumer's `build.zig.zon` declares klaxon as a **path dependency**
   (Zig requires the path to be relative; `create` computes it).
2. Its `build.zig` calls `b.dependency("klaxon", .{ .target = …, .optimize =
   …, .@"app-root" = b.root.root_dir.path orelse "." })`.
3. Klaxon's `build.zig` sees `-Dapp-root` and switches to external-app mode:
   the exe root becomes `<app-root>/src/main.zig` (an absolute
   `cwdRelativePath`), the binary registers as the **`app` artifact**, and
   the framework is exposed as the **`klaxon` module** rooted at
   `src/klaxon.zig` — a single module instance so the app and the framework
   share types and globals (input router, timeline, registry).
4. `klaxon.artifact("app")` retrieves it; `b.installArtifact` +
   `b.addRunArtifact` give the consumer `zig build` and `zig build run`.

```zig
// <name>/src/main.zig
const klaxon = @import("klaxon");
const ui = klaxon.ui;
const widgets = klaxon.widgets;
const host_mod = klaxon.host;
// host_mod.Host.init(...), widgets.* factories, ui.state.Signal — see the
// generated file for a working example.
```

### The `deps/` caveat

Klaxon's package `paths` deliberately exclude `deps/` — prebuilt Skia/SDL/WAMR
artifacts are far too large for the package hash. A `.path` dependency builds
straight out of the checkout so `deps/` resolves inside the klaxon package as
usual; `klaxon doctor` (or `klaxon deps`/`scripts/fetch-deps.sh`) inside the
checkout is the bootstrap step. If klaxon is ever consumed as a *fetched*
(URL) dependency, `deps/` will be absent and the fetch step must run in the
cached package — that flow is not supported yet.

## Monorepo build (developing klaxon itself)

| Step | Purpose |
|---|---|
| `zig build` | install all native apps → `zig-out/bin/` |
| `zig build run` | build + run the hello app |
| `zig build gallery` / `navigator` / `i18n` / `a11y` | run the demo apps |
| `zig build test` / `test-golden` | unit tests / golden suite (144 scenes) |
| `zig build bench` | 33-scene benchmark runner (`-Dbench-scene/-Dbench-frames/-Dbench-output`) |
| `zig build conformance` | conformance suite (`conformance/tests/*.json`) |
| `zig build cli` | the `klaxon` CLI → `zig-out/bin/klaxon` |
| `zig build web` | wasm32-emscripten build (`-Dweb-app=hello|gallery`) |
| `zig build android-lib` / `-Dtarget=…-ios` | mobile static libs |
| `zig build package-macos[-dmg]` / `package-linux` | desktop packages → `dist/` |

Cross-cutting options: `-Dtarget`, `-Doptimize`, `-Dapp-root=<dir>` (external
app mode — normally set by a consumer's `build.zig`, not by hand).

## Packaging

`scripts/package.sh [platform] [args]` dispatches to
`scripts/package-{linux,macos,windows,windows-msi,android,ios,web}.sh`; all
artifacts land in `dist/` (the iOS `.app` stays in `zig-out/ios/`). The
platform matrix and its status live in ROADMAP.md §5b.
