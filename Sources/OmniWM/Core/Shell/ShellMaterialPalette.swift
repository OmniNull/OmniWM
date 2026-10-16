// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import OmniWMMaterialColor

enum ShellMaterialPalette {
    static let roles: [ShellRole: omni_material_role] = [
        .background: OMNI_MATERIAL_BACKGROUND,
        .surface: OMNI_MATERIAL_SURFACE_CONTAINER,
        .elevatedSurface: OMNI_MATERIAL_SURFACE_CONTAINER_HIGH,
        .highestSurface: OMNI_MATERIAL_SURFACE_CONTAINER_HIGHEST,
        .foreground: OMNI_MATERIAL_ON_SURFACE,
        .secondaryForeground: OMNI_MATERIAL_ON_SURFACE_VARIANT,
        .mutedForeground: OMNI_MATERIAL_OUTLINE,
        .border: OMNI_MATERIAL_OUTLINE_VARIANT,
        .accent: OMNI_MATERIAL_PRIMARY,
        .accentForeground: OMNI_MATERIAL_ON_PRIMARY,
        .accentContainer: OMNI_MATERIAL_PRIMARY_CONTAINER,
        .accentContainerForeground: OMNI_MATERIAL_ON_PRIMARY_CONTAINER,
        .secondaryAccent: OMNI_MATERIAL_SECONDARY,
        .secondaryContainer: OMNI_MATERIAL_SECONDARY_CONTAINER,
        .secondaryContainerForeground: OMNI_MATERIAL_ON_SECONDARY_CONTAINER,
        .tertiaryAccent: OMNI_MATERIAL_TERTIARY,
        .tertiaryContainer: OMNI_MATERIAL_TERTIARY_CONTAINER,
        .tertiaryContainerForeground: OMNI_MATERIAL_ON_TERTIARY_CONTAINER,
        .error: OMNI_MATERIAL_ERROR,
        .focus: OMNI_MATERIAL_PRIMARY,
        .shadow: OMNI_MATERIAL_SHADOW
    ]

    static func colors(
        seed: UInt32,
        variant: omni_material_variant = OMNI_MATERIAL_TONAL_SPOT,
        dark: Bool
    ) -> [ShellRole: UInt32] {
        var scheme = [UInt32](repeating: 0, count: Int(OMNI_MATERIAL_ROLE_COUNT.rawValue))
        scheme.withUnsafeMutableBufferPointer { omni_material_scheme(seed, variant, dark, 0, $0.baseAddress) }
        return roles.mapValues { scheme[Int($0.rawValue)] & 0xFFFFFF }
    }
}
