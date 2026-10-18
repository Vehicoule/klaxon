// Klaxon — build script (Phase 0.2/0.3).
// Builds the kx_skia C++/ObjC++ shim, links Skia + SDL3 (static, from deps/),
// and builds the hello app. The deps tag must match scripts/fetch-deps.sh.
const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // On Windows the native default resolves to x86_64-windows-gnu (mingw
    // ABI), whose libmingw32 CRT collides with the /MT MSVC objects our
    // shims produce. Default to the MSVC ABI — libcmt's real crt0 then
    // provides the entry point and runs the CRT init chain (heap, TLS,
    // static ctors). Mirrors the platform/windows spike link recipe.
    const target = b.standardTargetOptions(.{
        .default_target = if (builtin.os.tag == .windows)
            .{ .cpu_arch = builtin.cpu.arch, .os_tag = .windows, .abi = .msvc }
        else
            .{},
    });
    // Default ReleaseFast: the interactive demos (gallery, navigator, …) are
    // what people run — a Debug build makes a theme rebuild ~450ms instead of
    // ~1.5ms and misrepresents the framework. -Doptimize=Debug still works.
    // NOTE: not standardOptimizeOption(.preferred_optimize_mode) — Zig 0.17
    // replaces the -Doptimize flag with -Drelease entirely when a preferred
    // mode is set, so every -Doptimize=<mode> script silently builds Debug.
    const optimize: std.builtin.OptimizeMode = blk: {
        if (b.option([]const u8, "optimize", "Prioritize performance, safety, or binary size (default: fast)")) |s| {
            if (std.meta.stringToEnum(std.builtin.OptimizeMode, s)) |m| break :blk m;
            // Zig 0.17 renamed the enum members (ReleaseSmall -> small); keep
            // the legacy spellings working for packaging scripts and CI.
            const legacy = std.StaticStringMap(std.builtin.OptimizeMode).initComptime(.{
                .{ "Debug", .debug },
                .{ "ReleaseSafe", .safe },
                .{ "ReleaseFast", .fast },
                .{ "ReleaseSmall", .small },
            });
            break :blk legacy.get(s) orelse
                @panic("unknown -Doptimize value (expected debug|safe|fast|small)");
        }
        break :blk switch (b.graph.release_mode) {
            .off, .any, .fast => .fast,
            .safe => .safe,
            .small => .small,
        };
    };

    // Phase 3f: wasm32-emscripten web target (docs/specs/phase-3f-wasm-plan.md).
    const is_wasm = target.result.os.tag == .emscripten;
    // Phase 3d: Android target (aarch64-linux-android).
    const is_android = target.result.os.tag == .linux and target.result.abi == .android;
    // Phase 3e: iOS target (aarch64-ios.15.0 / aarch64-ios.15.0-simulator).
    const is_ios = target.result.os.tag == .ios;

    // Deps tag — must match the TAG logic in scripts/fetch-deps.sh.
    const tag: []const u8 = if (is_wasm)
        "web-wasm" // emsdk + Skia out/web-wasm + SDL build-web-wasm
    else if (is_android)
        "android-arm64" // Skia out/android-arm64 + SDL build-android-arm64 (CMake/NDK)
    else if (is_ios)
        if (target.result.abi == .simulator) "ios-sim-arm64" else "ios-arm64"
    else switch (target.result.os.tag) {
        .macos => "macos-arm64", // arm64 only, no x64
        .linux => if (target.result.cpu.arch == .x86_64) "linux-x64" else "linux-arm64",
        .windows => if (target.result.cpu.arch == .x86_64) "windows-x64" else "windows-arm64",
        else => @panic("unsupported target OS (see scripts/fetch-deps.sh)"),
    };
    const is_macos = target.result.os.tag == .macos;

    // --- external app mode (Phase 5a) ---
    // `klaxon create`d projects depend on klaxon and pass -Dapp-root=<their
    // root>: the app's src/main.zig is compiled here as the "app" artifact,
    // with the framework exposed as the "klaxon" module (@import("klaxon")).
    // Declared before the wasm/android/ios early returns so external projects
    // can also target web/mobile without "invalid option: -Dapp-root".
    const app_root_opt = b.option([]const u8, "app-root", "external project root — builds <app-root>/src/main.zig as the 'app' artifact");

    // The wasm target gets its own build graph (static lib + emcc link step);
    // the native steps (run/test/test-golden/gallery/...) are not defined for it.
    if (is_wasm) {
        addWasmWeb(b, target, optimize, tag, app_root_opt);
        return;
    }

    // Phase 3d/3e: android + ios get their own build graphs (static lib +
    // external link step); the native steps are not defined for them.
    if (is_android) {
        addAndroidLib(b, target, optimize, tag, app_root_opt);
        return;
    }
    if (is_ios) {
        addIosApp(b, target, optimize, tag, app_root_opt);
        return;
    }

    // -Dsanitize: instrument the kx_skia C/C++ shim with clang
    // -fsanitize=address,undefined. Declared after the wasm/android/ios
    // early returns — those graphs reject the flag (emscripten's
    // compiler_rt lacks the symbols; the wasm shim set carries its own
    // -fno-sanitize). Zig ships no ASan runtime (compiler-rt has ubsan_rt
    // + libtsan only), so sanitizerRuntime() locates an external
    // libclang_rt/libasan to link into every artifact; zig's bundled
    // ubsan_rt covers -fsanitize=undefined automatically.
    const sanitize = b.option(bool, "sanitize", "Instrument the kx_skia C/C++ shim with -fsanitize=address,undefined (native linux/macOS only)") orelse false;
    const san_rt: ?SanitizerRuntime = if (sanitize) sanitizerRuntime(b, target) else null;

    // --- kx_skia shim (C++ / ObjC++ static lib) ---
    const kx_skia = addKxSkia(b, target, optimize, "kx_skia", is_macos, sanitize);

    // C bindings: SDL3 (sdl_c) + kx_skia (kx_c) via zig translate-c
    // (Zig 0.17 removed @cImport — b.addTranslateC is the replacement).
    const translate_sdl = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl_c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_sdl.addIncludePath(b.path("deps/SDL/include"));

    const translate_kx = b.addTranslateC(.{
        .root_source_file = b.path("kx_skia/include/kx_skia.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Windows: skparagraph's ICU needs icudtl.dat next to the exe at runtime
    // (staged by fetch-deps into the Skia out dir).
    if (target.result.os.tag == .windows) {
        const dat = b.fmt("deps/skia/out/{s}/icudtl.dat", .{tag});
        b.getInstallStep().dependOn(&b.addInstallFile(b.path(dat), "bin/icudtl.dat").step);
    }

    if (app_root_opt) |app_root| {
        addExternalApp(b, target, optimize, translate_sdl, translate_kx, kx_skia, is_macos, tag, app_root, san_rt);
        return;
    }

    // --- hello app ---
    const exe = addApp(b, target, optimize, "hello", "src/main.zig", translate_sdl, translate_kx, kx_skia, is_macos, tag, san_rt);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Build and run the hello app");
    run_step.dependOn(&run.step);

    // --- gallery app (Phase 1g) ---
    const gallery_exe = addApp(b, target, optimize, "gallery", "src/gallery_main.zig", translate_sdl, translate_kx, kx_skia, is_macos, tag, san_rt);
    b.installArtifact(gallery_exe);

    const run_gallery = b.addRunArtifact(gallery_exe);
    run_gallery.step.dependOn(b.getInstallStep());
    const gallery_step = b.step("gallery", "Build and run the gallery app");
    gallery_step.dependOn(&run_gallery.step);

    // --- navigator demo app (Phase 2a) ---
    const nav_exe = addApp(b, target, optimize, "navigator", "src/navigator_main.zig", translate_sdl, translate_kx, kx_skia, is_macos, tag, san_rt);
    b.installArtifact(nav_exe);

    const run_nav = b.addRunArtifact(nav_exe);
    run_nav.step.dependOn(b.getInstallStep());
    const nav_step = b.step("navigator", "Build and run the navigator demo app");
    nav_step.dependOn(&run_nav.step);

    // --- i18n demo app (Phase 2b) ---
    const i18n_exe = addApp(b, target, optimize, "i18n", "src/i18n_main.zig", translate_sdl, translate_kx, kx_skia, is_macos, tag, san_rt);
    b.installArtifact(i18n_exe);

    const run_i18n = b.addRunArtifact(i18n_exe);
    run_i18n.step.dependOn(b.getInstallStep());
    const i18n_step = b.step("i18n", "Build and run the i18n demo app");
    i18n_step.dependOn(&run_i18n.step);

    // --- a11y demo app (Phase 2c) ---
    const a11y_exe = addApp(b, target, optimize, "a11y", "src/a11y_main.zig", translate_sdl, translate_kx, kx_skia, is_macos, tag, san_rt);
    b.installArtifact(a11y_exe);

    const run_a11y = b.addRunArtifact(a11y_exe);
    run_a11y.step.dependOn(b.getInstallStep());
    const a11y_step = b.step("a11y", "Build and run the a11y demo app");
    a11y_step.dependOn(&run_a11y.step);

    // --- bench runner (Phase 4c.3) ---
    // Benchmark runner: the 33-scene catalogue, metrics, JSON report to stdout.
    // Always ReleaseSmall — benchmarks must measure the shipping binary
    // (docs/PERF-BUDGETS.md), whatever -Doptimize the user passes. The bench
    // graph gets its OWN ReleaseSmall kx_skia shim: the shared shim is built
    // at the user's optimize (Debug → ubsan-instrumented), which neither links
    // into a ReleaseSmall exe nor measures realistic performance.
    const bench_frames = b.option(u32, "bench-frames", "Benchmark frames per scene (default 600)") orelse 600;
    const bench_scene = b.option([]const u8, "bench-scene", "Run a single scene by name (default: all scenes)") orelse null;
    const bench_output = b.option([]const u8, "bench-output", "Also write the JSON report to this file") orelse null;
    const bench_options = b.addOptions();
    bench_options.addOption(u32, "bench_frames", bench_frames);
    bench_options.addOption(?[]const u8, "bench_scene", bench_scene);
    bench_options.addOption(?[]const u8, "bench_output", bench_output);
    // Installed runner path (zig-out/bin/bench) — the runner stats it for the
    // report's binary_size_bytes. The run step depends on the install step,
    // so the file is in place before the runner executes.
    bench_options.addOption([]const u8, "bench_exe_path", "zig-out/bin/bench");

    const kx_skia_bench = addKxSkia(b, target, .ReleaseSmall, "kx_skia_bench", is_macos, false);
    const bench_opt = b.option(std.builtin.OptimizeMode, "bench-optimize", "bench executable optimize mode (default ReleaseSmall)") orelse .small;
    // The bench shim is never sanitized (false above — instrumentation
    // would skew metrics), so the exe doesn't need the sanitizer runtime.
    const bench_exe = addApp(b, target, bench_opt, "bench", "src/bench_main.zig", translate_sdl, translate_kx, kx_skia_bench, is_macos, tag, null);
    bench_exe.root_module.addOptions("build_options", bench_options);
    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(b.getInstallStep());
    const bench_step = b.step("bench", "Run benchmarks: 33 scenes, JSON metrics to stdout (-Dbench-frames=N -Dbench-scene=NAME -Dbench-output=PATH)");
    bench_step.dependOn(&run_bench.step);

    // --- conformance suite (Phase 4c.7) ---
    // Runs conformance/tests/*.json against the real widget tree headlessly
    // (raster backend), writes conformance/results-<ts>.json + a summary.
    const conf_exe = addApp(b, target, optimize, "conformance", "src/conformance_main.zig", translate_sdl, translate_kx, kx_skia, is_macos, tag, san_rt);
    b.installArtifact(conf_exe);

    const run_conf = b.addRunArtifact(conf_exe);
    run_conf.step.dependOn(b.getInstallStep());
    const conf_step = b.step("conformance", "Run the conformance suite (conformance/tests/*.json)");
    conf_step.dependOn(&run_conf.step);

    // --- pixel-fidelity harness ---
    // Renders fidelity/scenes.json through the real widget tree (headless
    // raster), writing fidelity/out/klaxon/<scene>.ppm + JSON sidecars for
    // tools/fidelity_diff.py to compare with the Compose runner's frames.
    const fid_exe = addApp(b, target, optimize, "fidelity", "src/fidelity_main.zig", translate_sdl, translate_kx, kx_skia, is_macos, tag, san_rt);
    b.installArtifact(fid_exe);

    const run_fid = b.addRunArtifact(fid_exe);
    run_fid.step.dependOn(b.getInstallStep());
    run_fid.addPassthruArgs(); // zig build fidelity -- --scene=<substr>
    const fid_step = b.step("fidelity", "Render fidelity scenes (fidelity/out/klaxon/*.ppm)");
    fid_step.dependOn(&run_fid.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = !is_windows_local(target),
        }),
    });
    tests.root_module.addImport("sdl_c", translate_sdl.createModule());
    tests.root_module.addImport("kx_c", translate_kx.createModule());
    // Golden tests render through the shim: the test exe links the same runtime.
    linkRuntime(b, tests.root_module, kx_skia, target, is_macos, tag, san_rt);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Golden tests only. The 0.17 compile-time --test-filter only matches
    // tests declared in the ROOT module, and this repo's tests live in the
    // widget modules (pulled in via refAllDecls) — so the golden suite uses
    // a custom test runner that filters by test name at runtime.
    const golden_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = !is_windows_local(target),
        }),
        .test_runner = .{ .path = b.path("src/test_runner_golden.zig"), .mode = .simple },
    });
    golden_tests.root_module.addImport("sdl_c", translate_sdl.createModule());
    golden_tests.root_module.addImport("kx_c", translate_kx.createModule());
    linkRuntime(b, golden_tests.root_module, kx_skia, target, is_macos, tag, san_rt);
    const run_golden = b.addRunArtifact(golden_tests);
    const golden_step = b.step("test-golden", "Run golden tests only");
    golden_step.dependOn(&run_golden.step);

    // --- fuzz harnesses (test-only, src/fuzz/) ---
    // `zig build fuzz` runs the embedded corpus once as normal unit tests.
    // `zig build fuzz -Dfuzz-target=X --fuzz=<runs>` makes the build runner
    // rebuild the target's test exe with -ffuzz and drive it for <runs>
    // executions (scripts/fuzz.sh wraps this with a seconds bound).
    // Harnesses always build Debug — ReleaseFast would strip the bounds
    // checks these targets exist to trip.
    const fuzz_target = b.option([]const u8, "fuzz-target", "Fuzz target: text_edit|tree_json|arb|input|all (default: all)") orelse "all";
    const fuzz_step = b.step("fuzz", "Build and run fuzz harnesses (use -Dfuzz-target=X, --fuzz=<runs>)");
    // One klaxon module instance shared by the harness roots — the same
    // pattern addExternalApp uses so all file-relative imports inside src/
    // resolve to a single set of types + process globals (router, timeline).
    const fuzz_klaxon = b.createModule(.{
        .root_source_file = b.path("src/klaxon.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
        .link_libcpp = !is_windows_local(target),
    });
    fuzz_klaxon.addImport("sdl_c", translate_sdl.createModule());
    fuzz_klaxon.addImport("kx_c", translate_kx.createModule());
    const fuzz_targets = [_][]const u8{ "text_edit", "tree_json", "arb", "input" };
    var fuzz_any = false;
    for (fuzz_targets) |t| {
        if (!std.mem.eql(u8, fuzz_target, "all") and !std.mem.eql(u8, fuzz_target, t)) continue;
        fuzz_any = true;
        const fuzz_tests = b.addTest(.{
            .name = b.fmt("fuzz-{s}", .{t}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/fuzz/fuzz_{s}.zig", .{t})),
                .target = target,
                .optimize = .Debug,
                .link_libc = true,
                .link_libcpp = !is_windows_local(target),
            }),
        });
        fuzz_tests.root_module.addImport("klaxon", fuzz_klaxon);
        linkRuntime(b, fuzz_tests.root_module, kx_skia, target, is_macos, tag, san_rt);
        const run_fuzz = b.addRunArtifact(fuzz_tests);
        fuzz_step.dependOn(&run_fuzz.step);
    }
    if (!fuzz_any)
        @panic("unknown -Dfuzz-target (expected text_edit|tree_json|arb|input|all)");

    // --- dynamic color tests (deps/mcu) ---
    // src/dynamic_color.zig is deliberately self-contained (std only — it
    // cannot import theme.zig without dragging the kx_c module into a bare
    // `zig test`), so it needs its own test step rather than riding the
    // main.zig-rooted suite. linkRuntime supplies libkx_skia.a, which now
    // archives the mcu objects; the linker pulls only kx_mcu.cpp's TU.
    const dc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dynamic_color.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = !is_windows_local(target),
        }),
    });
    linkRuntime(b, dc_tests.root_module, kx_skia, target, is_macos, tag, san_rt);
    const run_dc_tests = b.addRunArtifact(dc_tests);
    const dc_test_step = b.step("test-dynamic-color", "Run dynamic-color (material-color-utilities) tests");
    dc_test_step.dependOn(&run_dc_tests.step);

    // --- klaxon CLI (Phase 5a) ---
    // The `klaxon` launcher — a plain Zig exe, no SDL/skia linkage.
    const cli = b.addExecutable(.{
        .name = "klaxon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/klaxon/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const cli_step = b.step("cli", "Build the klaxon CLI (zig-out/bin/klaxon)");
    cli_step.dependOn(&b.addInstallArtifact(cli, .{}).step);

    // --- package-macos: build + bundle a .app (macOS only) ---
    if (is_macos) {
        const pkg = b.addSystemCommand(&.{ "scripts/package-macos.sh", "gallery", "./dist" });
        pkg.step.dependOn(b.getInstallStep());
        const pkg_step = b.step("package-macos", "Build + package gallery into a .app bundle (macOS)");
        pkg_step.dependOn(&pkg.step);

        // --- package-macos-dmg: same + drag-and-drop .dmg (Phase 3b.3) ---
        const pkg_dmg = b.addSystemCommand(&.{ "scripts/package-macos.sh", "gallery", "./dist", "--dmg" });
        pkg_dmg.step.dependOn(b.getInstallStep());
        const pkg_dmg_step = b.step("package-macos-dmg", "Build + package gallery into a .dmg (macOS)");
        pkg_dmg_step.dependOn(&pkg_dmg.step);
    }

    // --- package-linux: build + package gallery for Linux (Phase 3a.2/5b) ---
    // The script produces all four formats (AppImage/.deb/.rpm/Flatpak
    // manifest) under ./dist; android/ios return above before reaching this.
    if (target.result.os.tag == .linux) {
        const linux_arch: []const u8 = if (target.result.cpu.arch == .x86_64) "x64" else "arm64";
        const pkg = b.addSystemCommand(&.{ "scripts/package-linux.sh", "gallery", linux_arch });
        pkg.step.dependOn(b.getInstallStep());
        const pkg_step = b.step("package-linux", "Build + package gallery for Linux (AppImage, deb, rpm, Flatpak)");
        pkg_step.dependOn(&pkg.step);
    }
}

/// Phase 5a external-app mode (klaxon-as-a-dependency): the consumer project's
/// src/main.zig is the exe root; the framework is one "klaxon" module rooted
/// at src/klaxon.zig — a single module instance, so every file-relative import
/// inside src/ resolves into the same compilation (no split globals/types).
/// The binary registers as "app" — retrievable via dependency.artifact("app").
fn addExternalApp(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    translate_sdl: *std.Build.Step.TranslateC,
    translate_kx: *std.Build.Step.TranslateC,
    kx_skia: *std.Build.Step.Compile,
    is_macos: bool,
    tag: []const u8,
    app_root: []const u8,
    san_rt: ?SanitizerRuntime,
) void {
    const klaxon_mod = b.createModule(.{
        .root_source_file = b.path("src/klaxon.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = !is_windows_local(target),
    });
    klaxon_mod.addImport("sdl_c", translate_sdl.createModule());
    klaxon_mod.addImport("kx_c", translate_kx.createModule());

    const app = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            // Absolute consumer path — outside this package's build root.
            .root_source_file = b.graph.cwdRelativePath(b.fmt("{s}/src/main.zig", .{app_root})),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = !is_windows_local(target),
        }),
    });
    app.root_module.addImport("klaxon", klaxon_mod);
    linkRuntime(b, app.root_module, kx_skia, target, is_macos, tag, san_rt);
    b.installArtifact(app);

    const app_tests = b.addTest(.{
        .name = "app-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.graph.cwdRelativePath(b.fmt("{s}/src/main.zig", .{app_root})),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = !is_windows_local(target),
        }),
    });
    app_tests.root_module.addImport("klaxon", klaxon_mod);
    linkRuntime(b, app_tests.root_module, kx_skia, target, is_macos, tag, san_rt);
    b.installArtifact(app_tests);
    const run_tests = b.addRunArtifact(app_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const app_golden = b.addTest(.{
        .name = "app-golden",
        .root_module = b.createModule(.{
            .root_source_file = b.graph.cwdRelativePath(b.fmt("{s}/src/main.zig", .{app_root})),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = !is_windows_local(target),
        }),
        .test_runner = .{ .path = b.path("src/test_runner_golden.zig"), .mode = .simple },
    });
    app_golden.root_module.addImport("klaxon", klaxon_mod);
    linkRuntime(b, app_golden.root_module, kx_skia, target, is_macos, tag, san_rt);
    b.installArtifact(app_golden);
    const run_golden = b.addRunArtifact(app_golden);
    const golden_step = b.step("test-golden", "Run golden tests only");
    golden_step.dependOn(&run_golden.step);
}

/// material-color-utilities (deps/mcu, vendored Apache-2.0 — UPSTREAM.md
/// pins the upstream commit): dynamic color — HCT, tonal palettes, M3E schemes,
/// Celebi/Wu quantize + Score ranking. Pure-stdlib C++, no Skia/SDL headers;
/// deps/mcu/kx_mcu.cpp is the extern "C" POD seam (see kx_mcu.h). Upstream
/// *_test.cc files are vendored but never compiled.
const mcu_sources = [_][]const u8{
    "deps/mcu/kx_mcu.cpp",
    "deps/mcu/cpp/blend/blend.cc",
    "deps/mcu/cpp/cam/cam.cc",
    "deps/mcu/cpp/cam/hct.cc",
    "deps/mcu/cpp/cam/hct_solver.cc",
    "deps/mcu/cpp/cam/viewing_conditions.cc",
    "deps/mcu/cpp/contrast/contrast.cc",
    "deps/mcu/cpp/dislike/dislike.cc",
    "deps/mcu/cpp/dynamiccolor/dynamic_color.cc",
    "deps/mcu/cpp/dynamiccolor/dynamic_scheme.cc",
    "deps/mcu/cpp/dynamiccolor/material_dynamic_colors.cc",
    "deps/mcu/cpp/palettes/tones.cc",
    "deps/mcu/cpp/quantize/celebi.cc",
    "deps/mcu/cpp/quantize/lab.cc",
    "deps/mcu/cpp/quantize/wsmeans.cc",
    "deps/mcu/cpp/quantize/wu.cc",
    "deps/mcu/cpp/scheme/scheme_content.cc",
    "deps/mcu/cpp/scheme/scheme_expressive.cc",
    "deps/mcu/cpp/scheme/scheme_fidelity.cc",
    "deps/mcu/cpp/scheme/scheme_fruit_salad.cc",
    "deps/mcu/cpp/scheme/scheme_monochrome.cc",
    "deps/mcu/cpp/scheme/scheme_neutral.cc",
    "deps/mcu/cpp/scheme/scheme_rainbow.cc",
    "deps/mcu/cpp/scheme/scheme_tonal_spot.cc",
    "deps/mcu/cpp/scheme/scheme_vibrant.cc",
    "deps/mcu/cpp/score/score.cc",
    "deps/mcu/cpp/temperature/temperature_cache.cc",
    "deps/mcu/cpp/utils/utils.cc",
};

/// Create the kx_skia C++/ObjC++ shim as a static library. The native graph
/// builds it twice: at the user's optimize (hello/gallery/tests) and at
/// ReleaseSmall for the bench runner — the shim must match the bench binary's
/// optimization (a Debug shim is ubsan-instrumented: it fails to link into a
/// ReleaseSmall exe, and would skew the metrics anyway).
fn addKxSkia(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    is_macos: bool,
    sanitize: bool,
) *std.Build.Step.Compile {
    const kx_skia = b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = !is_windows_local(target),
        }),
    });
    const shim_flags_base = &[_][]const u8{
        "-std=c++20",             "-fno-exceptions", "-fno-rtti",
        "-DSK_GANESH",            "-DSK_GRAPHITE",   "-DNDEBUG",
        // Match the vendored libicu.a: Skia builds ICU with symbol
        // renaming off, so ubrk_* links unsuffixed.
        "-DU_DISABLE_RENAMING=1",
    };
    // -Dsanitize: clang ASan + UBSan on the shim TUs. UBSan links out of
    // the box (zig bundles ubsan_rt); ASan objects get their runtime from
    // sanitizerRuntime(), attached in linkRuntime.
    const shim_flags: []const []const u8 = if (sanitize)
        shim_flags_base ++ &[_][]const u8{"-fsanitize=address,undefined"}
    else
        shim_flags_base;
    // On Windows, kx_skia_common.cpp goes through compileMsvcShims instead
    // (MSVC STL ABI — see the .windows case below).
    if (target.result.os.tag != .windows) {
        kx_skia.root_module.addCSourceFiles(.{
            .files = &.{"kx_skia/src/kx_skia_common.cpp"},
            .flags = shim_flags,
            .language = .cpp,
        });
    }
    switch (target.result.os.tag) {
        .macos => {
            kx_skia.root_module.addCSourceFiles(.{
                .files = &.{"kx_skia/src/kx_skia_macos.mm"},
                .flags = shim_flags,
                .language = .objective_cpp,
            });
            kx_skia.root_module.addCSourceFiles(.{
                .files = &.{"kx_skia/src/kx_a11y_macos.mm"},
                .flags = shim_flags,
                .language = .objective_cpp,
            });
            if (sanitize) {
                // Upstream clang emits __asan_version_mismatch_check_v8
                // into each instrumented TU; Apple's asan dylib exports a
                // differently-versioned name instead — satisfy it with a
                // no-op (the check only compares instrumenter/runtime
                // versions, and both are clang 21-era ABI v8).
                const stub = b.addWriteFiles().add("kx_asan_abi_stub.cpp",
                    \\extern "C" void __asan_version_mismatch_check_v8(void) {}
                    \\
                );
                kx_skia.root_module.addCSourceFile(.{
                    .file = stub,
                    .flags = &.{"-std=c++20"},
                    .language = .cpp,
                });
            }
        },
        .linux => {
            kx_skia.root_module.addCSourceFiles(.{
                .files = &.{
                    "kx_skia/src/kx_skia_linux.cpp",
                    // Phase 3a: the AT-SPI2 a11y bridge — an AtkObject tree
                    // bridged onto the a11y D-Bus by the stock at-spi2-atk
                    // adaptor (see the file header for the design choice).
                    "kx_skia/src/kx_a11y_linux.cpp",
                },
                .flags = shim_flags,
                .language = .cpp,
            });
            // libatk + libatk-bridge: pkg-config supplies the include dirs
            // (atk/atk.h, atk-bridge.h) and libs — CI installs libatk1.0-dev +
            // libatk-bridge2.0-dev (pulls libatspi2.0-dev transitively).
            // glib/gobject: the bridge calls g_* directly (main context,
            // idle marshal, GObject lifecycle) — not just via libatk.
            kx_skia.root_module.linkSystemLibrary("atk-1.0", .{});
            kx_skia.root_module.linkSystemLibrary("atk-bridge-2.0", .{});
            kx_skia.root_module.linkSystemLibrary("gobject-2.0", .{});
            kx_skia.root_module.linkSystemLibrary("glib-2.0", .{});
            // <vulkan/vulkan.h> comes from Skia's vendored copy — the shim
            // loads libvulkan at runtime via SDL_Vulkan_LoadLibrary, so no
            // SDK or loader link is needed to build it.
            kx_skia.root_module.addIncludePath(b.path("deps/skia/include/third_party/vulkan"));
        },
        .windows => {
            // Compiled with MSVC cl.exe (not zig's clang): Skia/Dawn are
            // built with MSVC and their headers exchange STL types
            // (std::vector<Adapter>, wgpu::StringView) — a zig-libc++ shim
            // would ABI-mismatch. Objects come from compileMsvcShims and are
            // archived into libkx_skia like the other platforms' objects.
            // mcu sources go through cl.exe there too (std::map/vector/...
            // instantiate the MSVC STL; they must not pick up zig's libc++).
            const objects = compileMsvcShims(b, target);
            for (objects) |obj| kx_skia.root_module.addObjectFile(obj);
        },
        else => @panic("no kx_skia platform impl for this OS yet (add kx_skia/src/kx_skia_<os>)"),
    }
    // material-color-utilities: compile into the shim lib on every platform
    // the zig clang driver builds (all but Windows — see above). deps/mcu is
    // the include root: the sources include "cpp/<dir>/<file>.h".
    if (target.result.os.tag != .windows) {
        kx_skia.root_module.addCSourceFiles(.{
            .files = &mcu_sources,
            .flags = shim_flags,
            .language = .cpp,
        });
        kx_skia.root_module.addIncludePath(b.path("deps/mcu"));
    }
    kx_skia.root_module.addIncludePath(b.path("kx_skia/include"));
    kx_skia.root_module.addIncludePath(b.path("deps/skia"));
    kx_skia.root_module.addIncludePath(b.path("deps/skia/include"));
    // ICU common headers (ubrk.h — grapheme-cluster boundaries) — the same
    // path SkUnicode_icu compiles against; libicu.a is already linked.
    kx_skia.root_module.addIncludePath(b.path("deps/skia/third_party/externals/icu/source/common"));
    kx_skia.root_module.addIncludePath(b.path("deps/SDL/include"));
    if (is_macos) {
        inline for (.{ "Metal", "QuartzCore", "Foundation", "CoreGraphics", "CoreText", "CoreFoundation", "IOSurface" }) |fw| {
            kx_skia.root_module.linkFramework(fw, .{});
        }
    }
    return kx_skia;
}

/// Create an app executable: module + C bindings + runtime link.
fn addApp(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root_src: []const u8,
    translate_sdl: *std.Build.Step.TranslateC,
    translate_kx: *std.Build.Step.TranslateC,
    kx_skia: *std.Build.Step.Compile,
    is_macos: bool,
    tag: []const u8,
    san_rt: ?SanitizerRuntime,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_src),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = !is_windows_local(target),
        }),
    });
    exe.root_module.addImport("sdl_c", translate_sdl.createModule());
    exe.root_module.addImport("kx_c", translate_kx.createModule());
    linkRuntime(b, exe.root_module, kx_skia, target, is_macos, tag, san_rt);
    return exe;
}

/// Link the runtime (SDL3 static + kx_skia shim + Skia static libs + macOS
/// frameworks) into a module. Shared by the exe and the test exe.
fn linkRuntime(
    b: *std.Build,
    module: *std.Build.Module,
    kx_skia: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    is_macos: bool,
    tag: []const u8,
    san_rt: ?SanitizerRuntime,
) void {
    const is_windows = std.mem.startsWith(u8, tag, "windows-");
    // SDL3 (static lib).
    if (is_windows) {
        module.addObjectFile(b.path(b.fmt("deps/SDL/build-{s}/SDL3-static.lib", .{tag})));
    } else {
        module.addObjectFile(b.path(b.fmt("deps/SDL/build-{s}/libSDL3.a", .{tag})));
    }
    if (is_macos) {
        inline for (.{
            "Cocoa",                  "IOKit",          "CoreVideo",      "CoreAudio",    "AudioToolbox", "AudioUnit",
            "ForceFeedback",          "GameController", "Metal",          "QuartzCore",   "CoreHaptics",  "AVFoundation",
            "UniformTypeIdentifiers", "CoreBluetooth",  "CoreFoundation", "CoreGraphics", "Carbon",
        }) |framework| {
            module.linkFramework(framework, .{});
        }
    }

    // Sanitized shim: every artifact linking libkx_skia.a also links the
    // ASan runtime sanitizerRuntime() located (zig has none of its own),
    // plus -rpath so dyld finds the real toolchain dylib on macOS.
    if (san_rt) |rt| {
        for (rt.objects) |obj| module.addObjectFile(obj);
        for (rt.rpaths) |rp| module.addRPath(rp);
    }

    // kx_skia shim + Skia static libs. The .a/.lib lists are deterministic
    // for our args.gn (scripts/fetch-deps.sh) — update both together if
    // args.gn changes.
    module.linkLibrary(kx_skia);
    const skia_libs = [_][]const u8{
        "libfreetype2.a", "libharfbuzz.a",    "libicu.a",      "libpng.a",            "libskcms.a",
        "libskia.a",      "libskparagraph.a", "libskshaper.a", "libskunicode_core.a", "libskunicode_icu.a",
        "libzlib.a",
    };
    const skia_libs_win = [_][]const u8{
        // Order: dependents first (skia's graphite Dawn backend references
        // dawn symbols; spirv_cross is referenced by the D3D12 backend).
        "skia.lib",          "skparagraph.lib",   "skshaper.lib",    "skunicode_core.lib",
        "skunicode_icu.lib", "dawn_combined.lib", "spirv_cross.lib", "d3d12allocator.lib",
        "harfbuzz.lib",      "icu.lib",           "freetype2.lib",   "libpng.lib",
        "skcms.lib",         "zlib.lib",
    };
    if (is_windows) {
        for (skia_libs_win) |lib| {
            module.addObjectFile(b.path(b.fmt("deps/skia/out/{s}/{s}", .{ tag, lib })));
        }
        // System libs: D3D12/DXGI (graphite-dawn-d3d12), GL (ganesh-gl WGL),
        // UIA (a11y bridge), plus SDL's own platform deps. Zig's bundled
        // import-lib table doesn't cover all of these (d3dcompiler, dxguid,
        // delayimp, ...), so point it at the real MSVC/WinSDK lib dirs —
        // resolved names there take precedence over zig's bundled stubs.
        const dirs = msvcLibDirs(b, target);
        inline for (.{ dirs.vc, dirs.um, dirs.ucrt }) |d| {
            module.addLibraryPath(.{ .cwd_relative = d });
        }
        // CRT: zig links this target as windows-gnu — lld ignores the
        // /DEFAULTLIB records embedded in MSVC objects, so the /MT CRT libs
        // (libcmt, libvcruntime, libcpmt, libucrt, oldnames) are linked
        // positionally instead, exactly like the spike recipe. Keeping
        // link_libc OFF on every module avoids zig's libmingw32, whose
        // tlssup.obj duplicates libcmt's tlsdyn.obj.
        for ([_][]const u8{ "dxguid.lib", "uuid.lib" }) |lib| {
            module.addObjectFile(.{ .cwd_relative = b.fmt("{s}\\{s}", .{ dirs.um, lib }) });
        }
        for ([_][]const u8{ "libcmt.lib", "libvcruntime.lib", "libcpmt.lib", "delayimp.lib", "oldnames.lib" }) |lib| {
            module.addObjectFile(.{ .cwd_relative = b.fmt("{s}\\{s}", .{ dirs.vc, lib }) });
        }
        for ([_][]const u8{"libucrt.lib"}) |lib| {
            module.addObjectFile(.{ .cwd_relative = b.fmt("{s}\\{s}", .{ dirs.ucrt, lib }) });
        }
        const win_libs = [_][]const u8{
            // "delayimp", "dxguid" and "uuid" are in zig's isLibCLibName list
            // for mingw targets — linkSystemLibrary would silently set
            // link_libc, dragging libmingw32 in. They are linked positionally
            // above alongside the CRT libs.
            "d3d12",            "dxgi",    "d3dcompiler", "dxva2",
            "opengl32",         "gdi32",   "user32",      "kernel32",
            "advapi32",         "ole32",   "oleaut32",    "dwmapi",
            "ws2_32",           "imm32",   "version",     "setupapi",
            "winmm",            "shell32", "hid",         "cfgmgr32",
            "uiautomationcore", "dbghelp", "onecore",
        };
        inline for (win_libs) |lib| {
            // .use_pkg_config = .no: these resolve through the MSVC/Windows
            // SDK import libs — there is no pkg-config on Windows runners
            // (zig would spawn `pkg-config --list-all` and hard-fail).
            module.linkSystemLibrary(lib, .{ .use_pkg_config = .no });
        }
    } else {
        for (skia_libs) |lib| {
            module.addObjectFile(b.path(b.fmt("deps/skia/out/{s}/{s}", .{ tag, lib })));
        }
        if (target.result.os.tag == .linux) {
            // kx_a11y_linux.cpp's ATK/AT-SPI deps — the symbols live in
            // libkx_skia.a, so every linux host exe needs the libs too.
            module.linkSystemLibrary("atk-1.0", .{});
            module.linkSystemLibrary("atk-bridge-2.0", .{});
            module.linkSystemLibrary("gobject-2.0", .{});
            module.linkSystemLibrary("glib-2.0", .{});
        }
    }
    if (is_macos) {
        inline for (.{ "Metal", "Foundation", "CoreFoundation", "CoreGraphics", "CoreText", "QuartzCore", "IOSurface" }) |fw| {
            module.linkFramework(fw, .{});
        }
    }
}

/// What an artifact must link when the shim is built with
/// -fsanitize=address (-Dsanitize). Zig 0.17's compiler-rt covers ubsan +
/// tsan but ships no ASan runtime, so it comes from the host toolchain.
const SanitizerRuntime = struct {
    /// Extra link inputs (.so on linux; the stripped toolchain dylib on macOS).
    objects: []const std.Build.LazyPath = &.{},
    /// Extra -rpath dirs (macOS only: the clang runtime dir, so dyld
    /// resolves @rpath/libclang_rt.asan_osx_dynamic.dylib to the original).
    rpaths: []const std.Build.LazyPath = &.{},
};

fn sanitizerRuntime(b: *std.Build, target: std.Build.ResolvedTarget) SanitizerRuntime {
    return switch (target.result.os.tag) {
        .macos => macOsAsanRt(b),
        .linux => linuxAsanRt(b, target),
        else => @panic("-Dsanitize supports native linux and macOS targets only"),
    };
}

/// Apple ships libclang_rt.asan_osx_dynamic.dylib as a "zippered" binary:
/// its arm64 slice carries both macOS and MacCatalyst LC_BUILD_VERSIONs,
/// and zig's dylib parser rejects the maccatalyst one. Produce a
/// macOS-only copy via lipo+vtool for the static link — the install name
/// still points at @rpath/libclang_rt.asan_osx_dynamic.dylib, so dyld
/// loads the original (properly signed) dylib at runtime.
fn macOsAsanRt(b: *std.Build) SanitizerRuntime {
    const res_dir = std.mem.trim(u8, b.run(&.{ "xcrun", "clang", "-print-resource-dir" }), &std.ascii.whitespace);
    const darwin_lib = b.fmt("{s}/lib/darwin", .{res_dir});
    const strip = b.addSystemCommand(&.{ "sh", "-c",
        // vtool warns "code signature will be invalid" — expected, the
        // stripped copy is link-only (dyld loads the original). stderr is
        // silenced so zig doesn't echo it as a failed-command annotation.
        \\xcrun lipo "$1" -thin arm64 -output "$2.tmp" &&
        \\xcrun vtool -remove-build-version maccatalyst -output "$2" "$2.tmp" 2>/dev/null &&
        \\rm "$2.tmp"
        , "kx-asan-strip" });
    strip.addFileArg(.{ .cwd_relative = b.fmt("{s}/libclang_rt.asan_osx_dynamic.dylib", .{darwin_lib}) });
    const dylib = strip.addOutputFileArg("libclang_rt.asan_osx_dynamic.dylib");
    const objects = b.allocator.alloc(std.Build.LazyPath, 1) catch @panic("OOM");
    objects[0] = dylib;
    const rpaths = b.allocator.alloc(std.Build.LazyPath, 1) catch @panic("OOM");
    rpaths[0] = .{ .cwd_relative = darwin_lib };
    return .{ .objects = objects, .rpaths = rpaths };
}

/// zig cc instruments the shim for ASan but has no runtime to link; find
/// the host's. clang's own libclang_rt.asan-*.so is preferred (same vintage
/// as the instrumenter); gcc's libasan.so.8 is ABI-compatible (upstream
/// ASan v8) and is a plain `apt install libasan8` away.
fn linuxAsanRt(b: *std.Build, target: std.Build.ResolvedTarget) SanitizerRuntime {
    const arch: []const u8 = switch (target.result.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => @panic("-Dsanitize: no ASan runtime lookup for this linux arch"),
    };
    var objects: std.ArrayList(std.Build.LazyPath) = .empty;
    // `clang -print-file-name` resolves inside clang's resource dir and
    // echoes the bare name back when the file isn't there. asan_cxx adds
    // the operator new/delete interceptors.
    for ([_][]const u8{ "asan", "asan_cxx" }) |rt| {
        const name = b.fmt("libclang_rt.{s}-{s}.so", .{ rt, arch });
        switch (b.runFallible(&.{ "clang", b.fmt("-print-file-name={s}", .{name}) }, .{ .stderr_behavior = .ignore })) {
            .success => |out| {
                const p = std.mem.trim(u8, out, &std.ascii.whitespace);
                if (std.mem.endsWith(u8, p, ".so"))
                    objects.append(b.allocator, .{ .cwd_relative = p }) catch @panic("OOM");
            },
            else => {},
        }
    }
    if (objects.items.len == 0) {
        const triplet: []const u8 = if (target.result.cpu.arch == .x86_64) "x86_64-linux-gnu" else "aarch64-linux-gnu";
        const gcc_candidates = [_][]const u8{
            b.fmt("/usr/lib/{s}/libasan.so.8", .{triplet}),
            "/usr/lib64/libasan.so.8",
        };
        for (gcc_candidates) |p| {
            if (std.Io.Dir.accessAbsolute(b.graph.io, p, .{})) |_| {
                objects.append(b.allocator, .{ .cwd_relative = p }) catch @panic("OOM");
                break;
            } else |_| {}
        }
    }
    if (objects.items.len == 0)
        @panic("-Dsanitize needs an ASan runtime on linux: apt install libclang-rt-dev (preferred) or libasan8");
    return .{ .objects = objects.items };
}

/// Phase 3f web target (wasm32-emscripten). Zig cannot link an executable for
/// emscripten, so the app is built as a static library and the final link is a
/// manual emcc step (sokol-zig pattern — docs/specs/phase-3f-wasm-plan.md §2):
///
///   libhello.a + libkx_skia.a + libSDL3.a + libskia*.wasm.a
///     -- emcc --> zig-out/web/hello.html (+ .js + .wasm)
///
/// No LTO anywhere on this path (LTO miscompiles wasm — plan §2), no pthreads,
/// no Asyncify: the browser owns the main thread (rAF loop).
fn addWasmWeb(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tag: []const u8,
    app_root_opt: ?[]const u8,
) void {
    const emsdk = "deps/emsdk";
    // Emscripten sysroot: <emscripten.h>, <GLES3/gl32.h>, musl headers.
    const sysroot_include = b.fmt("{s}/upstream/emscripten/cache/sysroot/include", .{emsdk});

    // --- kx_skia shim (C++): common + wasm impl (Ganesh WebGL2) ---
    const kx_skia = b.addLibrary(.{
        .name = "kx_skia",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = false, // emcc links musl
            // No link_libcpp: Zig's bundled libc++ headers are incompatible
            // with the emscripten sysroot. Emscripten provides its own libc++
            // in sysroot/include/c++/v1 (added to the include path below).
            .link_libcpp = false,
        }),
    });
    const shim_flags = &[_][]const u8{
        "-std=c++20",             "-fno-exceptions",             "-fno-rtti",
        "-DSK_GANESH",            "-DSK_GL",                     "-DSK_GRAPHITE",
        "-DSK_DAWN",              "-DSK_FORCE_8_BYTE_ALIGNMENT", "-DNDEBUG",
        // Match libicu.wasm.a: Skia builds ICU with symbol renaming off.
        "-DU_DISABLE_RENAMING=1",
        // zig cc enables UBSan instrumentation that references zig's
        // compiler-rt symbols; emscripten's compiler_rt doesn't provide them
        // (wasm-ld undefined __ubsan_handle_* in emdawnwebgpu's webgpu.cpp).
        "-fno-sanitize=undefined",
        // Disable all default include paths: zig cc adds its own musl/libc++
        // headers which conflict with the emscripten sysroot. All include paths
        // are provided explicitly below (compat + c++/v1 + sysroot + project
        // headers) — the same list emcc assembles (emcc.py get_cflags).
            "-nostdinc",
        "-nostdinc++",
    };
    kx_skia.root_module.addCSourceFiles(.{
        .files = &([_][]const u8{
            "kx_skia/src/kx_skia_common.cpp",
            "kx_skia/src/kx_skia_wasm.cpp",
            // emdawnwebgpu runtime impl (navigator.gpu → wgpu C API); the
            // matching library_webgpu*.js libs are added at the emcc link.
            "deps/emdawnwebgpu_pkg/webgpu/src/webgpu.cpp",
        } ++ mcu_sources),
        .flags = shim_flags,
        .language = .cpp,
    });
    kx_skia.root_module.addIncludePath(b.path("kx_skia/include"));
    kx_skia.root_module.addIncludePath(b.path("deps/mcu"));
    kx_skia.root_module.addIncludePath(b.path("deps/skia"));
    kx_skia.root_module.addIncludePath(b.path("deps/skia/include"));
    // ICU common headers (ubrk.h — grapheme-cluster boundaries); the wasm
    // build links libicu.wasm.a like the native one links libicu.a.
    kx_skia.root_module.addIncludePath(b.path("deps/skia/third_party/externals/icu/source/common"));
    // emdawnwebgpu package headers BEFORE everything else providing
    // webgpu/*.h: the pkg carries the standard-spec headers matching its JS
    // runtime. The vendored Dawn headers (third_party/externals/dawn) are the
    // dawn-native superset and must NOT leak into the wasm build.
    kx_skia.root_module.addIncludePath(b.path("deps/emdawnwebgpu_pkg/webgpu/include"));
    kx_skia.root_module.addIncludePath(b.path("deps/emdawnwebgpu_pkg/webgpu_cpp/include"));
    kx_skia.root_module.addIncludePath(b.path("deps/SDL/include"));
    // Emscripten sysroot dirs, mirroring emcc's own search order (emcc -v):
    //   fakesdl → compat → c++/v1 → clang builtins → include
    // - compat/ is REQUIRED and must come first: it holds xlocale.h plus the
    //   other BSD-compat headers that shadow same-named musl headers
    //   (stdlib.h, string.h, math.h, …). libc++'s
    //   __locale_dir/locale_base_api.h does #include <xlocale.h>
    //   unconditionally under __EMSCRIPTEN__; without compat/ on the path the
    //   C++ compile fails "'xlocale.h' not found" (this was the build-wasm CI
    //   failure; _LIBCPP_HAS_NO_XLOCALE is NOT honored by this libc++).
    // - c++/v1 (emscripten's libc++) must precede include/ (musl): libc++
    //   wrapper headers like <cstddef> do #include <stddef.h> expecting
    //   c++/v1/stddef.h, which then #include_next's down to the musl header;
    //   if musl's is found first libc++ #errors out ("didn't find libc++'s
    //   <stddef.h> header").
    // - fakesdl is skipped (real SDL3 headers above); zig's own lib/include
    //   (-isystem, searched after all -I dirs) covers the clang builtins.
    kx_skia.root_module.addIncludePath(b.path(b.fmt("{s}/compat", .{sysroot_include})));
    kx_skia.root_module.addIncludePath(b.path(b.fmt("{s}/c++/v1", .{sysroot_include})));
    kx_skia.root_module.addIncludePath(b.path(sysroot_include));

    // C bindings: SDL3 (sdl_c) + kx_skia (kx_c) via zig translate-c, with the
    // emscripten target + sysroot include.
    const translate_sdl = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl_c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_sdl.addIncludePath(b.path("deps/SDL/include"));
    // compat before include — same emcc order as the shim (compat holds the
    // BSD/GNU headers emscripten code expects to shadow the musl ones).
    translate_sdl.addIncludePath(b.path(b.fmt("{s}/compat", .{sysroot_include})));
    translate_sdl.addIncludePath(b.path(sysroot_include));

    const translate_kx = b.addTranslateC(.{
        .root_source_file = b.path("kx_skia/include/kx_skia.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_kx.addIncludePath(b.path(b.fmt("{s}/compat", .{sysroot_include})));
    translate_kx.addIncludePath(b.path(sysroot_include));

    // App selection: -Dweb-app=hello (default) | gallery — mirrors -Dios-app.
    const web_app = b.option([]const u8, "web-app", "web app to build: hello|gallery") orelse "hello";
    const app_name: []const u8 = if (app_root_opt != null) "app" else if (std.mem.eql(u8, web_app, "gallery")) "gallery" else "hello";
    const root_src: []const u8 = if (std.mem.eql(u8, app_name, "gallery")) "src/gallery_main.zig" else "src/main.zig";

    // --- app as a static library (Zig cannot link an exe for emscripten) ---
    const app = b.addLibrary(.{
        .name = app_name,
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = if (app_root_opt) |ar| b.graph.cwdRelativePath(b.fmt("{s}/src/main.zig", .{ar})) else b.path(root_src),
            .target = target,
            .optimize = optimize,
            .link_libc = false, // emcc links musl
            .link_libcpp = false, // pure Zig app; emcc links libc++ at the final link
        }),
    });
    if (app_root_opt != null) {
        const klaxon_mod = b.createModule(.{
            .root_source_file = b.path("src/klaxon.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = false,
            .link_libcpp = false,
        });
        klaxon_mod.addImport("sdl_c", translate_sdl.createModule());
        klaxon_mod.addImport("kx_c", translate_kx.createModule());
        app.root_module.addImport("klaxon", klaxon_mod);
    } else {
        app.root_module.addImport("sdl_c", translate_sdl.createModule());
        app.root_module.addImport("kx_c", translate_kx.createModule());
    }
    b.installArtifact(app);
    b.installArtifact(kx_skia);

    // --- emcc link step ---
    const opt_flag: []const u8 = switch (optimize) {
        .Debug => "-O0",
        .ReleaseSafe => "-O2",
        .ReleaseFast => "-O3",
        .ReleaseSmall => "-Oz",
    };
    // Non-CanvasKit wasm builds emit lib<name>.wasm.a (gn/toolchain/BUILD.gn).
    // Same lib list as the native linkRuntime — update both together.
    const skia_libs = [_][]const u8{
        "libfreetype2.wasm.a",     "libharfbuzz.wasm.a", "libicu.wasm.a",
        "libpng.wasm.a",           "libskcms.wasm.a",    "libskia.wasm.a",
        "libskparagraph.wasm.a",   "libskshaper.wasm.a", "libskunicode_core.wasm.a",
        "libskunicode_icu.wasm.a", "libzlib.wasm.a",
    };
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(b.allocator, b.fmt("{s}/upstream/emscripten/emcc", .{emsdk})) catch unreachable;
    argv.append(b.allocator, b.fmt("zig-out/lib/lib{s}.a", .{app_name})) catch unreachable;
    argv.append(b.allocator, "zig-out/lib/libkx_skia.a") catch unreachable;
    argv.append(b.allocator, b.fmt("deps/SDL/build-{s}/libSDL3.a", .{tag})) catch unreachable;
    for (skia_libs) |lib| {
        argv.append(b.allocator, b.fmt("deps/skia/out/{s}/{s}", .{ tag, lib })) catch unreachable;
    }
    argv.appendSlice(b.allocator, &.{
        "-o",
        b.fmt("zig-out/web/{s}.html", .{app_name}),
        "--shell-file",
        "web/shell.html",
        "--js-library",
        "web/kx_a11y.js",
        // emdawnwebgpu JS runtime — the generated tables must precede
        // library_webgpu.js (it depends on their globals), per the pkg's
        // emdawnwebgpu.port.py linker_setup.
        "--js-library",
        "deps/emdawnwebgpu_pkg/webgpu/src/library_webgpu_enum_tables.js",
        "--js-library",
        "deps/emdawnwebgpu_pkg/webgpu/src/library_webgpu_generated_struct_info.js",
        "--js-library",
        "deps/emdawnwebgpu_pkg/webgpu/src/library_webgpu_generated_sig_info.js",
        "--js-library",
        "deps/emdawnwebgpu_pkg/webgpu/src/library_webgpu.js",
        "-sUSE_WEBGL2=1",
        "-sALLOW_MEMORY_GROWTH=1",
        "-sMAXIMUM_MEMORY=2GB",
        "-sENVIRONMENT=web",
        "-sSTACK_SIZE=1MB",
        // _malloc/_free are wasm exports callable as JS globals
        // (kx_a11y.js uses _malloc/_free for the scratch buffer); they are
        // not runtime methods — listing them there just warns.
        "-sEXPORTED_FUNCTIONS=_main,_kx_a11y_dump_tree,_kx_a11y_free_string,_kx_a11y_key,_kx_a11y_root_node,_kx_a11y_text,_kx_a11y_focus_node,_kx_a11y_activate_node,_malloc,_free",
        "-sEXPORTED_RUNTIME_METHODS=ccall,cwrap,FS",
        opt_flag,
    }) catch unreachable;

    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/web" });
    const link = b.addSystemCommand(argv.items);
    link.step.dependOn(&mkdir.step);
    // Installs libhello.a + libkx_skia.a into zig-out/lib (paths referenced above).
    link.step.dependOn(b.getInstallStep());
    const web_step = b.step("web", "Build the wasm web target (-Dweb-app=hello|gallery)");
    web_step.dependOn(&link.step);
}

/// Phase 3d Android target (aarch64-linux-android). Zig cannot link an APK, so
/// the app is built as a static library and the final link is done by CMake/NDK
/// (Gradle project). The kx_skia C++ shim is NOT compiled by Zig here — CMake/NDK
/// handles it (same split as the emcc link on wasm, but with the NDK toolchain).
///
///   lib<app>.a  (zig build -Dtarget=aarch64-linux-android android-lib)
///     + kx_skia shim .o   (CMake/NDK)
///     + libSDL3.a + libskia*.a  (deps, tag android-arm64)
///       -- NDK clang++ --> lib<app>.so  (loaded by the Android app)
///
/// No run/test/package steps for android — the NDK/CMake toolchain links.
fn addAndroidLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tag: []const u8,
    app_root_opt: ?[]const u8,
) void {
    _ = tag; // deps tag for the CMake/NDK link (not used by Zig here)

    // -Dandroid-app=gallery|hello (default: gallery)
    const app_opt = b.option([]const u8, "android-app", "Android app to build: gallery|hello") orelse "gallery";
    const is_hello = std.mem.eql(u8, app_opt, "hello");
    const app_name: []const u8 = if (app_root_opt != null) "app" else if (is_hello) "hello" else "gallery";
    const root_src: []const u8 = if (is_hello) "src/main.zig" else "src/gallery_android.zig";

    // C bindings: SDL3 (sdl_c) + kx_skia (kx_c) via zig translate-c.
    // Use the NATIVE target for translate-c: Zig 0.17's NativePaths adds the
    // macOS SDK include dir on Darwin hosts even when cross-compiling, which
    // breaks Android translate-c (bionic headers conflict with macOS SDK).
    // SDL3 and kx_skia C APIs are platform-independent, and macOS arm64 +
    // Android arm64 share the AAPCS64 ABI — the generated bindings are valid.
    const native_target = b.graph.host;
    const translate_sdl = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl_c.h"),
        .target = native_target,
        .optimize = optimize,
    });
    translate_sdl.addIncludePath(b.path("deps/SDL/include"));

    const translate_kx = b.addTranslateC(.{
        .root_source_file = b.path("kx_skia/include/kx_skia.h"),
        .target = native_target,
        .optimize = optimize,
    });

    const android_root_src = if (app_root_opt != null) blk: {
        const wf = b.addWriteFiles();
        break :blk wf.add("android_app_root.zig",
            \\const std = @import("std");
            \\const builtin = @import("builtin");
            \\const klaxon = @import("klaxon");
            \\const app_main = @import("app_main");
            \\pub const std_options_debug_io: std.Io = klaxon.ios_io.io;
            \\pub const std_options_debug_threaded_io: ?*std.Io.Threaded = null;
            \\pub const std_options_elf_debug_info_search_paths: ?fn (exe_path: []const u8) switch (builtin.object_format) {
            \\    .elf => std.debug.ElfFile.DebugInfoSearchPaths,
            \\    else => void,
            \\} = struct {
            \\    fn search(_: []const u8) std.debug.ElfFile.DebugInfoSearchPaths {
            \\        return .none;
            \\    }
            \\}.search;
            \\export fn SDL_main(argc: c_int, argv: [*:null]?[*:0]u8) callconv(.c) c_int {
            \\    _ = argc;
            \\    _ = argv;
            \\    const init: std.process.Init.Minimal = undefined;
            \\    app_main.main(init) catch return 1;
            \\    return 0;
            \\}
            \\pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
            \\    var buf: [1024]u8 = undefined;
            \\    const len = @min(msg.len, buf.len - 1);
            \\    @memcpy(buf[0..len], msg[0..len]);
            \\    buf[len] = 0;
            \\    klaxon.sdl.c.SDL_Log("PANIC: %s", buf[0..len :0].ptr);
            \\    std.c.abort();
            \\}
            \\
        );
    } else b.path(root_src);

    // App as a static library (Zig provides bionic libc for android targets).
    const app = b.addLibrary(.{
        .name = app_name,
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = android_root_src,
            .target = target,
            .optimize = optimize,
            .link_libc = true, // Zig provides Android bionic libc
            .pic = true, // required: linked into libmain.so (shared)
        }),
    });
    if (app_root_opt) |ar| {
        const klaxon_mod = b.createModule(.{
            .root_source_file = b.path("src/klaxon.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
        });
        klaxon_mod.addImport("sdl_c", translate_sdl.createModule());
        klaxon_mod.addImport("kx_c", translate_kx.createModule());
        const app_main_mod = b.createModule(.{
            .root_source_file = b.graph.cwdRelativePath(b.fmt("{s}/src/main.zig", .{ar})),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
        });
        app_main_mod.addImport("klaxon", klaxon_mod);
        app.root_module.addImport("klaxon", klaxon_mod);
        app.root_module.addImport("app_main", app_main_mod);
    } else {
        app.root_module.addImport("sdl_c", translate_sdl.createModule());
        app.root_module.addImport("kx_c", translate_kx.createModule());
    }
    b.installArtifact(app);

    // Step: android-lib → zig-out/lib/lib<app>.a (CMake/NDK links the shim + Skia + SDL).
    const lib_step = b.step("android-lib", "Build the Android static library (aarch64-linux-android)");
    lib_step.dependOn(b.getInstallStep());
}

/// Phase 3e iOS target (aarch64-ios.15.0 / aarch64-ios.15.0-simulator). Zig
/// cannot link an iOS app bundle, so the app is built as a static library and
/// the final link is a manual xcrun clang++ step (same split as emcc on wasm).
/// The kx_skia ObjC++ shim is NOT compiled by Zig — xcrun clang++ handles it.
///
///   lib<app>.a  (zig build-lib -target aarch64-ios.15.0 -O ReleaseSmall)
///     + kx_skia shim .o   (xcrun clang++ -x objective-c++)
///     + libSDL3.a + libskia*.a  (deps, tag ios-arm64 / ios-sim-arm64)
///     + SDL_main TU + iOS frameworks
///       -- xcrun clang++ --> <app>.app
///
/// Guard: optimize == .ReleaseSmall is required — Zig 0.17 std.Io.Threaded
/// has a bug on iOS in Debug/ReleaseSafe.
/// No run/test steps for iOS device (cannot run on host).
fn addIosApp(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tag: []const u8,
    app_root_opt: ?[]const u8,
) void {
    // Guard: ReleaseSmall only (Zig 0.17 std.Io.Threaded iOS bug in Debug/ReleaseSafe).
    // Note: use .small (not .ReleaseSmall) — deprecated enum aliases only work
    // in switch statements, not in if comparisons (Zig 0.17 quirk).
    if (optimize != .small) {
        @panic("iOS target requires -Doptimize=ReleaseSmall (Zig 0.17 std.Io.Threaded bug on iOS in Debug/ReleaseSafe)");
    }

    const is_sim = target.result.abi == .simulator;
    const sdk_name: []const u8 = if (is_sim) "iphonesimulator" else "iphoneos";

    // SDK path via xcrun (runs on macOS host with Xcode installed).
    const sdk_path_raw = b.run(&.{ "xcrun", "--sdk", sdk_name, "--show-sdk-path" });
    const sdk_path = std.mem.trimEnd(u8, sdk_path_raw, "\r\n");

    // C bindings: SDL3 (sdl_c) + kx_skia (kx_c) via zig translate-c, with the
    // ios target. No -lc flag — it breaks libc detection for iOS targets.
    const translate_sdl = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl_c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_sdl.addIncludePath(b.path("deps/SDL/include"));
    translate_sdl.addIncludePath(b.graph.cwdRelativePath(sdk_path));

    const translate_kx = b.addTranslateC(.{
        .root_source_file = b.path("kx_skia/include/kx_skia.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_kx.addIncludePath(b.graph.cwdRelativePath(sdk_path));

    // App as a static library. src/main_ios.zig est la racine du graphe iOS
    // (callbacks SDL + start(), avec l'override std_options_debug_io —
    // gallery_main.zig n'était qu'un placeholder).
    const ios_root_src = if (app_root_opt != null) blk: {
        const wf = b.addWriteFiles();
        break :blk wf.add("ios_app_root.zig",
            \\const std = @import("std");
            \\const klaxon = @import("klaxon");
            \\const app_main = @import("app_main");
            \\pub const std_options_debug_io: std.Io = klaxon.ios_io.io;
            \\pub fn main(init: std.process.Init.Minimal) !void {
            \\    return app_main.main(init);
            \\}
            \\
        );
    } else b.path("src/main_ios.zig");

    const app = b.addLibrary(.{
        .name = if (app_root_opt != null) "app" else "gallery",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = ios_root_src,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    if (app_root_opt) |ar| {
        const klaxon_mod = b.createModule(.{
            .root_source_file = b.path("src/klaxon.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        klaxon_mod.addImport("sdl_c", translate_sdl.createModule());
        klaxon_mod.addImport("kx_c", translate_kx.createModule());
        const app_main_mod = b.createModule(.{
            .root_source_file = b.graph.cwdRelativePath(b.fmt("{s}/src/main.zig", .{ar})),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        app_main_mod.addImport("klaxon", klaxon_mod);
        app.root_module.addImport("klaxon", klaxon_mod);
        app.root_module.addImport("app_main", app_main_mod);
    } else {
        app.root_module.addImport("sdl_c", translate_sdl.createModule());
        app.root_module.addImport("kx_c", translate_kx.createModule());
    }
    // Backend selection: -Dios-backend=auto (default) | graphite-metal | raster
    const ios_backend = b.option([]const u8, "ios-backend", "iOS rendering backend (default: auto)") orelse "auto";
    // App selection: -Dios-app=gallery (default) | hello
    const ios_app = b.option([]const u8, "ios-app", "iOS app to build: gallery|hello") orelse "gallery";
    const ios_options = b.addOptions();
    ios_options.addOption([]const u8, "ios_backend", ios_backend);
    ios_options.addOption([]const u8, "ios_app", ios_app);
    app.root_module.addOptions("build_options", ios_options);
    b.installArtifact(app);

    // Build the kx_skia iOS shim: compile the C++/ObjC++ sources with xcrun
    // clang++ and archive into libkx_skia_ios.a. Not compiled by Zig (ObjC++).
    const shim_obj_dir = "zig-out/lib/kx_skia_ios_obj";
    const mkdir_shim = b.addSystemCommand(&.{ "mkdir", "-p", shim_obj_dir });
    const shim_sources = [_][]const u8{
        "kx_skia/src/kx_skia_common.cpp",
        "kx_skia/src/kx_skia_ios.mm",
        "kx_skia/src/kx_a11y_ios.mm",
        "kx_skia/src/kx_ios_sdl_main.c",
    } ++ mcu_sources;
    var shim_objs: [shim_sources.len][]const u8 = undefined;
    var last_compile_step: *std.Build.Step = &mkdir_shim.step;
    const version_min_flag = if (is_sim) "-mios-simulator-version-min=15.0" else "-mios-version-min=15.0";
    for (shim_sources, 0..) |src, i| {
        const obj_path = b.fmt("{s}/{d}.o", .{ shim_obj_dir, i });
        shim_objs[i] = obj_path;
        const is_c = std.mem.endsWith(u8, src, ".c");
        const is_objcpp = std.mem.endsWith(u8, src, ".mm");
        const lang = if (is_c) "c" else if (is_objcpp) "objective-c++" else "c++";
        const std_flag = if (is_c) "-std=c11" else "-std=c++20";
        const compile_cmd = if (is_c)
            &[_][]const u8{
                "xcrun",                            "clang",            b.fmt("-x{s}", .{lang}),
                b.fmt("-isysroot{s}", .{sdk_path}), std_flag,           "-arch",
                "arm64",                            version_min_flag,   "-DSK_GANESH",
                "-DSK_GRAPHITE",                    "-DSK_METAL",       "-DNDEBUG",
                "-I",                               "kx_skia/include",  "-I",
                "deps/skia",                        "-I",               "deps/skia/include",
                "-I",                               "deps/SDL/include", "-c",
                src,                                "-o",               obj_path,
            }
        else
            &[_][]const u8{
                "xcrun",                            "clang++",          b.fmt("-x{s}", .{lang}),
                b.fmt("-isysroot{s}", .{sdk_path}), std_flag,           "-arch",
                "arm64",                            version_min_flag,   "-fno-exceptions",
                "-fno-rtti",
                // ARC disabled — the shim does manual retain/release
                // (sk_cfp + CFRetain). iOS ships graphite-metal only.
                                       "-fno-objc-arc",    "-DSK_GANESH",
                "-DSK_GRAPHITE",                    "-DSK_METAL",       "-DNDEBUG",
                // libicu.a is built with symbol renaming off (Skia).
                "-DU_DISABLE_RENAMING=1",           "-I",               "kx_skia/include",
                "-I",                               "deps/mcu",         "-I",
                "deps/skia",                        "-I",               "deps/skia/include",
                "-I",                               "deps/skia/third_party/externals/icu/source/common",
                "-I",                               "deps/SDL/include", "-c",
                src,                                "-o",               obj_path,
            };
        const compile = b.addSystemCommand(compile_cmd);
        compile.step.dependOn(last_compile_step);
        last_compile_step = &compile.step;
    }
    var archive_argv: std.ArrayList([]const u8) = .empty;
    archive_argv.appendSlice(b.allocator, &.{ "xcrun", "ar", "rcs", "zig-out/lib/libkx_skia_ios.a" }) catch unreachable;
    archive_argv.appendSlice(b.allocator, &shim_objs) catch unreachable;
    const archive = b.addSystemCommand(archive_argv.items);
    archive.step.dependOn(last_compile_step);

    // Final link: xcrun clang++ compiles the SDL_main TU + links the static
    // lib + shim .o + Skia .a + SDL .a + iOS frameworks. The shim and deps
    // are not yet built for iOS — this step may fail at link time; the graph
    // just needs to evaluate.
    const skia_libs = [_][]const u8{
        "libfreetype2.a", "libharfbuzz.a",    "libicu.a",      "libpng.a",            "libskcms.a",
        "libskia.a",      "libskparagraph.a", "libskshaper.a", "libskunicode_core.a", "libskunicode_icu.a",
        "libzlib.a",
    };
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(b.allocator, "xcrun") catch unreachable;
    argv.append(b.allocator, "clang++") catch unreachable;
    argv.append(b.allocator, b.fmt("-isysroot{s}", .{sdk_path})) catch unreachable;
    argv.append(b.allocator, "-std=c++20") catch unreachable;
    argv.append(b.allocator, "-arch") catch unreachable;
    argv.append(b.allocator, "arm64") catch unreachable;
    // Simulator vs device: different version-min flags.
    if (is_sim) {
        argv.append(b.allocator, "-mios-simulator-version-min=15.0") catch unreachable;
    } else {
        argv.append(b.allocator, "-mios-version-min=15.0") catch unreachable;
    }
    argv.append(b.allocator, if (app_root_opt != null) "zig-out/lib/libapp.a" else "zig-out/lib/libgallery.a") catch unreachable;
    // kx_skia shim .o (compiled by xcrun clang++ from kx_skia_common.cpp + kx_skia_ios.mm)
    argv.append(b.allocator, "zig-out/lib/libkx_skia_ios.a") catch unreachable;
    // SDL3 static
    argv.append(b.allocator, b.fmt("deps/SDL/build-{s}/libSDL3.a", .{tag})) catch unreachable;
    // Skia static libs
    for (skia_libs) |lib| {
        argv.append(b.allocator, b.fmt("deps/skia/out/{s}/{s}", .{ tag, lib })) catch unreachable;
    }
    // iOS frameworks
    argv.appendSlice(b.allocator, &.{
        "-framework", "UIKit",
        "-framework", "Foundation",
        "-framework", "CoreGraphics",
        "-framework", "CoreText",
        "-framework", "QuartzCore",
        "-framework", "Metal",
        "-framework", "IOSurface",
        "-framework", "OpenGLES",
        "-framework", "CoreVideo",
        "-framework", "AudioToolbox",
        "-framework", "AVFoundation",
        "-framework", "CoreAudio",
        "-framework", "CoreHaptics",
        "-framework", "GameController",
        "-framework", "UniformTypeIdentifiers",
        "-framework", "CoreBluetooth",
    }) catch unreachable;
    argv.appendSlice(b.allocator, &.{ "-o", "zig-out/ios/gallery" }) catch unreachable;

    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/ios" });
    const link = b.addSystemCommand(argv.items);
    link.step.dependOn(&mkdir.step);
    // Installs libgallery.a into zig-out/lib (path referenced above).
    link.step.dependOn(b.getInstallStep());
    // The link references libkx_skia_ios.a — built by the shim archive step.
    link.step.dependOn(&archive.step);

    // Single step: "ios-gallery" (the only iOS app for now — a previous
    // "ios" step depended on the same link.step and produced the identical
    // binary, which was misleading).
    const ios_gallery_step = b.step("ios-gallery", "Build the iOS gallery app");
    ios_gallery_step.dependOn(&link.step);
}

/// Serial cursor shared across EVERY compileMsvcShims call: addKxSkia runs
/// twice per build (main lib + kx_skia_bench), and two independently
/// serialized chains still race each other on the shared cl/vcvars temp
/// state — one global chain removes the race for good.
var msvc_cl_serial: ?*std.Build.Step = null;

/// vcvars64's environment, imported once at graph time and replayed via
/// `set` lines in the wrapper — cached so the second compileMsvcShims call
/// doesn't re-run vsdevcmd.
const MsvcEnv = struct { path: []const u8, include: []const u8 };
var msvc_env_cache: ?MsvcEnv = null;
var msvc_env_tried: bool = false;

/// Import vcvars64's PATH/INCLUDE once per build. Every cl invocation then
/// `set`s them directly instead of re-entering vsdevcmd — per-invocation
/// vcvars raced on its own shared temp state (the recurring "The process
/// cannot access the file because it is being used by another process"
/// failures) and cost ~1-3 s per TU on top.
fn msvcEnvCapture(b: *std.Build, vcvars: []const u8) ?MsvcEnv {
    if (msvc_env_tried) return msvc_env_cache;
    msvc_env_tried = true;
    const res = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "cmd", "/c", b.fmt("\"{s}\" >NUL 2>&1 && set", .{vcvars}) },
        .stdout_limit = .limited(4 * 1024 * 1024),
    }) catch return null;
    if (res.term != .exited or res.term.exited != 0) return null;
    var path: ?[]const u8 = null;
    var include: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, res.stdout, '\n');
    while (it.next()) |line| {
        const l = std.mem.trimEnd(u8, line, "\r");
        if (std.ascii.startsWithIgnoreCase(l, "PATH=")) path = b.dupe(l[5..]);
        if (std.ascii.startsWithIgnoreCase(l, "INCLUDE=")) include = b.dupe(l[8..]);
    }
    if (path == null or include == null) return null;
    msvc_env_cache = .{ .path = path.?, .include = include.? };
    return msvc_env_cache;
}

/// Compile the kx_skia C++ shims with MSVC cl.exe (Windows only — see the
/// .windows case in addKxSkia for why zig's clang is not used). vcvars64.bat
/// is located through vswhere unless INCLUDE is already set (vcvars-loaded
/// shell). Returns the produced .obj paths.
fn compileMsvcShims(b: *std.Build, target: std.Build.ResolvedTarget) []const std.Build.LazyPath {
    const tag: []const u8 = if (target.result.cpu.arch == .x86_64) "windows-x64" else "windows-arm64";
    const Shim = struct { src: []const u8, lean: bool };
    // material-color-utilities TUs — compiled by cl like the rest of the shim
    // (the whole libkx_skia archive must share one STL ABI; these instantiate
    // MSVC std::map/vector/etc.). All lean — no Windows headers at all.
    const mcu_shims = blk: {
        var list: [mcu_sources.len]Shim = undefined;
        for (mcu_sources, 0..) |src, i| list[i] = .{ .src = src, .lean = true };
        break :blk list;
    };
    const sources = [_]Shim{
        .{ .src = "kx_skia/src/kx_skia_common.cpp", .lean = true },
        .{ .src = "kx_skia/src/kx_skia_win.cpp", .lean = true },
        // UIAutomationCore.h needs the ole2 types — no WIN32_LEAN_AND_MEAN.
        .{ .src = "kx_skia/src/kx_a11y_win.cpp", .lean = false },
    } ++ mcu_shims;
    const vcvars = msvcVcvarsPath(b, target);
    // Wrapper .bat: `cmd /c wrapper.bat <args>` forwards args via %* —
    // args appended after a quoted `cmd /c "..."` string are ignored by cmd.
    const wf = b.addWriteFiles();
    // cl writes diagnostics to STDOUT; zig only surfaces stderr on failure.
    // Capture full cl output to a per-invocation temp log (parallel shims
    // must not share it) and dump it to stderr only when cl fails — zig
    // truncates long output, and skia-header warnings would bury the error.
    // cl is retried once: the first parallel invocations on a fresh runner
    // race inside vcvars/vsdevcmd and can exit nonzero with no output while
    // a sequential re-run of the same file compiles cleanly.
    const attempt = "@cl %* >\"%kxlog%\" 2>&1 || cl %* >\"%kxlog%\" 2>&1\r\n" ++
        "@if errorlevel 1 (echo cl failed twice - output:>&2&type \"%kxlog%\">&2&del \"%kxlog%\"&exit /b 1)\r\n" ++
        "@del \"%kxlog%\" >NUL 2>&1\r\n";
    // Environment prelude: the captured vcvars env (preferred — no vsdevcmd
    // re-entry per TU), else @call vcvars each time, else nothing when
    // INCLUDE is already set (vcvars-loaded shell).
    const env_prelude = if (vcvars.len == 0)
        ""
    else if (msvcEnvCapture(b, vcvars)) |env|
        b.fmt("@set \"PATH={s}\"\r\n@set \"INCLUDE={s}\"\r\n", .{ env.path, env.include })
    else
        b.fmt("@call \"{s}\" >NUL 2>&1\r\n@if errorlevel 1 (echo vcvars64 failed>&2& exit /b 1)\r\n", .{vcvars});
    const wrapper = wf.add("msvc-cl-wrapper.bat", b.fmt("@set \"kxlog=%TEMP%\\kx-cl-%RANDOM%-%RANDOM%.log\"\r\n{s}{s}", .{ env_prelude, attempt }));
    var objs: std.ArrayList(std.Build.LazyPath) = .empty;
    // cl runs serialized across ALL shim compiles (global msvc_cl_serial):
    // parallel invocations on a fresh runner race on shared temp state (cl
    // intermediates, identical %RANDOM% log names in simultaneous cmds,
    // vsdevcmd writes) and die with "The process cannot access the file
    // because it is being used by another process". 6 small TUs ≈ 30 s —
    // not worth parallelizing.
    for (sources) |s| {
        const run = b.addSystemCommand(&.{"cmd"});
        if (msvc_cl_serial) |p| run.step.dependOn(p);
        msvc_cl_serial = &run.step;
        run.addArg("/c");
        run.addFileArg(wrapper);
        run.addArg("/nologo");
        run.addArg("/std:c++20");
        run.addArg("/EHsc");
        run.addArg("/O2");
        run.addArg("/MT");
        run.addArg("/bigobj");
        // /w, not /W3: Skia's headers emit hundreds of C4244/C4267 warnings
        // that flood zig's captured stderr — on failure the actual C####
        // error was truncated away and CI showed warnings only. Errors still
        // print; the warning noise is third-party, not actionable.
        run.addArg("/w");
        run.addArg("/DNDEBUG");
        run.addArg("/D_CRT_SECURE_NO_WARNINGS");
        run.addArg("/DNOMINMAX");
        if (s.lean) run.addArg("/DWIN32_LEAN_AND_MEAN");
        run.addArg("/DSK_GANESH");
        run.addArg("/DSK_GRAPHITE");
        // skia.lib's ICU is built with symbol renaming off.
        run.addArg("/DU_DISABLE_RENAMING=1");
        inline for (.{ "kx_skia/include", "deps/skia", "deps/skia/include", "deps/skia/third_party/externals/icu/source/common", "deps/SDL/include", "deps/mcu" }) |inc| {
            run.addArg("/I" ++ inc);
        }
        // Dawn's checked-in headers + the cmake-generated webgpu_cpp.h.
        run.addArg("/Ideps/skia/third_party/externals/dawn/include");
        run.addArg(b.fmt("/Ideps/skia/out/{s}/cmake_dawn/gen/include", .{tag}));
        run.addArg("/c");
        run.addFileArg(b.path(s.src));
        objs.append(b.allocator, run.addPrefixedOutputFileArg("/Fo:", b.fmt("{s}.obj", .{std.fs.path.stem(s.src)}))) catch @panic("OOM");
    }
    return objs.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// MSVC toolset lib dir + WinSDK um/ucrt lib dirs for the target arch.
/// `zig build` runs steps with cwd = build root; returned paths are absolute.
const WinLibDirs = struct { vc: []const u8, um: []const u8, ucrt: []const u8 };

fn msvcLibDirs(b: *std.Build, target: std.Build.ResolvedTarget) WinLibDirs {
    const io = b.graph.io;
    const arch_dir: []const u8 = if (target.result.cpu.arch == .x86_64) "x64" else "arm64";
    const root = vsInstallRoot(b) orelse
        @panic("MSVC toolset not found — install Visual Studio (VCTools), or run `zig build` inside a vcvars shell");
    const msvc_dir = b.fmt("{s}\\VC\\Tools\\MSVC", .{root});
    const ver = newestSubdir(b, msvc_dir) orelse
        @panic("MSVC toolset not found — no VC\\Tools\\MSVC\\<ver> under the VS install root");
    const vc_lib = b.fmt("{s}\\{s}\\lib\\{s}", .{ msvc_dir, ver, arch_dir });
    std.Io.Dir.accessAbsolute(io, vc_lib, .{}) catch
        @panic("MSVC toolset lib dir missing for the target arch — install the matching VCTools component");
    const sdk_lib = "C:\\Program Files (x86)\\Windows Kits\\10\\Lib";
    const sdk_ver = newestSubdir(b, sdk_lib) orelse
        @panic("Windows SDK not found under C:\\Program Files (x86)\\Windows Kits\\10\\Lib");
    return .{
        .vc = vc_lib,
        .um = b.fmt("{s}\\{s}\\um\\{s}", .{ sdk_lib, sdk_ver, arch_dir }),
        .ucrt = b.fmt("{s}\\{s}\\ucrt\\{s}", .{ sdk_lib, sdk_ver, arch_dir }),
    };
}

/// MSVC/WinSDK *include* dirs (VC toolset + um + ucrt + shared) for translate-c.
const WinIncDirs = struct { vc: []const u8, um: []const u8, ucrt: []const u8, shared: []const u8 };

fn msvcIncludeDirs(b: *std.Build, target: std.Build.ResolvedTarget) WinIncDirs {
    _ = target;
    const root = vsInstallRoot(b) orelse
        @panic("MSVC headers not found — install Visual Studio (VCTools)");
    const msvc_dir = b.fmt("{s}\\VC\\Tools\\MSVC", .{root});
    const ver = newestSubdir(b, msvc_dir) orelse
        @panic("MSVC headers not found — no VC\\Tools\\MSVC\\<ver> under the VS install root");
    const vc_inc = b.fmt("{s}\\{s}\\include", .{ msvc_dir, ver });
    std.Io.Dir.accessAbsolute(b.graph.io, vc_inc, .{}) catch
        @panic("MSVC headers not found under the VS install root");
    const sdk_inc = "C:\\Program Files (x86)\\Windows Kits\\10\\Include";
    const sdk_ver = newestSubdir(b, sdk_inc) orelse
        @panic("Windows SDK not found under C:\\Program Files (x86)\\Windows Kits\\10\\Include");
    return .{
        .vc = vc_inc,
        .um = b.fmt("{s}\\{s}\\um", .{ sdk_inc, sdk_ver }),
        .ucrt = b.fmt("{s}\\{s}\\ucrt", .{ sdk_inc, sdk_ver }),
        .shared = b.fmt("{s}\\{s}\\shared", .{ sdk_inc, sdk_ver }),
    };
}

/// Highest-sorting subdirectory name inside `dir`, or null if unreadable.
fn newestSubdir(b: *std.Build, dir_path: []const u8) ?[]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(b.graph.io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(b.graph.io);
    var it = dir.iterate();
    var best: ?[]const u8 = null;
    while (it.next(b.graph.io) catch null) |ent| {
        if (ent.kind != .directory) continue;
        if (best == null or std.mem.order(u8, ent.name, best.?) == .gt)
            best = b.allocator.dupe(u8, ent.name) catch @panic("OOM");
    }
    return best;
}

/// VS install root (`...\Microsoft Visual Studio\2022\Enterprise`,
/// `...\18\Enterprise`, ...). Probes the known layouts first, then falls
/// back to vswhere — always installed under Installer\ alongside any VS
/// 2017+ install — so future VS versions resolve without code changes.
fn vsInstallRoot(b: *std.Build) ?[]const u8 {
    const prefixes = [_][]const u8{
        "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022",
        "C:\\Program Files\\Microsoft Visual Studio\\2022",
        "C:\\Program Files\\Microsoft Visual Studio\\18",
        "C:\\Program Files\\Microsoft Visual Studio\\2026",
    };
    const editions = [_][]const u8{ "BuildTools", "Community", "Professional", "Enterprise" };
    for (prefixes) |p| for (editions) |e| {
        const cand = b.fmt("{s}\\{s}", .{ p, e });
        std.Io.Dir.accessAbsolute(b.graph.io, cand, .{}) catch continue;
        return cand;
    };
    const vswhere = "C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe";
    const res = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ vswhere, "-latest", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath" },
        .stdout_limit = .limited(64 * 1024),
    }) catch return null;
    const root = std.mem.trim(u8, res.stdout, " \r\n\t");
    if (res.term == .exited and res.term.exited == 0 and root.len > 0) return root;
    return null;
}

/// Path to vcvars64.bat ("" when INCLUDE is already set — a vcvars shell).
fn msvcVcvarsPath(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    if (b.graph.environ_map.get("INCLUDE")) |v| {
        if (v.len > 0) return "";
    }
    // vcvars64 = host arch on both x64 and ARM64 native installs; crossing
    // from an x64 host to aarch64 needs the amd64_arm64 variant instead.
    const vcvars_name: []const u8 = if (target.result.cpu.arch == .aarch64 and
        builtin.cpu.arch == .x86_64)
        "vcvarsamd64_arm64.bat"
    else
        "vcvars64.bat";
    // One install root for vcvars, lib dirs and include dirs — probe the
    // usual layouts (2022, then VS 2026: windows-latest is now the
    // windows-2025 image which ships VS 2026 under ...\18\<Edition>) and
    // fall back to vswhere for whatever the image actually has.
    const root = vsInstallRoot(b) orelse
        @panic("MSVC not found: install Visual Studio (VCTools + a Windows SDK), or run `zig build` inside a vcvars shell");
    const cand = b.fmt("{s}\\VC\\Auxiliary\\Build\\{s}", .{ root, vcvars_name });
    std.Io.Dir.accessAbsolute(b.graph.io, cand, .{}) catch
        @panic("MSVC not found: vcvars missing under the VS install root — run `zig build` inside a vcvars shell");
    return cand;
}

fn is_windows_local(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .windows;
}
