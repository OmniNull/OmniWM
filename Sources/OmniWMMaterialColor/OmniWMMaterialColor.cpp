// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

#include "OmniWMMaterialColor.h"

#include "cpp/cam/hct.h"
#include "cpp/dynamiccolor/dynamic_scheme.h"
#include "cpp/dynamiccolor/material_dynamic_colors.h"
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

#include <memory>
#include <vector>

namespace {

namespace mcu = material_color_utilities;
using Colors = mcu::MaterialDynamicColors;
using Role = mcu::DynamicColor (*)();

constexpr Role roles[OMNI_MATERIAL_ROLE_COUNT] = {
    Colors::Background,
    Colors::OnBackground,
    Colors::Surface,
    Colors::SurfaceDim,
    Colors::SurfaceBright,
    Colors::SurfaceContainerLowest,
    Colors::SurfaceContainerLow,
    Colors::SurfaceContainer,
    Colors::SurfaceContainerHigh,
    Colors::SurfaceContainerHighest,
    Colors::OnSurface,
    Colors::SurfaceVariant,
    Colors::OnSurfaceVariant,
    Colors::InverseSurface,
    Colors::InverseOnSurface,
    Colors::Outline,
    Colors::OutlineVariant,
    Colors::Shadow,
    Colors::Scrim,
    Colors::SurfaceTint,
    Colors::Primary,
    Colors::OnPrimary,
    Colors::PrimaryContainer,
    Colors::OnPrimaryContainer,
    Colors::InversePrimary,
    Colors::Secondary,
    Colors::OnSecondary,
    Colors::SecondaryContainer,
    Colors::OnSecondaryContainer,
    Colors::Tertiary,
    Colors::OnTertiary,
    Colors::TertiaryContainer,
    Colors::OnTertiaryContainer,
    Colors::Error,
    Colors::OnError,
    Colors::ErrorContainer,
    Colors::OnErrorContainer,
};

std::unique_ptr<mcu::DynamicScheme> scheme(mcu::Hct seed, omni_material_variant variant, bool dark, double contrast) {
    switch (variant) {
    case OMNI_MATERIAL_CONTENT: return std::make_unique<mcu::SchemeContent>(seed, dark, contrast);
    case OMNI_MATERIAL_VIBRANT: return std::make_unique<mcu::SchemeVibrant>(seed, dark, contrast);
    case OMNI_MATERIAL_EXPRESSIVE: return std::make_unique<mcu::SchemeExpressive>(seed, dark, contrast);
    case OMNI_MATERIAL_FIDELITY: return std::make_unique<mcu::SchemeFidelity>(seed, dark, contrast);
    case OMNI_MATERIAL_FRUIT_SALAD: return std::make_unique<mcu::SchemeFruitSalad>(seed, dark, contrast);
    case OMNI_MATERIAL_RAINBOW: return std::make_unique<mcu::SchemeRainbow>(seed, dark, contrast);
    case OMNI_MATERIAL_NEUTRAL: return std::make_unique<mcu::SchemeNeutral>(seed, dark, contrast);
    case OMNI_MATERIAL_MONOCHROME: return std::make_unique<mcu::SchemeMonochrome>(seed, dark, contrast);
    case OMNI_MATERIAL_TONAL_SPOT:
    default: return std::make_unique<mcu::SchemeTonalSpot>(seed, dark, contrast);
    }
}

}

extern "C" uint32_t omni_material_seed(const uint32_t *argb, size_t count, uint32_t fallback) {
    std::vector<mcu::Argb> pixels;
    pixels.reserve(count);
    for (size_t index = 0; index < count; index++) {
        if ((argb[index] >> 24) == 0xFF) {
            pixels.push_back(argb[index]);
        }
    }
    if (pixels.empty()) {
        return fallback;
    }
    mcu::ScoreOptions options;
    options.desired = 1;
    options.fallback_color_argb = static_cast<int>(fallback);
    std::vector<mcu::Argb> ranked = mcu::RankedSuggestions(mcu::QuantizeCelebi(pixels, 128).color_to_count, options);
    return ranked.empty() ? fallback : ranked.front();
}

extern "C" void omni_material_scheme(
    uint32_t seed,
    omni_material_variant variant,
    bool dark,
    double contrast,
    uint32_t output[OMNI_MATERIAL_ROLE_COUNT]
) {
    std::unique_ptr<mcu::DynamicScheme> built = scheme(mcu::Hct(seed | 0xFF000000u), variant, dark, contrast);
    for (int index = 0; index < OMNI_MATERIAL_ROLE_COUNT; index++) {
        output[index] = roles[index]().GetArgb(*built);
    }
}
