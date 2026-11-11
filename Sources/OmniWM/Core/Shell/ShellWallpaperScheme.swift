// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMMaterialColor

enum ShellWallpaperScheme: String, CaseIterable, Sendable {
    case tonalSpot
    case content
    case vibrant
    case expressive
    case fidelity
    case fruitSalad
    case rainbow
    case neutral
    case monochrome

    var variant: omni_material_variant {
        switch self {
        case .tonalSpot: OMNI_MATERIAL_TONAL_SPOT
        case .content: OMNI_MATERIAL_CONTENT
        case .vibrant: OMNI_MATERIAL_VIBRANT
        case .expressive: OMNI_MATERIAL_EXPRESSIVE
        case .fidelity: OMNI_MATERIAL_FIDELITY
        case .fruitSalad: OMNI_MATERIAL_FRUIT_SALAD
        case .rainbow: OMNI_MATERIAL_RAINBOW
        case .neutral: OMNI_MATERIAL_NEUTRAL
        case .monochrome: OMNI_MATERIAL_MONOCHROME
        }
    }
}
