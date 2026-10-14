# bench/runners/ios — Klaxon bench suite on iOS simulator

Tier-2 run: the 33-scene catalogue (`src/bench.zig`, schema v2) on a real
iOS surface — Graphite over Metal on the simulator's software Metal.

## Why a separate .app

Android runs the suite inside the gallery APK (`adb shell setprop
debug.klaxon.bench 1` → `SDL_main` calls `bench.runAndroidSuite()`). iOS has
no equivalent launch channel, so the suite is its own .app
(`com.klaxon.bench`):

- `bench_ios_main.zig` exports the four `SDL_MAIN_USE_CALLBACKS` entry
  points that `kx_skia/src/kx_ios_sdl_main.c` anchors — the same surface
  `src/platform_ios.zig` ships for the gallery — but drives the bench
  catalogue instead. One scene runs per `SDL_AppIterate` so the UIKit run
  loop turns between scenes (the bench window's implicit CATransaction
  commits and the CAMetalLayer maps before the paced frames run).
- The report goes to `SDL_GetPrefPath("klaxon","bench")/bench.json` =
  `<data container>/Library/Application Support/klaxon/bench/bench.json`.

## Build/run

    scripts/bench-ios-sim.sh [--backend auto|graphite-metal|raster|...]
                             [--frames N] [--only scene] [--skip a,b]

Outside `build.zig`, so the script does the plumbing itself:

1. `zig build -Dtarget=aarch64-ios.15.0-simulator -Doptimize=ReleaseSmall
   ios-gallery` — for `zig-out/lib/libkx_skia_ios.a` (the ObjC++ shim:
   `kx_skia_common.cpp` + `kx_skia_ios.mm` + `kx_ios_sdl_main.c`) and the
   iOS dep graph (SDL/Skia must be fetched: `scripts/fetch-deps.sh ios`).
2. `zig translate-c` `src/sdl_c.h` + `kx_skia/include/kx_skia.h` for
   `aarch64-ios.15.0-simulator` → `zig-out/ios-bench/gen/{sdl_c,kx_c}.zig`
   (the same products `b.addTranslateC` makes in `zig build`).
3. `zig build-lib` `bench_ios_main.zig` → `zig-out/ios-bench/libkx_ios_bench.a`,
   module wiring: `bench` → `src/bench.zig` (re-pulls the rest of `src/` via
   relative imports), `sdl_c`/`kx_c` → the translate-c outputs.
   `src/ios_io.zig` can't be a module next to `bench` (a file belongs to
   one module — `sdl.zig` is already inside `bench`'s tree), so
   `ios_io.zig` here is a verbatim port of it, wired to `sdl_c` directly.
4. `xcrun clang++` link — the same recipe as build.zig's iOS link step,
   with `libkx_ios_bench.a` standing in for `libgallery.a`.
5. `Bench.app` (`Info.plist` here) → `xcrun simctl install` + `launch`;
   the script polls for `bench.json`, then copies it to
   `bench/results/tier2-ios-<backend>/klaxon/`.

Result naming follows the other tiers: `graphite-metal` →
`tier2-ios-metal`, `ganesh-gles` → `tier2-ios-gles`, `raster` →
`tier2-ios-raster`.

## Known divergences / caveats

- `rss_mb` is always `0.0` — `devtools.readRssMb` (`src/devtools.zig`)
  only handles `.linux`/`.macos`; iOS needs a one-line `switch` arm to the
  mach path (`mach_task_basic_info` works on iOS). src/ change required.
- `simctl launch` returns when the app *launches*, not when it exits; the
  script parses the host pid from its output (`<bundle>: <pid>` — sim apps
  are host processes) and polls the report file + `kill -0`. `launchctl
  list` inside the sim flakes under concurrent `simctl` use, so it is not
  used for liveness.
- First scene (`hello`) can run before the window is fully mapped; its
  presents are dropped — harmless for the work-rate metrics
  (`frame_time_*`, `fps`), but `presented_fps` reads 0 there (it's 0 for
  all fully-static scenes by design — clean frames never touch the
  swapchain).
- Simulator Metal is software-emulated — fps/presented numbers measure the
  translation path, not device GPU throughput (see
  `bench/results/ios-backends-20261011.json` for the matrix context).
