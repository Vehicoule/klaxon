// kx_mcu.cpp — extern "C" wrapper over deps/mcu/cpp (Google
// material-color-utilities, Apache-2.0 — see LICENSE, UPSTREAM.md in this dir).
//
// Boundary conventions (kx_mcu.h): colors are 0xRRGGBBAA — Klaxon's
// convention; MCU speaks 0xAARRGGBB, converted at the seam. Only POD types
// cross: u32 colors, f64 HCT components, the 38-field KxMcuScheme struct.

#include "kx_mcu.h"

#include <map>
#include <vector>

#include "cpp/blend/blend.h"
#include "cpp/cam/hct.h"
#include "cpp/dynamiccolor/dynamic_scheme.h"
#include "cpp/palettes/tones.h"
#include "cpp/quantize/celebi.h"
#include "cpp/scheme/scheme_content.h"
#include "cpp/scheme/scheme_expressive.h"
#include "cpp/scheme/scheme_fidelity.h"
#include "cpp/scheme/scheme_fruit_salad.h"
#include "cpp/scheme/scheme_monochrome.h"
#include "cpp/scheme/scheme_neutral.h"
#include "cpp/scheme/scheme_rainbow.h"
#include "cpp/scheme/scheme_tonal_spot.h"
#include "cpp/scheme/scheme_vibrant.h"
#include "cpp/score/score.h"
#include "cpp/utils/utils.h"

using material_color_utilities::Argb;
using material_color_utilities::DynamicScheme;
using material_color_utilities::Hct;
using material_color_utilities::QuantizerResult;
using material_color_utilities::SchemeContent;
using material_color_utilities::SchemeExpressive;
using material_color_utilities::SchemeFidelity;
using material_color_utilities::SchemeFruitSalad;
using material_color_utilities::SchemeMonochrome;
using material_color_utilities::SchemeNeutral;
using material_color_utilities::SchemeRainbow;
using material_color_utilities::SchemeTonalSpot;
using material_color_utilities::SchemeVibrant;
using material_color_utilities::ScoreOptions;
using material_color_utilities::TonalPalette;

namespace {

// 0xRRGGBBAA (Klaxon) <-> 0xAARRGGBB (MCU).
Argb ToArgb(uint32_t rgba) {
  return ((rgba & 0xFF) << 24) | (rgba >> 8);
}
uint32_t ToRgba(Argb argb) {
  return (argb << 8) | (argb >> 24);
}

DynamicScheme MakeScheme(KxMcuVariant variant, uint32_t seed_rgba, bool dark,
                         double contrast_level) {
  const Hct seed(ToArgb(seed_rgba));
  switch (variant) {
    case KX_MCU_VARIANT_TONAL_SPOT:
      return SchemeTonalSpot(seed, dark, contrast_level);
    case KX_MCU_VARIANT_EXPRESSIVE:
      return SchemeExpressive(seed, dark, contrast_level);
    case KX_MCU_VARIANT_VIBRANT:
      return SchemeVibrant(seed, dark, contrast_level);
    case KX_MCU_VARIANT_NEUTRAL:
      return SchemeNeutral(seed, dark, contrast_level);
    case KX_MCU_VARIANT_MONOCHROME:
      return SchemeMonochrome(seed, dark, contrast_level);
    case KX_MCU_VARIANT_FIDELITY:
      return SchemeFidelity(seed, dark, contrast_level);
    case KX_MCU_VARIANT_CONTENT:
      return SchemeContent(seed, dark, contrast_level);
    case KX_MCU_VARIANT_RAINBOW:
      return SchemeRainbow(seed, dark, contrast_level);
    case KX_MCU_VARIANT_FRUIT_SALAD:
      return SchemeFruitSalad(seed, dark, contrast_level);
  }
  return SchemeTonalSpot(seed, dark, contrast_level);  // unreachable
}

}  // namespace

KxMcuHct kx_mcu_hct_from_color(uint32_t rgba) {
  const Hct hct(ToArgb(rgba));
  return {hct.get_hue(), hct.get_chroma(), hct.get_tone()};
}

uint32_t kx_mcu_color_from_hct(double hue, double chroma, double tone) {
  return ToRgba(Hct(hue, chroma, tone).ToInt());
}

uint32_t kx_mcu_tonal_color(uint32_t seed_rgba, double tone) {
  return ToRgba(TonalPalette(ToArgb(seed_rgba)).get(tone));
}

size_t kx_mcu_tonal_palette(uint32_t seed_rgba, const double* tones,
                            uint32_t* out, size_t n) {
  const TonalPalette palette(ToArgb(seed_rgba));
  for (size_t i = 0; i < n; i++) out[i] = ToRgba(palette.get(tones[i]));
  return n;
}

void kx_mcu_scheme(KxMcuVariant variant, uint32_t seed_rgba, bool dark,
                   double contrast_level, KxMcuScheme* out) {
  const DynamicScheme s = MakeScheme(variant, seed_rgba, dark, contrast_level);
  out->primary = ToRgba(s.GetPrimary());
  out->on_primary = ToRgba(s.GetOnPrimary());
  out->primary_container = ToRgba(s.GetPrimaryContainer());
  out->on_primary_container = ToRgba(s.GetOnPrimaryContainer());
  out->secondary = ToRgba(s.GetSecondary());
  out->on_secondary = ToRgba(s.GetOnSecondary());
  out->secondary_container = ToRgba(s.GetSecondaryContainer());
  out->on_secondary_container = ToRgba(s.GetOnSecondaryContainer());
  out->tertiary = ToRgba(s.GetTertiary());
  out->on_tertiary = ToRgba(s.GetOnTertiary());
  out->tertiary_container = ToRgba(s.GetTertiaryContainer());
  out->on_tertiary_container = ToRgba(s.GetOnTertiaryContainer());
  out->error = ToRgba(s.GetError());
  out->on_error = ToRgba(s.GetOnError());
  out->error_container = ToRgba(s.GetErrorContainer());
  out->on_error_container = ToRgba(s.GetOnErrorContainer());
  out->surface = ToRgba(s.GetSurface());
  out->on_surface = ToRgba(s.GetOnSurface());
  out->surface_variant = ToRgba(s.GetSurfaceVariant());
  out->on_surface_variant = ToRgba(s.GetOnSurfaceVariant());
  out->surface_container_lowest = ToRgba(s.GetSurfaceContainerLowest());
  out->surface_container_low = ToRgba(s.GetSurfaceContainerLow());
  out->surface_container = ToRgba(s.GetSurfaceContainer());
  out->surface_container_high = ToRgba(s.GetSurfaceContainerHigh());
  out->surface_container_highest = ToRgba(s.GetSurfaceContainerHighest());
  out->background = ToRgba(s.GetBackground());
  out->on_background = ToRgba(s.GetOnBackground());
  out->outline = ToRgba(s.GetOutline());
  out->outline_variant = ToRgba(s.GetOutlineVariant());
  out->inverse_surface = ToRgba(s.GetInverseSurface());
  out->inverse_on_surface = ToRgba(s.GetInverseOnSurface());
  out->inverse_primary = ToRgba(s.GetInversePrimary());
  out->surface_tint = ToRgba(s.GetSurfaceTint());
  out->surface_bright = ToRgba(s.GetSurfaceBright());
  out->surface_dim = ToRgba(s.GetSurfaceDim());
  out->scrim = ToRgba(s.GetScrim());
  out->shadow = ToRgba(s.GetShadow());
}

size_t kx_mcu_dominant_colors(const uint8_t* rgba_pixels, size_t pixel_count,
                              uint32_t* out, size_t cap) {
  std::vector<Argb> pixels;
  pixels.reserve(pixel_count);
  for (size_t i = 0; i < pixel_count; i++) {
    const uint8_t* p = rgba_pixels + i * 4;
    if (p[3] == 0) continue;  // fully transparent: invisible, skip.
    pixels.push_back(material_color_utilities::ArgbFromRgb(p[0], p[1], p[2]));
  }
  if (cap == 0 || out == nullptr) return 0;
  if (pixels.empty()) {
    out[0] = ToRgba(ScoreOptions{}.fallback_color_argb);
    return 1;
  }
  const QuantizerResult result =
      material_color_utilities::QuantizeCelebi(pixels, 128);
  ScoreOptions options;
  options.desired = cap;
  const std::vector<Argb> ranked =
      material_color_utilities::RankedSuggestions(result.color_to_count,
                                                  options);
  size_t n = 0;
  for (const Argb argb : ranked) {
    if (n >= cap) break;
    out[n++] = ToRgba(argb);
  }
  return n;
}

uint32_t kx_mcu_harmonize(uint32_t design_rgba, uint32_t theme_rgba) {
  return ToRgba(material_color_utilities::BlendHarmonize(ToArgb(design_rgba),
                                                       ToArgb(theme_rgba)));
}
