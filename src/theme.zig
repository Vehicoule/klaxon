// Theme — Material 3 Expressive design tokens (Phase 2d-0).
//
// The full M3E token set: color roles (light/dark baseline schemes), type
// scale, shape, elevation, motion (durations, easings, springs), state-layer
// opacities and spacing. Widgets consume a Theme value — apps override
// tokens (or the whole Theme) to reskin; that override layer is where custom
// branding lands (see docs/DESIGN-SYSTEM.md).
//
// Colors are 0xRRGGBBAA (see ui/paint.zig). Color values are Google's M3
// baseline schemes. Dynamic color (HCT palettes from a seed/wallpaper) comes
// from material-color-utilities via src/dynamic_color.zig — see
// Theme.fromSeedColor / Theme.fromImage.
//
// Decision record: docs/adr/ADR-0010-design-system-m3e.md.

const std = @import("std");
const ui = @import("ui.zig");
const anim = @import("ui/anim.zig");
// Dynamic color engine (material-color-utilities). The dependency runs this
// way only: theme.zig -> dynamic_color.zig, never the reverse — the engine
// stays std-only so `zig test src/dynamic_color.zig` compiles standalone.
const dynamic_color = @import("dynamic_color.zig");

pub const Color = ui.paint.Color;

/// M3 state layer: the on-color of a container blended over the base color
/// at the state opacity (hover 0.08, focus 0.10, pressed 0.12, drag 0.16).
pub fn stateLayer(base: Color, on: Color, alpha: f32) Color {
    return anim.lerpColor(base, on, alpha);
}

/// Relative luminance (WCAG 2.x): 0 = black, 1 = white. Used for contrast
/// checks in tests and by accessibility tooling.
pub fn relativeLuminance(c: Color) f32 {
    const lin = struct {
        fn f(chan: u32) f32 {
            const s = @as(f32, @floatFromInt(chan)) / 255.0;
            return if (s <= 0.04045) s / 12.92 else std.math.pow(f32, (s + 0.055) / 1.055, 2.4);
        }
    }.f;
    const r = lin((c >> 24) & 0xFF);
    const g = lin((c >> 16) & 0xFF);
    const b = lin((c >> 8) & 0xFF);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// WCAG contrast ratio between two colors (1..21).
pub fn contrastRatio(a: Color, b: Color) f32 {
    const la = relativeLuminance(a);
    const lb = relativeLuminance(b);
    const hi = @max(la, lb);
    const lo = @min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
}

/// `copy(alpha = a)` — the color with its alpha channel REPLACED (clamped
/// to 0..1); contrast with ui.paint.withAlphaScaled, which scales it.
fn withAlpha(c: Color, a: f32) Color {
    const byte: u32 = @intFromFloat(std.math.clamp(@round(std.math.clamp(a, 0, 1) * 255), 0, 255));
    return (c & 0xFFFFFF00) | byte;
}

/// androidx Color.compositeOver (ui-graphics Color.kt): Porter-Duff
/// source-over in straight sRGB channels — out_a = sa + da·(1−sa),
/// out_c = (sc·sa + dc·da·(1−sa)) / out_a (component 0 when out_a == 0).
fn compositeOver(src: Color, dst: Color) Color {
    const sa = @as(f32, @floatFromInt(src & 0xFF)) / 255.0;
    const da = @as(f32, @floatFromInt(dst & 0xFF)) / 255.0;
    const oa = sa + da * (1 - sa);
    const chan = struct {
        fn f(sc: u32, dc: u32, _sa: f32, _da: f32, _oa: f32) u32 {
            if (_oa <= 0) return 0;
            const v = (@as(f32, @floatFromInt(sc)) * _sa + @as(f32, @floatFromInt(dc)) * _da * (1 - _sa)) / _oa;
            return @intFromFloat(std.math.clamp(@round(v), 0, 255));
        }
    }.f;
    const a: u32 = @intFromFloat(std.math.clamp(@round(oa * 255), 0, 255));
    return (chan((src >> 24) & 0xFF, (dst >> 24) & 0xFF, sa, da, oa) << 24) |
        (chan((src >> 16) & 0xFF, (dst >> 16) & 0xFF, sa, da, oa) << 16) |
        (chan((src >> 8) & 0xFF, (dst >> 8) & 0xFF, sa, da, oa) << 8) | a;
}

/// M3 color roles — one scheme (light or dark). Baseline values published by
/// Google; M3E keeps the same roles.
pub const ColorScheme = struct {
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
    @"error": Color, // keyword — quoted identifier keeps the M3 role name
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
    background: Color, // deprecated in M3 in favor of surface; kept for completeness
    on_background: Color,
    outline: Color,
    outline_variant: Color,
    inverse_surface: Color,
    inverse_on_surface: Color,
    inverse_primary: Color,
    surface_tint: Color, // = primary
    surface_bright: Color,
    surface_dim: Color,
    scrim: Color,
    shadow: Color,

    /// Upstream ColorScheme.surfaceColorAtElevation (ColorScheme.kt:1157):
    /// the M3 tonal-elevation overlay — `surface_tint` at alpha
    /// `(4.5·ln(e+1)+2)/100` composited over `surface`. Elevation ≤ 0 →
    /// `surface` unchanged.
    pub fn surfaceColorAtElevation(cs: ColorScheme, elevation_dp: f32) Color {
        if (elevation_dp <= 0) return cs.surface;
        const alpha = (4.5 * @log(elevation_dp + 1) + 2) / 100;
        return compositeOver(withAlpha(cs.surface_tint, alpha), cs.surface);
    }

    /// Upstream ColorScheme.applyTonalElevation (ColorScheme.kt:1566): the
    /// overlay applies ONLY when `background` IS the scheme `surface` AND
    /// tonal elevation is `enabled` (the LocalTonalElevationEnabled local —
    /// supplied by Theme.tonal_elevation_enabled). A surface_container_*
    /// container fails the gate and passes through unchanged — which is why
    /// M3E's default token set paints zero tonal elevation (every elevated
    /// container resolves to a surface_container_* role, and every
    /// `surface` container sits at Level0).
    ///
    /// Upstream also accumulates LocalAbsoluteTonalElevation down the
    /// Surface tree; Klaxon has no Surface primitive or tree locals — each
    /// widget's own elevation is the whole term.
    pub fn applyTonalElevation(cs: ColorScheme, background: Color, elevation_dp: f32, enabled: bool) Color {
        return if (background == cs.surface and enabled) cs.surfaceColorAtElevation(elevation_dp) else background;
    }
};

/// M3E dynamic-scheme variant — which DynamicScheme algorithm generates the
/// color roles in Theme.fromSeedColor / Theme.fromImage. Re-export of
/// dynamic_color.Variant (enum over the nine schemes deps/mcu/kx_mcu.h
/// exposes) so theme consumers need a single import. `tonal_spot` is the M3
/// baseline: low-chroma pastels, the Android 12+ default.
pub const Scheme = dynamic_color.Variant;

/// One M3 type style: font size, line height (px at scale 1), weight
/// (400/500), letter spacing (px at scale 1 — the M3 tracking values).
pub const TypeStyle = struct {
    size: f32,
    line_height: f32,
    weight: u16,
    letter_spacing: f32,
};

/// M3 type scale: 5 roles x 3 sizes.
pub const TypeScale = struct {
    display_large: TypeStyle,
    display_medium: TypeStyle,
    display_small: TypeStyle,
    headline_large: TypeStyle,
    headline_medium: TypeStyle,
    headline_small: TypeStyle,
    title_large: TypeStyle,
    title_medium: TypeStyle,
    title_small: TypeStyle,
    body_large: TypeStyle,
    body_medium: TypeStyle,
    body_small: TypeStyle,
    label_large: TypeStyle,
    label_medium: TypeStyle,
    label_small: TypeStyle,
};

/// M3 shape scale (corner radii, px). "Full" (pill) has no fixed token —
/// components compute it as height/2. M3E added `large_increased` (20) and
/// `extra_extra_large` (48) to the classic five-step scale.
pub const Shape = struct {
    extra_small: f32, // 4
    small: f32, // 8
    medium: f32, // 12
    large: f32, // 16
    large_increased: f32, // 20 (M3E)
    extra_large: f32, // 28
    extra_extra_large: f32, // 48 (M3E)
};

/// One elevation level as a raster shadow approximation. M3 specifies
/// key/ambient umbra+penumbra shadows; the raster backend draws a single
/// blurred offset shadow — these values approximate the M3 levels.
///
/// Reference-only: widgets draw elevation parametrically through
/// ui.paint.elevationShadow (SkShadowUtils ambient+spot from the elevation
/// dp), which this per-level table cannot express. It documents the shape
/// of the M3 levels for consumers that want a stand-in (e.g. an HTML/CSS
/// export); it is not a widget contract — no widget reads it.
pub const Shadow = struct {
    dy: f32,
    blur: f32,
    alpha: f32,
};

/// M3 elevation levels 0-5. Descriptive reference only — widgets take an
/// elevation dp to ui.paint.elevationShadow (the SkShadowUtils ambient+spot
/// pair); they do not raster from these Shadow values (see the Shadow doc).
pub const Elevation = struct {
    level0: Shadow,
    level1: Shadow,
    level2: Shadow,
    level3: Shadow,
    level4: Shadow,
    level5: Shadow,
};

/// M3 duration scale (ms).
pub const Durations = struct {
    short1: u32,
    short2: u32,
    short3: u32,
    short4: u32,
    medium1: u32,
    medium2: u32,
    medium3: u32,
    medium4: u32,
    long1: u32,
    long2: u32,
    long3: u32,
    long4: u32,
};

/// A cubic-bezier easing (CSS-style control points; endpoints fixed at
/// (0,0)/(1,1)). Samples through ui.anim.cubicBezier.
pub const Bezier = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,

    pub fn sample(b: Bezier, t: f32) f32 {
        return anim.cubicBezier(b.x1, b.y1, b.x2, b.y2, t);
    }
};

/// M3 easing curves. Per the M3 spec, `emphasized` and `standard` share the
/// same curve (0.2, 0, 0, 1) — the emphasized family differs through its
/// accelerate/decelerate variants, all exposed here.
pub const Easings = struct {
    standard: Bezier, // (0.2, 0, 0, 1)
    standard_accelerate: Bezier, // (0.3, 0, 1, 1)
    standard_decelerate: Bezier, // (0, 0, 0, 1)
    emphasized: Bezier, // (0.2, 0, 0, 1)
    emphasized_accelerate: Bezier, // (0.3, 0, 0.8, 0.15)
    emphasized_decelerate: Bezier, // (0.05, 0.7, 0.1, 1)
};

/// M3E spring presets — the ExpressiveMotionTokens scheme (stiffness +
/// damping ratio, converted to the anim.Spring parameterization
/// c = 2*zeta*sqrt(k*m)): default/spatial ride DefaultSpatial (380, 0.8);
/// effects rides DefaultEffects (1600, 1.0) — effects springs are
/// CRITICALLY damped so colors/fractions never overshoot. fast_*/slow_*
/// expose the remaining four tokens (FastSpatial 800/0.6, FastEffects
/// 3800/1.0, SlowSpatial 200/0.8, SlowEffects 800/1.0) for widgets whose
/// upstream source names them (Switch thumb, TextField label = FastSpatial;
/// NavigationDrawer close = FastEffects).
pub const Springs = struct {
    default_spring: anim.Spring,
    spatial_spring: anim.Spring,
    effects_spring: anim.Spring,
    fast_spatial: anim.Spring,
    fast_effects: anim.Spring,
    slow_spatial: anim.Spring,
    slow_effects: anim.Spring,
};

pub const Motion = struct {
    durations: Durations,
    easings: Easings,
    springs: Springs,
};

/// M3 state-layer opacities (the on-color blended over the base).
pub const StateLayers = struct {
    hover: f32, // 0.08
    focus: f32, // 0.10
    pressed: f32, // 0.12
    drag: f32, // 0.16
};

/// Spacing scale (px). M3 does not publish spacing tokens; this is the
/// conventional 4-based scale used across M3 implementations.
///
/// A scale reference for APP layout (screens, cards-in-a-flow margins) —
/// not a widget contract: components carry their own padding/gap tokens
/// (e.g. ButtonDefaults.contentPaddingFor, MenuListItemContainerHeight's
/// insets), so no widget reads `theme.spacing`. Pair with
/// `platform.spacing_scale` when an app wants density-aware page margins.
pub const Spacing = struct {
    xs: f32,
    s: f32,
    m: f32,
    l: f32,
    xl: f32,
    xxl: f32,
};

/// Platform density (Phase 2d-0.5): M3E is mobile-first; the desktop gap is
/// a token layer, never per-widget decisions.
pub const Density = enum { mobile, desktop };

/// Scrollbar behavior (Phase 2d-0.5): classic (permanent, takes layout
/// space — GTK), overlay (floats over the content, appears on scroll/hover
/// — macOS), auto_hide (takes layout space, hidden at rest — Windows).
pub const ScrollbarStyle = enum { classic, overlay, auto_hide };

/// Platform adaptation tokens: control heights, hit targets, spacing scale,
/// scrollbar style, focus ring, cursors. Behavior is borrowed from Apple
/// HIG / Fluent / GTK — never their visuals.
pub const PlatformTokens = struct {
    density: Density = .mobile,
    /// Control heights: 48dp mobile (M3E spec), 40dp desktop (comfortable).
    control_height: f32 = 48,
    /// Minimum pointer hit target (a11y floor): 48dp mobile, 24dp desktop.
    hit_target_min: f32 = 48,
    /// Spacing multiplier (denser layout on desktop): 1.0 mobile, 0.9 desktop.
    spacing_scale: f32 = 1.0,
    scrollbar_style: ScrollbarStyle = .classic,
    scrollbar_width: f32 = 8,
    /// Host-painted focus ring (Phase 2c): width + offset from the control.
    focus_ring_width: f32 = 2,
    focus_ring_offset: f32 = 3,
    /// Pointer cursors (hand/ibeam/...) mapped by the host on desktop.
    cursors: bool = false,
};

const type_scale: TypeScale = .{
    .display_large = .{ .size = 57, .line_height = 64, .weight = 400, .letter_spacing = -0.25 },
    .display_medium = .{ .size = 45, .line_height = 52, .weight = 400, .letter_spacing = 0 },
    .display_small = .{ .size = 36, .line_height = 44, .weight = 400, .letter_spacing = 0 },
    .headline_large = .{ .size = 32, .line_height = 40, .weight = 400, .letter_spacing = 0 },
    .headline_medium = .{ .size = 28, .line_height = 36, .weight = 400, .letter_spacing = 0 },
    .headline_small = .{ .size = 24, .line_height = 32, .weight = 400, .letter_spacing = 0 },
    .title_large = .{ .size = 22, .line_height = 28, .weight = 400, .letter_spacing = 0 },
    .title_medium = .{ .size = 16, .line_height = 24, .weight = 500, .letter_spacing = 0.15 },
    .title_small = .{ .size = 14, .line_height = 20, .weight = 500, .letter_spacing = 0.1 },
    .body_large = .{ .size = 16, .line_height = 24, .weight = 400, .letter_spacing = 0.5 },
    .body_medium = .{ .size = 14, .line_height = 20, .weight = 400, .letter_spacing = 0.25 },
    .body_small = .{ .size = 12, .line_height = 16, .weight = 400, .letter_spacing = 0.4 },
    .label_large = .{ .size = 14, .line_height = 20, .weight = 500, .letter_spacing = 0.1 },
    .label_medium = .{ .size = 12, .line_height = 16, .weight = 500, .letter_spacing = 0.5 },
    .label_small = .{ .size = 11, .line_height = 16, .weight = 500, .letter_spacing = 0.5 },
};

const shape: Shape = .{ .extra_small = 4, .small = 8, .medium = 12, .large = 16, .large_increased = 20, .extra_large = 28, .extra_extra_large = 48 };

const elevation: Elevation = .{
    .level0 = .{ .dy = 0, .blur = 0, .alpha = 0 },
    .level1 = .{ .dy = 1, .blur = 3, .alpha = 0.10 }, // 1dp
    .level2 = .{ .dy = 1, .blur = 6, .alpha = 0.12 }, // 3dp
    .level3 = .{ .dy = 2, .blur = 10, .alpha = 0.14 }, // 6dp
    .level4 = .{ .dy = 3, .blur = 14, .alpha = 0.16 }, // 8dp
    .level5 = .{ .dy = 4, .blur = 18, .alpha = 0.18 }, // 12dp
};

const motion: Motion = .{
    .durations = .{
        .short1 = 50,
        .short2 = 100,
        .short3 = 150,
        .short4 = 200,
        .medium1 = 250,
        .medium2 = 300,
        .medium3 = 350,
        .medium4 = 400,
        .long1 = 450,
        .long2 = 500,
        .long3 = 550,
        .long4 = 600,
    },
    .easings = .{
        .standard = .{ .x1 = 0.2, .y1 = 0.0, .x2 = 0.0, .y2 = 1.0 },
        .standard_accelerate = .{ .x1 = 0.3, .y1 = 0.0, .x2 = 1.0, .y2 = 1.0 },
        .standard_decelerate = .{ .x1 = 0.0, .y1 = 0.0, .x2 = 0.0, .y2 = 1.0 },
        .emphasized = .{ .x1 = 0.2, .y1 = 0.0, .x2 = 0.0, .y2 = 1.0 },
        .emphasized_accelerate = .{ .x1 = 0.3, .y1 = 0.0, .x2 = 0.8, .y2 = 0.15 },
        .emphasized_decelerate = .{ .x1 = 0.05, .y1 = 0.7, .x2 = 0.1, .y2 = 1.0 },
    },
    .springs = .{
        // ExpressiveMotionTokens — was a Standard/Expressive hybrid
        // ((1400,0.8)/(700,0.8)/(3800,0.9)) that matched no published scheme
        // and left effects underdamped (ζ 0.9 → color/fraction overshoot).
        .default_spring = anim.Spring.fromDampingRatio(380, 0.8, 1), // DefaultSpatial
        .spatial_spring = anim.Spring.fromDampingRatio(380, 0.8, 1), // DefaultSpatial
        .effects_spring = anim.Spring.fromDampingRatio(1600, 1.0, 1), // DefaultEffects
        .fast_spatial = anim.Spring.fromDampingRatio(800, 0.6, 1), // FastSpatial
        .fast_effects = anim.Spring.fromDampingRatio(3800, 1.0, 1), // FastEffects
        .slow_spatial = anim.Spring.fromDampingRatio(200, 0.8, 1), // SlowSpatial
        .slow_effects = anim.Spring.fromDampingRatio(800, 1.0, 1), // SlowEffects
    },
};

const state_layers: StateLayers = .{ .hover = 0.08, .focus = 0.10, .pressed = 0.12, .drag = 0.16 };

const spacing: Spacing = .{ .xs = 4, .s = 8, .m = 12, .l = 16, .xl = 24, .xxl = 32 };

const platform_mobile: PlatformTokens = .{};
const platform_desktop: PlatformTokens = .{
    .density = .desktop,
    .control_height = 40, // comfortable (macOS-like)
    .hit_target_min = 24,
    .spacing_scale = 0.9,
    .scrollbar_style = .overlay, // macOS-style: floats, auto-hides
    .focus_ring_width = 3, // HIG-like: thicker ring, closer to the control
    .focus_ring_offset = 2,
    .cursors = true,
};

/// A complete theme: every design token a widget needs. Copy and override
/// fields (or the whole value) to reskin — widgets read tokens, never
/// hardcode them. Field defaults are the light scheme, so `Theme{}` is a
/// valid theme (and `optionsFromValue` can build a partial override object).
pub const Theme = struct {
    name: []const u8 = "light",
    colors: ColorScheme = light_colors,
    /// Mirrors upstream LocalTonalElevationEnabled (ColorScheme.kt:1582):
    /// when false, applyTonalElevation never resolves the surface_tint
    /// overlay — a subtree opt-out. Klaxon has no composition locals; the
    /// Theme IS the ambient value, so hand a subtree a Theme copy with this
    /// field false.
    tonal_elevation_enabled: bool = true,
    type_scale: TypeScale = type_scale,
    shape: Shape = shape,
    /// Descriptive reference of the M3 levels — widgets raster shadows
    /// parametrically (ui.paint.elevationShadow), not from this table.
    elevation: Elevation = elevation,
    motion: Motion = motion,
    state: StateLayers = state_layers,
    /// App-layout scale reference — widgets use their own component padding
    /// tokens, so no widget reads this field.
    spacing: Spacing = spacing,
    platform: PlatformTokens = platform_mobile,

    /// Upstream ColorScheme.applyTonalElevation (ColorScheme.kt:1566) with
    /// the LocalTonalElevationEnabled flag supplied by this theme
    /// (`tonal_elevation_enabled`). Widgets call this where their upstream
    /// Surface() received a tonalElevation — see ColorScheme.applyTonalElevation.
    pub fn applyTonalElevation(t: Theme, background: Color, elevation_dp: f32) Color {
        return t.colors.applyTonalElevation(background, elevation_dp, t.tonal_elevation_enabled);
    }

    /// Dynamic theme (Phase 2d): resolve every color role from a seed color
    /// through material-color-utilities (src/dynamic_color.zig → deps/mcu)
    /// at the M3 baseline — the `tonal_spot` variant (Android 12+ default)
    /// at default contrast. `seed` is a 0xRRGGBBAA Color like every other
    /// here (its alpha is ignored — generated roles are opaque); `dark_mode`
    /// selects the dark scheme.
    ///
    /// Only colors are generated: the non-color tokens (type, shape,
    /// elevation, motion, state, spacing, platform) come from the matching
    /// baseline preset. The role mapping is exact — Scheme.toColorScheme
    /// copies all 38 roles by field name and fails to compile if the two
    /// structs ever drift apart.
    pub fn fromSeedColor(seed: Color, dark_mode: bool) Theme {
        return fromSeedColorScheme(seed, dark_mode, .tonal_spot, 0);
    }

    /// fromSeedColor with the full DynamicScheme controls: `scheme` picks
    /// the M3E variant (tonal_spot/expressive/vibrant/... — all nine schemes
    /// deps/mcu exposes) and `contrast_level` is [-1, 1] — 0 is the WCAG AA
    /// default, >0 pushes text-on-color pairs further apart.
    pub fn fromSeedColorScheme(seed: Color, dark_mode: bool, scheme: Scheme, contrast_level: f64) Theme {
        var t: Theme = if (dark_mode) dark else light;
        t.name = if (dark_mode) "dynamic dark" else "dynamic light";
        t.colors = dynamic_color.scheme(seed, scheme, dark_mode, contrast_level).toColorScheme(ColorScheme);
        return t;
    }

    /// Dynamic theme from an image (Phase 2d): quantize `rgba_pixels`
    /// (Celebi/Wu), rank the palette by MCU Score suitability — the same
    /// pipeline Android uses for wallpaper "Material You" themes — then
    /// build the scheme from the winning seed, at the M3 baseline
    /// (tonal_spot, default contrast, Google Blue fallback). `rgba_pixels`
    /// holds at least `width * height * 4` bytes in straight R,G,B,A order;
    /// fully transparent pixels are ignored.
    pub fn fromImage(rgba_pixels: []const u8, width: u32, height: u32, dark_mode: bool) Theme {
        return fromImageScheme(rgba_pixels, width, height, dark_mode, .tonal_spot, 0, 0x4285F4FF);
    }

    /// fromImage with the full controls — `scheme`/`contrast_level` as in
    /// fromSeedColorScheme; `fallback_seed` applies when the buffer is empty
    /// or contains no visible pixel (every alpha == 0 — the quantizer's own
    /// filter, mirrored here so the caller's fallback wins over MCU's
    /// built-in Google Blue).
    pub fn fromImageScheme(
        rgba_pixels: []const u8,
        width: u32,
        height: u32,
        dark_mode: bool,
        scheme: Scheme,
        contrast_level: f64,
        fallback_seed: Color,
    ) Theme {
        const byte_len = @as(u64, width) * height * 4;
        std.debug.assert(rgba_pixels.len >= byte_len);
        const pixels = rgba_pixels[0..@intCast(byte_len)];
        // Early-exit scan matching the quantizer's skip rule (alpha == 0):
        // typical images exit after a few pixels; only all-transparent
        // buffers pay the full pass — and they take the fallback anyway.
        var any_visible = false;
        for (0..pixels.len / 4) |i| {
            if (pixels[i * 4 + 3] != 0) {
                any_visible = true;
                break;
            }
        }
        const seed = if (any_visible)
            dynamic_color.dominantColor(pixels, fallback_seed)
        else
            fallback_seed;
        return fromSeedColorScheme(seed, dark_mode, scheme, contrast_level);
    }
};

/// M3 baseline light scheme.
const light_colors: ColorScheme = .{
    .primary = 0x6750A4FF,
    .on_primary = 0xFFFFFFFF,
    .primary_container = 0xEADDFFFF,
    .on_primary_container = 0x21005DFF,
    .secondary = 0x625B71FF,
    .on_secondary = 0xFFFFFFFF,
    .secondary_container = 0xE8DEF8FF,
    .on_secondary_container = 0x1D192BFF,
    .tertiary = 0x7D5260FF,
    .on_tertiary = 0xFFFFFFFF,
    .tertiary_container = 0xFFD8E4FF,
    .on_tertiary_container = 0x31111DFF,
    .@"error" = 0xB3261EFF,
    .on_error = 0xFFFFFFFF,
    .error_container = 0xF9DEDCFF,
    .on_error_container = 0x410E0BFF,
    .surface = 0xFEF7FFFF,
    .on_surface = 0x1D1B20FF,
    .surface_variant = 0xE7E0ECFF,
    .on_surface_variant = 0x49454FFF,
    .surface_container_lowest = 0xFFFFFFFF,
    .surface_container_low = 0xF7F2FAFF,
    .surface_container = 0xF3EDF7FF,
    .surface_container_high = 0xECE6F0FF,
    .surface_container_highest = 0xE6E0E9FF,
    .background = 0xFEF7FFFF,
    .on_background = 0x1D1B20FF,
    .outline = 0x79747EFF,
    .outline_variant = 0xCAC4D0FF,
    .inverse_surface = 0x322F35FF,
    .inverse_on_surface = 0xF5EFF7FF,
    .inverse_primary = 0xD0BCFFFF,
    .surface_tint = 0x6750A4FF,
    .surface_bright = 0xFEF7FFFF,
    .surface_dim = 0xDED8E1FF,
    .scrim = 0x000000FF,
    .shadow = 0x000000FF,
};

/// M3 baseline dark scheme.
const dark_colors: ColorScheme = .{
    .primary = 0xD0BCFFFF,
    .on_primary = 0x381E72FF,
    .primary_container = 0x4F378BFF,
    .on_primary_container = 0xEADDFFFF,
    .secondary = 0xCCC2DCFF,
    .on_secondary = 0x332D41FF,
    .secondary_container = 0x4A4458FF,
    .on_secondary_container = 0xE8DEF8FF,
    .tertiary = 0xEFB8C8FF,
    .on_tertiary = 0x492532FF,
    .tertiary_container = 0x633B48FF,
    .on_tertiary_container = 0xFFD8E4FF,
    .@"error" = 0xF2B8B5FF,
    .on_error = 0x601410FF,
    .error_container = 0x8C1D18FF,
    .on_error_container = 0xF9DEDCFF,
    .surface = 0x141218FF,
    .on_surface = 0xE6E0E9FF,
    .surface_variant = 0x49454FFF,
    .on_surface_variant = 0xCAC4D0FF,
    .surface_container_lowest = 0x0F0D13FF,
    .surface_container_low = 0x1D1B20FF,
    .surface_container = 0x211F26FF,
    .surface_container_high = 0x2B2930FF,
    .surface_container_highest = 0x36343BFF,
    .background = 0x141218FF,
    .on_background = 0xE6E0E9FF,
    .outline = 0x938F99FF,
    .outline_variant = 0x49454FFF,
    .inverse_surface = 0xE6E0E9FF,
    .inverse_on_surface = 0x322F35FF,
    .inverse_primary = 0x6750A4FF,
    .surface_tint = 0xD0BCFFFF,
    .surface_bright = 0x3B383EFF,
    .surface_dim = 0x141218FF,
    .scrim = 0x000000FF,
    .shadow = 0x000000FF,
};

pub const light: Theme = .{
    .name = "light",
    .colors = light_colors,
    .type_scale = type_scale,
    .shape = shape,
    .elevation = elevation,
    .motion = motion,
    .state = state_layers,
    .spacing = spacing,
};

pub const dark: Theme = .{
    .name = "dark",
    .colors = dark_colors,
    .type_scale = type_scale,
    .shape = shape,
    .elevation = elevation,
    .motion = motion,
    .state = state_layers,
    .spacing = spacing,
};

/// Desktop presets (Phase 2d-0.5): the same M3E schemes with the platform
/// layer set to desktop (40dp comfortable controls, denser spacing, overlay
/// scrollbars, pointer cursors).
pub const desktop_light: Theme = .{
    .name = "desktop light",
    .colors = light_colors,
    .type_scale = type_scale,
    .shape = shape,
    .elevation = elevation,
    .motion = motion,
    .state = state_layers,
    .spacing = spacing,
    .platform = platform_desktop,
};

pub const desktop_dark: Theme = .{
    .name = "desktop dark",
    .colors = dark_colors,
    .type_scale = type_scale,
    .shape = shape,
    .elevation = elevation,
    .motion = motion,
    .state = state_layers,
    .spacing = spacing,
    .platform = platform_desktop,
};

// --- tests ---

test "theme: stateLayer blends the on-color at the state alpha" {
    const a: Color = 0x000000FF;
    const b: Color = 0xFFFFFFFF;
    try std.testing.expectEqual(a, anim.lerpColor(a, b, 0));
    try std.testing.expectEqual(b, anim.lerpColor(a, b, 1));
    try std.testing.expectEqual(b, anim.lerpColor(a, b, 2)); // clamped
    try std.testing.expectEqual(0x7F7F7FFF, anim.lerpColor(a, b, 0.5)); // truncating: 127.5 → 127
    try std.testing.expectEqual(
        anim.lerpColor(dark.colors.primary, dark.colors.on_primary, 0.08),
        stateLayer(dark.colors.primary, dark.colors.on_primary, dark.state.hover),
    );
}

test "theme: schemes are opaque, distinct, and WCAG-contrastive" {
    inline for (.{ light.colors, dark.colors }) |cs| {
        inline for (@typeInfo(ColorScheme).@"struct".field_names) |name| {
            try std.testing.expectEqual(@as(u8, 0xFF), @as(u8, @truncate(@field(cs, name) & 0xFF)));
        }
    }
    try std.testing.expect(light.colors.primary != dark.colors.primary);
    try std.testing.expect(light.colors.surface != dark.colors.surface);
    // M3 guarantees >= 4.5:1 for text on its container — every on-color /
    // container pair, both schemes (containers have dedicated on-colors;
    // surface containers take on_surface).
    inline for (.{ light.colors, dark.colors }) |cs| {
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
            .{ cs.surface_container, cs.on_surface },
            .{ cs.surface_container_high, cs.on_surface },
            .{ cs.surface_container_highest, cs.on_surface },
            .{ cs.inverse_surface, cs.inverse_on_surface },
        };
        inline for (pairs) |p| {
            try std.testing.expect(contrastRatio(p[0], p[1]) >= 4.5);
        }
    }
}

test "theme: type scale matches the M3 spec" {
    const ts = light.type_scale;
    try std.testing.expectEqual(@as(f32, 57), ts.display_large.size);
    try std.testing.expectEqual(@as(f32, 64), ts.display_large.line_height);
    try std.testing.expectEqual(@as(u16, 500), ts.title_medium.weight);
    try std.testing.expectEqual(@as(f32, 11), ts.label_small.size);
    inline for (@typeInfo(TypeScale).@"struct".field_names) |name| {
        const st: TypeStyle = @field(ts, name);
        try std.testing.expect(st.line_height >= st.size);
        try std.testing.expect(st.weight == 400 or st.weight == 500);
    }
}

test "theme: motion tokens are ordered and springs settle" {
    const m = light.motion;
    try std.testing.expect(m.durations.short1 < m.durations.short4);
    try std.testing.expect(m.durations.short4 < m.durations.medium1);
    try std.testing.expect(m.durations.medium4 < m.durations.long1);
    try std.testing.expect(m.durations.long1 < m.durations.long4);
    inline for (@typeInfo(Easings).@"struct".field_names) |name| {
        const b: Bezier = @field(m.easings, name);
        try std.testing.expectApproxEqAbs(@as(f32, 0), b.sample(0), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1), b.sample(1), 1e-4);
    }
    // Springs settle on target (closed form, tick-rate independent) — all
    // seven presets of the Expressive scheme.
    inline for (@typeInfo(Springs).@"struct".field_names) |name| {
        const s: anim.Spring = @field(m.springs, name);
        try std.testing.expect(@abs(s.displacement(100, 0, 5.0)) < 0.5);
    }
    // Effects springs are critically damped (ζ = 1) — a color or progress
    // fraction must never overshoot (ExpressiveMotionTokens.kt:24-33).
    try std.testing.expect(m.springs.effects_spring.displacement(1, 0, 0.3) <= 1.0);
}

test "theme: light and dark share the non-color tokens" {
    try std.testing.expectEqual(light.type_scale.display_large.size, dark.type_scale.display_large.size);
    try std.testing.expectEqual(light.shape.medium, dark.shape.medium);
    try std.testing.expectEqual(light.motion.durations.medium2, dark.motion.durations.medium2);
    try std.testing.expectEqual(light.state.hover, dark.state.hover);
    try std.testing.expectEqual(light.spacing.m, dark.spacing.m);
    try std.testing.expectEqual(light.platform.control_height, dark.platform.control_height);
}

test "theme: platform tokens — mobile defaults, desktop presets" {
    // Theme{} is the mobile platform (M3E spec values)
    const t = Theme{};
    try std.testing.expectEqual(Density.mobile, t.platform.density);
    try std.testing.expectEqual(@as(f32, 48), t.platform.control_height);
    try std.testing.expectEqual(@as(f32, 48), t.platform.hit_target_min);
    try std.testing.expectEqual(@as(f32, 1.0), t.platform.spacing_scale);
    try std.testing.expectEqual(ScrollbarStyle.classic, t.platform.scrollbar_style);
    try std.testing.expect(!t.platform.cursors);
    try std.testing.expectEqual(@as(f32, 2), t.platform.focus_ring_width);
    try std.testing.expectEqual(@as(f32, 3), t.platform.focus_ring_offset);
    // the mobile presets stay mobile
    try std.testing.expectEqual(Density.mobile, light.platform.density);
    try std.testing.expectEqual(Density.mobile, dark.platform.density);
    // desktop presets: comfortable 40dp, denser spacing, overlay scrollbar, cursors
    inline for (.{ desktop_light, desktop_dark }) |dt| {
        try std.testing.expectEqual(Density.desktop, dt.platform.density);
        try std.testing.expectEqual(@as(f32, 40), dt.platform.control_height);
        try std.testing.expectEqual(@as(f32, 24), dt.platform.hit_target_min);
        try std.testing.expectEqual(@as(f32, 0.9), dt.platform.spacing_scale);
        try std.testing.expectEqual(ScrollbarStyle.overlay, dt.platform.scrollbar_style);
        try std.testing.expect(dt.platform.cursors);
        try std.testing.expectEqual(@as(f32, 3), dt.platform.focus_ring_width);
        try std.testing.expectEqual(@as(f32, 2), dt.platform.focus_ring_offset);
    }
    // desktop presets keep the M3E schemes
    try std.testing.expectEqual(light.colors.primary, desktop_light.colors.primary);
    try std.testing.expectEqual(dark.colors.primary, desktop_dark.colors.primary);
    try std.testing.expect(desktop_light.colors.primary != desktop_dark.colors.primary);
}

test "theme: fromSeedColor — Google Blue seed reproduces the MCU tonal_spot roles" {
    // Anchors are the vendored MCU's exact output (deps/mcu, pinned to
    // material-foundation 5b3618b): seed 0x4285F4 (Google Blue) through the
    // tonal_spot DynamicScheme — known-good upstream values, not
    // approximations.
    const lt = Theme.fromSeedColor(0x4285F4FF, false);
    try std.testing.expectEqual(@as(Color, 0x445E91FF), lt.colors.primary);
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), lt.colors.on_primary);
    try std.testing.expectEqual(@as(Color, 0xD8E2FFFF), lt.colors.primary_container);
    try std.testing.expectEqual(@as(Color, 0x2B4678FF), lt.colors.on_primary_container);
    try std.testing.expectEqual(@as(Color, 0xBA1A1AFF), lt.colors.@"error");
    try std.testing.expectEqual(@as(Color, 0xF9F9FFFF), lt.colors.surface);

    const dk = Theme.fromSeedColor(0x4285F4FF, true);
    try std.testing.expectEqual(@as(Color, 0xADC6FFFF), dk.colors.primary);
    try std.testing.expectEqual(@as(Color, 0x102F60FF), dk.colors.on_primary);
    try std.testing.expectEqual(@as(Color, 0xFFB4ABFF), dk.colors.@"error");
    // The dark scheme's inverse_primary IS the light scheme's primary.
    try std.testing.expectEqual(lt.colors.primary, dk.colors.inverse_primary);

    // light vs dark are genuinely different schemes, and both are named.
    try std.testing.expect(lt.colors.primary != dk.colors.primary);
    try std.testing.expect(lt.colors.surface != dk.colors.surface);
    try std.testing.expectEqualStrings("dynamic light", lt.name);
    try std.testing.expectEqualStrings("dynamic dark", dk.name);
}

test "theme: fromSeedColor fills every color role — opaque, no sentinel leftovers" {
    inline for (.{ false, true }) |dark_mode| {
        const t = Theme.fromSeedColor(0x6750A4FF, dark_mode);
        inline for (@typeInfo(ColorScheme).@"struct".field_names) |name| {
            const c: Color = @field(t.colors, name);
            // 0x00000000 would mean the MCU write never landed (a leftover
            // sentinel); every M3 role is emitted opaque.
            try std.testing.expect(c != 0);
            try std.testing.expectEqual(@as(u8, 0xFF), @as(u8, @truncate(c)));
        }
        // Non-color tokens ride the baseline presets, untouched by the seed.
        try std.testing.expectEqual(light.type_scale.display_large.size, t.type_scale.display_large.size);
        try std.testing.expectEqual(light.shape.medium, t.shape.medium);
        try std.testing.expectEqual(light.motion.durations.medium2, t.motion.durations.medium2);
        try std.testing.expectEqual(light.state.hover, t.state.hover);
        try std.testing.expectEqual(light.platform.control_height, t.platform.control_height);
    }
    // surface_tint aliases primary — the M3 rule, verified end-to-end.
    const t = Theme.fromSeedColor(0x6750A4FF, false);
    try std.testing.expectEqual(t.colors.primary, t.colors.surface_tint);
}

test "theme: fromSeedColorScheme — all nine M3E variants hold WCAG pairs" {
    inline for (@typeInfo(Scheme).@"enum".field_values) |v| {
        const cs = Theme.fromSeedColorScheme(0x4285F4FF, false, @fromBackingInt(@intCast(v)), 0).colors;
        try std.testing.expectEqual(@as(u8, 0xFF), @as(u8, @truncate(cs.primary)));
        // M3 guarantees >= 4.5:1 on the flagship pairs at default contrast.
        try std.testing.expect(contrastRatio(cs.primary, cs.on_primary) >= 4.5);
        try std.testing.expect(contrastRatio(cs.surface, cs.on_surface) >= 4.5);
        try std.testing.expect(contrastRatio(cs.@"error", cs.on_error) >= 4.5);
    }
    // `scheme` actually selects the variant — expressive rotates the hues.
    try std.testing.expect(
        Theme.fromSeedColorScheme(0x4285F4FF, false, .expressive, 0).colors.primary !=
            Theme.fromSeedColorScheme(0x4285F4FF, false, .tonal_spot, 0).colors.primary,
    );
    // fromSeedColor is the tonal_spot baseline (M3 default).
    try std.testing.expectEqual(
        Theme.fromSeedColorScheme(0x4285F4FF, false, .tonal_spot, 0).colors,
        Theme.fromSeedColor(0x4285F4FF, false).colors,
    );
}

test "theme: fromImage — quantize+score extracts a seed, full scheme built" {
    // 32x32 RGBA8: ~87% Google Blue, rest dark speckle.
    var px: [32 * 32 * 4]u8 = undefined;
    for (0..32 * 32) |i| {
        const blue = i % 8 != 0;
        px[i * 4 + 0] = if (blue) 0x42 else 0x20;
        px[i * 4 + 1] = if (blue) 0x85 else 0x20;
        px[i * 4 + 2] = if (blue) 0xF4 else 0x30;
        px[i * 4 + 3] = 0xFF;
    }
    const t = Theme.fromImage(&px, 32, 32, false);
    // Every role populated — same populated-token invariant as fromSeedColor.
    inline for (@typeInfo(ColorScheme).@"struct".field_names) |name| {
        const c: Color = @field(t.colors, name);
        try std.testing.expect(c != 0);
        try std.testing.expectEqual(@as(u8, 0xFF), @as(u8, @truncate(c)));
    }
    // No drift between the two entry points: fromImage is exactly
    // quantize+score -> fromSeedColor over the winning seed.
    const seed = dynamic_color.dominantColor(&px, 0x4285F4FF);
    try std.testing.expectEqual(Theme.fromSeedColor(seed, false).colors, t.colors);
    // A blue-dominated image yields a blue-leaning primary (B above R).
    try std.testing.expect(t.colors.primary >> 8 & 0xFF > t.colors.primary >> 24 & 0xFF);
}

test "theme: fromImage — empty or fully transparent buffer uses the fallback seed" {
    const reference = Theme.fromSeedColor(0x6750A4FF, false).colors;
    const empty = Theme.fromImageScheme(&.{}, 0, 0, false, .tonal_spot, 0, 0x6750A4FF);
    try std.testing.expectEqual(reference, empty.colors);
    const transparent: [64]u8 = @splat(0); // 16 fully transparent pixels
    const t2 = Theme.fromImageScheme(&transparent, 4, 4, false, .tonal_spot, 0, 0x6750A4FF);
    try std.testing.expectEqual(reference, t2.colors);
}

// --- tonal elevation (ColorScheme.kt:1157-1161, 1566-1585) ---

/// Independent recompute of tint@alpha over opaque surface: per channel
/// (1-a)·surface + a·tint, alpha pinned opaque (the expected composite).
fn expectTintedSurface(surface: Color, tint: Color, alpha: f32) Color {
    const chan = struct {
        fn f(s: u32, tt: u32, a: f32) u32 {
            return @intFromFloat(std.math.clamp(@round(@as(f32, @floatFromInt(s)) * (1 - a) + @as(f32, @floatFromInt(tt)) * a), 0, 255));
        }
    }.f;
    return (chan((surface >> 24) & 0xFF, (tint >> 24) & 0xFF, alpha) << 24) |
        (chan((surface >> 16) & 0xFF, (tint >> 16) & 0xFF, alpha) << 16) |
        (chan((surface >> 8) & 0xFF, (tint >> 8) & 0xFF, alpha) << 8) | 0xFF;
}

test "theme: surfaceColorAtElevation — the upstream alpha curve at levels 0-5" {
    inline for (.{ light.colors, dark.colors }) |cs| {
        // Level0 is surface, untouched (ColorScheme.kt:1158).
        try std.testing.expectEqual(cs.surface, cs.surfaceColorAtElevation(0));
        // Levels 1-5 (1/3/6/8/12dp) against the upstream formula
        // alpha = (4.5·ln(e+1)+2)/100 (ColorScheme.kt:1159).
        const levels = [5]f32{ 1, 3, 6, 8, 12 };
        var prev_alpha: f32 = 0;
        for (levels) |e| {
            const alpha = (4.5 * @log(e + 1) + 2) / 100;
            try std.testing.expect(alpha > prev_alpha); // strictly increasing
            prev_alpha = alpha;
            try std.testing.expect(alpha > 0 and alpha < 0.2);
            const got = cs.surfaceColorAtElevation(e);
            try std.testing.expectEqual(@as(u8, 0xFF), @as(u8, @truncate(got))); // opaque
            const want = expectTintedSurface(cs.surface, cs.surface_tint, alpha);
            // compositeOver rounds identically — ±1 LSB tolerance per channel.
            inline for (.{ 24, 16, 8 }) |shift| {
                const gc: i32 = @intCast((got >> shift) & 0xFF);
                const wc: i32 = @intCast((want >> shift) & 0xFF);
                try std.testing.expect(@abs(gc - wc) <= 1);
            }
        }
    }
    // dark scheme lifts the surface (tint is lighter than surface there).
    try std.testing.expect(dark.colors.surfaceColorAtElevation(12) > dark.colors.surface);
}

test "theme: applyTonalElevation — the gate is surface-only and enabled-only" {
    const cs = light.colors;
    // surface + enabled + elev>0 → tinted (== surfaceColorAtElevation).
    try std.testing.expectEqual(cs.surfaceColorAtElevation(3), cs.applyTonalElevation(cs.surface, 3, true));
    try std.testing.expect(cs.applyTonalElevation(cs.surface, 3, true) != cs.surface);
    // elevation 0 short-circuits to surface either way (identity).
    try std.testing.expectEqual(cs.surface, cs.applyTonalElevation(cs.surface, 0, true));
    // a surface_container_* background fails the gate, elevation be damned —
    // THE reason M3E paints no tonal overlay by default.
    try std.testing.expectEqual(cs.surface_container, cs.applyTonalElevation(cs.surface_container, 6, true));
    try std.testing.expectEqual(cs.surface_container_low, cs.applyTonalElevation(cs.surface_container_low, 1, true));
    try std.testing.expectEqual(cs.inverse_surface, cs.applyTonalElevation(cs.inverse_surface, 6, true));
    // enabled=false (LocalTonalElevationEnabled off) → background unchanged.
    try std.testing.expectEqual(cs.surface, cs.applyTonalElevation(cs.surface, 6, false));

    // Theme.tonal_elevation_enabled supplies the flag (default true).
    try std.testing.expect((Theme{}).tonal_elevation_enabled);
    var t = light;
    try std.testing.expectEqual(cs.applyTonalElevation(cs.surface, 3, true), t.applyTonalElevation(cs.surface, 3));
    t.tonal_elevation_enabled = false;
    try std.testing.expectEqual(cs.surface, t.applyTonalElevation(cs.surface, 3));
}
