// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore

struct OverviewAppearance: Equatable {
    let backdrop: SettingsColor
    let normalBorder: SettingsColor
    let hoveredBorder: SettingsColor
    let selectedBorder: SettingsColor
    let focusBorder: BorderConfig?

    @MainActor
    init(settings: SettingsStore, isDark: Bool) {
        backdrop = settings.overview.backdropColor
        normalBorder = settings.overview.normalBorderColor
        hoveredBorder = settings.overview.hoveredBorderColor
        if settings.overview.matchFocusBorder {
            let config = BorderConfig.from(settings: settings, isDark: isDark)
            selectedBorder = config.color
            focusBorder = config
        } else {
            selectedBorder = settings.overview.selectedBorderColor
            focusBorder = nil
        }
    }

    var renderPalette: OverviewRenderPalette {
        OverviewRenderPalette(
            backdropColor: backdrop,
            normalBorderColor: normalBorder,
            hoveredBorderColor: hoveredBorder,
            selectedBorderColor: selectedBorder,
            focusBorder: focusBorder
        )
    }
}

@MainActor
struct OverviewPresentation {
    private(set) var configuredScale: CGFloat
    private var appearance: OverviewAppearance
    private(set) var renderPalette: OverviewRenderPalette

    init(settings: SettingsStore, isDark: Bool) {
        appearance = OverviewAppearance(settings: settings, isDark: isDark)
        configuredScale = OverviewLayoutCalculator.clampedScale(CGFloat(settings.overview.zoom))
        renderPalette = appearance.renderPalette
    }

    mutating func update(settings: SettingsStore, isDark: Bool) -> (scaleChanged: Bool, appearanceChanged: Bool) {
        let nextConfiguredScale = OverviewLayoutCalculator.clampedScale(CGFloat(settings.overview.zoom))
        let nextAppearance = OverviewAppearance(settings: settings, isDark: isDark)
        let scaleChanged = abs(nextConfiguredScale - configuredScale) > OverviewViewportProjection.zoomEpsilon
        let appearanceChanged = nextAppearance != appearance
        configuredScale = nextConfiguredScale
        if appearanceChanged {
            appearance = nextAppearance
            renderPalette = nextAppearance.renderPalette
        }
        return (scaleChanged, appearanceChanged)
    }
}
