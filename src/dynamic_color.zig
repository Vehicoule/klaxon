//! Dynamic color — M3E "Material You" theming from a seed color or an image.
//! Wraps Google's material-color-utilities C++ port (deps/mcu) through the
//! extern "C" seam in deps/mcu/kx_mcu.h.
//!
//! This module is deliberately freestanding (std only — no theme.zig/ui.zig
//! import) so `zig test src/dynamic_color.zig` compiles it alone; tests of
//! imported files that pull the `kx_c` translate-c module would otherwise
//! fail. Callers convert a `Scheme` into `theme.ColorScheme` via
//! `scheme(...).toColorScheme(theme.ColorScheme)`.
//!
//! Colors are 0xRRGGBBAA — the same convention as ui.paint.Color.

const std = @import("std");

/// 0xRRGGBBAA (R high byte, alpha low byte). Bitcast-compatible with
/// ui.paint.Color / theme.Color (both plain u32).
pub const Color = u32;

/// HCT: CAM16 hue + chroma, L* perceptual tone. Tone difference of 40
/// guarantees WCAG contrast >= 3.0; 50 guarantees >= 4.5.
pub const Hct = struct {
    /// Degrees in [0, 360).
    hue: f64,
    /// >= 0; the gamut maximum depends on hue and tone.
    chroma: f64,
    /// L* lightness in [0, 100] — linear to human perception.
    tone: f64,

    /// Decompose a color into HCT.
    pub fn fromColor(color: Color) Hct {
        const h = kx_mcu_hct_from_color(color);
        return .{ .hue = h.hue, .chroma = h.chroma, .tone = h.tone };
    }

    /// Recompose into a color. Chroma clamps to the gamut maximum for the
    /// hue/tone — `toColor` may return a less saturated color than requested.
    pub fn toColor(self: Hct) Color {
        return kx_mcu_color_from_hct(self.hue, self.chroma, self.tone);
    }

    /// Same hue/chroma at a new tone — the M3 "shift lightness" operation.
    pub fn withTone(self: Hct, tone: f64) Hct {
        return .{ .hue = self.hue, .chroma = self.chroma, .tone = tone };
    }
};

/// M3E scheme variants. `tonal_spot` is the Android 12+ default (pastel,
/// low chroma); `expressive` is the M3E default (rotated hues, more playful);
/// `vibrant` maximizes chroma; `fidelity`/`content` keep the seed's hue and
/// chroma; `neutral`/`monochrome` approach grayscale.
pub const Variant = enum(c_int) {
    tonal_spot = 0,
    expressive = 1,
    vibrant = 2,
    neutral = 3,
    monochrome = 4,
    fidelity = 5,
    content = 6,
    rainbow = 7,
    fruit_salad = 8,
};

/// All 38 M3 color roles — field-for-field identical to theme.ColorScheme
/// (verified by toColorScheme's comptime field-name copy). extern layout:
/// matches KxMcuScheme in deps/mcu/kx_mcu.h.
pub const Scheme = extern struct {
    primary: Color,
    on_primary: Color,
    primary_container: Color,
    on_primary_container: Color,
    secondary: Color,
    on_secondary: Color,
    secondary_container: Color,
    on_secondary_container: Color,
    tertiary: Color,
    on_tertiary: Color,
    tertiary_container: Color,
    on_tertiary_container: Color,
    @"error": Color,
    on_error: Color,
    error_container: Color,
    on_error_container: Color,
    surface: Color,
    on_surface: Color,
    surface_variant: Color,
    on_surface_variant: Color,
    surface_container_lowest: Color,
    surface_container_low: Color,
    surface_container: Color,
    surface_container_high: Color,
    surface_container_highest: Color,
    background: Color,
    on_background: Color,
    outline: Color,
    outline_variant: Color,
    inverse_surface: Color,
    inverse_on_surface: Color,
    inverse_primary: Color,
    surface_tint: Color,
    surface_bright: Color,
    surface_dim: Color,
    scrim: Color,
    shadow: Color,

    /// Copy into any struct with the same field names and Color-typed fields
    /// — i.e. `theme.ColorScheme`. Fails to compile if the target's fields
    /// drift out of sync with the C ABI struct, so the mapping can never
    /// silently skew.
    pub fn toColorScheme(self: Scheme, comptime T: type) T {
        var out: T = undefined;
        inline for (@typeInfo(T).@"struct".field_names) |name| {
            @field(out, name) = @field(self, name);
        }
        return out;
    }
};

/// Resolve all 38 roles for `variant` at `contrast_level` ([-1, 1]; 0 =
/// default WCAG AA targets, >0 raises text contrast). `dark` selects the
/// dark scheme.
pub fn scheme(seed: Color, variant: Variant, dark: bool, contrast_level: f64) Scheme {
    var out: Scheme = undefined;
    kx_mcu_scheme(@intFromEnum(variant), seed, dark, contrast_level, &out);
    return out;
}

/// Light scheme at default contrast.
pub fn schemeLight(seed: Color, variant: Variant) Scheme {
    return scheme(seed, variant, false, 0);
}

/// Dark scheme at default contrast.
pub fn schemeDark(seed: Color, variant: Variant) Scheme {
    return scheme(seed, variant, true, 0);
}

/// The `seed`'s tonal palette evaluated at `tone` in [0, 100]
/// (0 = black, 100 = white — the palette's hue/chroma held constant).
pub fn tonalColor(seed: Color, tone: f64) Color {
    return kx_mcu_tonal_color(seed, tone);
}

/// Batch form: out[i] = the seed's palette at tones[i]. Returns the count.
pub fn tonalPalette(seed: Color, tones: []const f64, out: []Color) usize {
    std.debug.assert(tones.len <= out.len);
    return kx_mcu_tonal_palette(seed, tones.ptr, out.ptr, tones.len);
}

/// Dominant theme-suitable colors of an RGBA8 pixel buffer (4 bytes per
/// pixel, straight R,G,B,A; fully transparent pixels ignored). Quantizes
/// with Celebi (Wu + WSMeans) then ranks by MCU Score suitability (chroma,
/// usage share) — best seed color first. Returns the written count
/// (>= 1; falls back to Google Blue when nothing scores).
pub fn dominantColors(rgba_pixels: []const u8, out: []Color) usize {
    std.debug.assert(rgba_pixels.len % 4 == 0);
    if (out.len == 0) return 0;
    return kx_mcu_dominant_colors(rgba_pixels.ptr, rgba_pixels.len / 4, out.ptr, out.len);
}

/// The single best seed color from an image — first of dominantColors
/// (which always yields at least one color, Google Blue as fallback).
/// `fallback` applies only when `rgba_pixels` is empty.
pub fn dominantColor(rgba_pixels: []const u8, fallback: Color) Color {
    if (rgba_pixels.len == 0) return fallback;
    var out: [1]Color = undefined;
    const n = dominantColors(rgba_pixels, &out);
    return if (n == 0) fallback else out[0];
}

/// M3 color harmonization: rotate `design`'s hue toward `theme`'s while
/// keeping its chroma/tone — blend a brand accent into a dynamic scheme.
pub fn harmonize(design: Color, theme: Color) Color {
    return kx_mcu_harmonize(design, theme);
}

// --- C ABI (deps/mcu/kx_mcu.h; impl deps/mcu/kx_mcu.cpp) ---

const KxMcuHct = extern struct { hue: f64, chroma: f64, tone: f64 };

extern fn kx_mcu_hct_from_color(rgba: u32) KxMcuHct;
extern fn kx_mcu_color_from_hct(hue: f64, chroma: f64, tone: f64) u32;
extern fn kx_mcu_tonal_color(seed_rgba: u32, tone: f64) u32;
extern fn kx_mcu_tonal_palette(seed_rgba: u32, tones: [*]const f64, out: [*]u32, n: usize) usize;
extern fn kx_mcu_scheme(variant: c_int, seed_rgba: u32, dark: bool, contrast_level: f64, out: *Scheme) void;
extern fn kx_mcu_dominant_colors(rgba_pixels: [*]const u8, pixel_count: usize, out: [*]u32, cap: usize) usize;
extern fn kx_mcu_harmonize(design_rgba: u32, theme_rgba: u32) u32;

// --- tests ---
//
// `zig test src/dynamic_color.zig` alone can't link the externs — pass the
// C++ sources positionally (skip *_test.cc, they need gtest):
//   zig test src/dynamic_color.zig deps/mcu/kx_mcu.cpp \
//     $(find deps/mcu/cpp -name '*.cc' ! -name '*_test.cc') -I deps/mcu -lc -lc++
// or via the build graph: `zig build test-dynamic-color`.

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

fn expectEqualOpaque(c: Color) !void {
    try expectEqual(@as(u8, 0xFF), channel(c, 0));
}

fn channel(color: Color, shift: u5) u8 {
    return @truncate(color >> shift);
}

fn channelDelta(a: Color, b: Color) u8 {
    var d: u8 = 0;
    inline for (.{ 24, 16, 8, 0 }) |s| {
        const x: i16 = channel(a, s);
        const y: i16 = channel(b, s);
        d = @max(d, @as(u8, @intCast(@abs(x - y))));
    }
    return d;
}

/// WCAG contrast ratio — mirrors theme.contrastRatio (kept local: this file
/// must not import theme.zig, see header).
fn contrastRatio(a: Color, b: Color) f32 {
    const lum = struct {
        fn f(c: Color) f32 {
            const lin = struct {
                fn g(chan: u8) f32 {
                    const s = @as(f32, @floatFromInt(chan)) / 255.0;
                    return if (s <= 0.04045) s / 12.92 else std.math.pow(f32, (s + 0.055) / 1.055, 2.4);
                }
            }.g;
            return 0.2126 * lin(channel(c, 24)) + 0.7152 * lin(channel(c, 16)) + 0.0722 * lin(channel(c, 8));
        }
    }.f;
    const hi = @max(lum(a), lum(b));
    const lo = @min(lum(a), lum(b));
    return (hi + 0.05) / (lo + 0.05);
}

test "hct: known anchors (CAM16 reference values)" {
    // Values cross-checked against the upstream java/cpp test corpus.
    const red = Hct.fromColor(0xFF0000FF);
    try expectApproxEqAbs(@as(f64, 27.4), red.hue, 1.0);
    try expectApproxEqAbs(@as(f64, 113.4), red.chroma, 1.0);
    try expectApproxEqAbs(@as(f64, 53.2), red.tone, 0.5);
    const green = Hct.fromColor(0x00FF00FF);
    try expectApproxEqAbs(@as(f64, 142.1), green.hue, 1.0);
    try expectApproxEqAbs(@as(f64, 108.4), green.chroma, 1.0);
    try expectApproxEqAbs(@as(f64, 87.7), green.tone, 0.5);
    const blue = Hct.fromColor(0x0000FFFF);
    try expectApproxEqAbs(@as(f64, 282.8), blue.hue, 1.0);
    try expectApproxEqAbs(@as(f64, 87.2), blue.chroma, 1.0);
    try expectApproxEqAbs(@as(f64, 32.3), blue.tone, 0.5);
    // achromatic endpoints
    try expectApproxEqAbs(@as(f64, 100), Hct.fromColor(0xFFFFFFFF).tone, 0.01);
    try expectApproxEqAbs(@as(f64, 0), Hct.fromColor(0x000000FF).tone, 0.01);
}

test "hct: roundtrip preserves the color (gamut-sized inputs)" {
    const colors = [_]Color{
        0xFF0000FF, 0x00FF00FF, 0x0000FFFF, 0xFFFFFFFF, 0x000000FF,
        0x6750A4FF, 0x4285F4FF, 0xFBBC05FF, 0x34A853FF, 0x808080FF,
    };
    for (colors) |c| {
        try expect(channelDelta(c, Hct.fromColor(c).toColor()) <= 2);
    }
    // hct -> color -> hct roundtrip keeps hue/chroma/tone close.
    const h = Hct{ .hue = 265, .chroma = 40, .tone = 60 };
    const back = Hct.fromColor(h.toColor());
    try expectApproxEqAbs(h.hue, back.hue, 1.0);
    try expectApproxEqAbs(h.chroma, back.chroma, 1.0);
    try expectApproxEqAbs(h.tone, back.tone, 0.5);
}

test "tonal palette: tone 0 is black, 100 is white, 50 sits between" {
    const seed: Color = 0x6750A4FF; // M3 baseline seed purple
    try expect(channelDelta(0x000000FF, tonalColor(seed, 0)) <= 1);
    try expect(channelDelta(0xFFFFFFFF, tonalColor(seed, 100)) <= 1);
    const mid = tonalColor(seed, 50);
    try expect(Hct.fromColor(mid).tone > 45);
    try expect(Hct.fromColor(mid).tone < 55);

    const tones = [_]f64{ 0, 25, 50, 75, 100 };
    var colors: [tones.len]Color = undefined;
    try expect(@as(usize, tones.len) == tonalPalette(seed, &tones, &colors));
    for (colors) |c| try expectEqualOpaque(c);
}

test "scheme: tonal_spot light/dark reproduce M3 role contrast" {
    const seed: Color = 0x6750A4FF;
    inline for (.{ schemeLight(seed, .tonal_spot), schemeDark(seed, .tonal_spot) }) |cs| {
        // every role opaque
        inline for (@typeInfo(Scheme).@"struct".field_names) |name| {
            try expectEqualOpaque(@field(cs, name));
        }
        // WCAG AA text pairs (M3 guarantees >= 4.5 at default contrast)
        const pairs = .{
            .{ cs.primary, cs.on_primary },
            .{ cs.secondary, cs.on_secondary },
            .{ cs.tertiary, cs.on_tertiary },
            .{ cs.@"error", cs.on_error },
            .{ cs.primary_container, cs.on_primary_container },
            .{ cs.secondary_container, cs.on_secondary_container },
            .{ cs.tertiary_container, cs.on_tertiary_container },
            .{ cs.error_container, cs.on_error_container },
            .{ cs.surface, cs.on_surface },
            .{ cs.surface_variant, cs.on_surface_variant },
            .{ cs.inverse_surface, cs.inverse_on_surface },
        };
        inline for (pairs) |p| {
            try expect(contrastRatio(p[0], p[1]) >= 4.5);
        }
    }
    const light = schemeLight(seed, .tonal_spot);
    const dark = schemeDark(seed, .tonal_spot);
    try expect(light.primary != dark.primary);
    try expect(light.surface != dark.surface);
    // light scheme surface is light, dark scheme surface is dark
    try expect(Hct.fromColor(light.surface).tone > 80);
    try expect(Hct.fromColor(dark.surface).tone < 30);
}

test "scheme: all nine variants resolve opaque roles" {
    const seed: Color = 0x4285F4FF; // Google Blue
    inline for (@typeInfo(Variant).@"enum".field_values) |v| {
        const cs = schemeLight(seed, @enumFromInt(v));
        try expect(cs.primary != 0);
        try expectEqualOpaque(cs.primary);
        try expectEqualOpaque(cs.on_primary);
        try expect(cs.primary_container != 0);
    }
}

test "scheme: high contrast pushes text-on-color pairs apart" {
    const seed: Color = 0x6750A4FF;
    const normal = scheme(seed, .tonal_spot, false, 0);
    const hi = scheme(seed, .tonal_spot, false, 1.0);
    // Higher contrast => on_primary sits further from primary in tone.
    const d_normal = @abs(Hct.fromColor(normal.on_primary).tone - Hct.fromColor(normal.primary).tone);
    const d_hi = @abs(Hct.fromColor(hi.on_primary).tone - Hct.fromColor(hi.primary).tone);
    try expect(d_hi >= d_normal);
    try expect(contrastRatio(hi.primary, hi.on_primary) >= contrastRatio(normal.primary, normal.on_primary) - 0.01);
}

test "toColorScheme: field-wise copies into a compatible struct" {
    // Mirror of theme.ColorScheme's shape — proves the copy compiles against
    // a foreign struct and that no field was skipped.
    const Mirror = extern struct {
        primary: Color,
        on_primary: Color,
        primary_container: Color,
        on_primary_container: Color,
        secondary: Color,
        on_secondary: Color,
        secondary_container: Color,
        on_secondary_container: Color,
        tertiary: Color,
        on_tertiary: Color,
        tertiary_container: Color,
        on_tertiary_container: Color,
        @"error": Color,
        on_error: Color,
        error_container: Color,
        on_error_container: Color,
        surface: Color,
        on_surface: Color,
        surface_variant: Color,
        on_surface_variant: Color,
        surface_container_lowest: Color,
        surface_container_low: Color,
        surface_container: Color,
        surface_container_high: Color,
        surface_container_highest: Color,
        background: Color,
        on_background: Color,
        outline: Color,
        outline_variant: Color,
        inverse_surface: Color,
        inverse_on_surface: Color,
        inverse_primary: Color,
        surface_tint: Color,
        surface_bright: Color,
        surface_dim: Color,
        scrim: Color,
        shadow: Color,
    };
    const cs = schemeLight(0x6750A4FF, .tonal_spot).toColorScheme(Mirror);
    try expectEqual(cs.primary, cs.surface_tint); // surface_tint aliases primary
    try expectEqual(schemeLight(0x6750A4FF, .tonal_spot).primary, cs.primary);
    // same field names/order => same byte layout as Scheme
    try expectEqual(@sizeOf(Scheme), @sizeOf(Mirror));
}

test "dominantColors: a mostly-red image ranks a red seed first" {
    // 64 x 64 px RGBA8: ~85% brick red, rest scattered dark blue.
    var px: [64 * 64 * 4]u8 = undefined;
    for (0..64 * 64) |i| {
        const red = i % 7 != 0; // ~85.7% red
        px[i * 4 + 0] = if (red) 0xC0 else 0x20;
        px[i * 4 + 1] = if (red) 0x39 else 0x20;
        px[i * 4 + 2] = if (red) 0x28 else 0xB0;
        px[i * 4 + 3] = 0xFF;
    }
    var out: [4]Color = undefined;
    const n = dominantColors(&px, &out);
    try expect(n >= 1);
    const top = out[0];
    // Red-dominant: R clearly above B, and hue in the red/pink sector.
    try expect(channel(top, 24) > channel(top, 8));
    try expect(channel(top, 24) > channel(top, 16));
}

test "dominantColors: transparent pixels are ignored; empty -> fallback" {
    var out: [2]Color = undefined;
    // Fully transparent buffer => fallback color (Google Blue), count 1.
    const transparent: [32]u8 = @splat(0); // 8 fully transparent pixels
    try expectEqual(@as(usize, 1), dominantColors(&transparent, &out));
    try expectEqual(@as(Color, 0x4285F4FF), out[0]);
    try expectEqual(@as(Color, 0xDEADBEEF), dominantColor(&.{}, 0xDEADBEEF));
}

test "harmonize: shifts hue toward the theme color, keeps tone" {
    const harmonized = harmonize(0x00FF00FF, 0x0000FFFF); // green -> blue-ish
    const h = Hct.fromColor(harmonized);
    const green = Hct.fromColor(0x00FF00FF);
    const blue = Hct.fromColor(0x0000FFFF);
    // hue moves away from pure green toward blue, tone is preserved.
    try expect(@abs(h.hue - green.hue) > 5);
    try expectApproxEqAbs(green.tone, h.tone, 1.0);
    try expect(h.hue > green.hue); // green 142 -> rotating toward 282
    _ = blue;
}
