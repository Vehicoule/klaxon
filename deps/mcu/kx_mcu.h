// kx_mcu.h — Klaxon's C ABI over Google's material-color-utilities C++ port
// (deps/mcu/cpp). No C++ type crosses this boundary: Zig sees only plain
// integers, doubles and POD structs.
//
// Conventions:
//   - Colors are 0xRRGGBBAA (R in the high byte, alpha in the low byte) — the
//     same convention as kx_skia.h and theme.zig's Color. MCU's native ARGB is
//     converted inside the implementation; callers never see it.
//   - Tones are HCT tones in [0, 100]; hue in [0, 360); chroma >= 0.
//   - All functions are pure (no global state) and thread-safe.
//
// Version history:
//   0.1.0 — Phase 2d dynamic color: HCT roundtrip, tonal palettes, all nine
//           M3E scheme variants (light/dark/contrast), Celebi+Wu quantization
//           with Score ranking for image-driven seed colors.
#ifndef KX_MCU_H
#define KX_MCU_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// HCT color: CAM16 hue + chroma, L* tone.
typedef struct KxMcuHct {
  double hue;
  double chroma;
  double tone;
} KxMcuHct;

/// M3E scheme variants (subset order matches nothing upstream — explicit ABI).
typedef enum KxMcuVariant {
  KX_MCU_VARIANT_TONAL_SPOT = 0,  // Android default: low-chroma pastels.
  KX_MCU_VARIANT_EXPRESSIVE = 1,  // M3E default: rotated, playful hues.
  KX_MCU_VARIANT_VIBRANT = 2,     // max chroma at each tone.
  KX_MCU_VARIANT_NEUTRAL = 3,     // near-grayscale accents.
  KX_MCU_VARIANT_MONOCHROME = 4,  // pure grayscale.
  KX_MCU_VARIANT_FIDELITY = 5,    // seed color preserved as-is.
  KX_MCU_VARIANT_CONTENT = 6,     // like fidelity, tertiary analog-shifted.
  KX_MCU_VARIANT_RAINBOW = 7,     // seed in primary+tertiary accents.
  KX_MCU_VARIANT_FRUIT_SALAD = 8, // two-hue complementary pop.
} KxMcuVariant;

/// All M3 color roles resolved for one scheme. Field order mirrors
/// theme.zig's ColorScheme exactly — the Zig side copies field-by-field.
/// Extra M3 roles that ColorScheme lacks (fixed accents, palette key colors)
/// are not carried across — expose more here if theme.zig grows fields.
typedef struct KxMcuScheme {
  uint32_t primary;
  uint32_t on_primary;
  uint32_t primary_container;
  uint32_t on_primary_container;
  uint32_t secondary;
  uint32_t on_secondary;
  uint32_t secondary_container;
  uint32_t on_secondary_container;
  uint32_t tertiary;
  uint32_t on_tertiary;
  uint32_t tertiary_container;
  uint32_t on_tertiary_container;
  uint32_t error;
  uint32_t on_error;
  uint32_t error_container;
  uint32_t on_error_container;
  uint32_t surface;
  uint32_t on_surface;
  uint32_t surface_variant;
  uint32_t on_surface_variant;
  uint32_t surface_container_lowest;
  uint32_t surface_container_low;
  uint32_t surface_container;
  uint32_t surface_container_high;
  uint32_t surface_container_highest;
  uint32_t background;
  uint32_t on_background;
  uint32_t outline;
  uint32_t outline_variant;
  uint32_t inverse_surface;
  uint32_t inverse_on_surface;
  uint32_t inverse_primary;
  uint32_t surface_tint;
  uint32_t surface_bright;
  uint32_t surface_dim;
  uint32_t scrim;
  uint32_t shadow;
} KxMcuScheme;

/// HCT decomposition of a color.
KxMcuHct kx_mcu_hct_from_color(uint32_t rgba);

/// Color for (hue, chroma, tone); chroma clamps to the gamut maximum.
uint32_t kx_mcu_color_from_hct(double hue, double chroma, double tone);

/// TonalPalette seeded by `seed_rgba`, evaluated at `tone` in [0, 100].
uint32_t kx_mcu_tonal_color(uint32_t seed_rgba, double tone);

/// Batch form: writes `out[i]` = palette color at `tones[i]`. Returns n
/// (tones, out and n must agree; out may be null when n == 0).
size_t kx_mcu_tonal_palette(uint32_t seed_rgba, const double* tones,
                            uint32_t* out, size_t n);

/// Resolve every M3 color role for `variant` seeded by `seed_rgba`.
/// `dark` selects the dark scheme; `contrast_level` is [-1, 1] (0 = default
/// WCAG AA, 1 = high contrast, -1 = reduced). Writes 38 colors into `out`.
void kx_mcu_scheme(KxMcuVariant variant, uint32_t seed_rgba, bool dark,
                   double contrast_level, KxMcuScheme* out);

/// Dominant theme-suitable colors in an RGBA8 pixel buffer (4 bytes per
/// pixel, straight R,G,B,A order — fully transparent pixels are ignored).
/// Quantizes via Celebi (Wu + WSMeans), then ranks by Score's suitability
/// heuristic (chroma, usage share). Writes up to `cap` colors, best first;
/// returns the count written (always >= 1 — falls back to Google Blue when
/// nothing scores). `rgba_pixels` is `pixel_count * 4` bytes.
size_t kx_mcu_dominant_colors(const uint8_t* rgba_pixels, size_t pixel_count,
                              uint32_t* out, size_t cap);

/// M3 color harmonization: shift `design_rgba`'s hue toward `theme_rgba`'s
/// (keeps the design color's chroma/tone where possible). Used to blend a
/// custom accent into a generated scheme.
uint32_t kx_mcu_harmonize(uint32_t design_rgba, uint32_t theme_rgba);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // KX_MCU_H
