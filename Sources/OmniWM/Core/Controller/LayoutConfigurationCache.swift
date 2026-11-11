// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct MonitorLayoutCacheEntry {
    struct Key: Equatable {
        let monitor: Monitor
        let scale: CGFloat
        let revision: UInt64
    }

    let key: Key
    let value: MonitorLayoutFrames
}

struct InnerGapCacheEntry {
    struct Key: Equatable {
        let monitor: Monitor
        let scale: CGFloat
        let revision: UInt64
        let runtimeGap: Double
    }

    let key: Key
    let value: CGFloat
}

struct BorderConfigCacheEntry {
    let revision: UInt64
    let isDark: Bool
    let keyboardMode: KeyboardModeKind
    var palette: ShellTheme?
    let value: BorderConfig
}

extension WMController {
    func resolvedBorderConfig() -> BorderConfig {
        let revision = settings.layoutConfigurationRevision
        let palette = settings.borders.colorSource == .palette ? workspaceBarManager.shellPalette : nil
        if let cachedBorderConfig,
           cachedBorderConfig.revision == revision,
           cachedBorderConfig.isDark == borderUsesDarkAppearance,
           cachedBorderConfig.keyboardMode == keyboardModeKind,
           cachedBorderConfig.palette == palette
        {
            return cachedBorderConfig.value
        }
        let value = BorderConfig.from(settings: settings, isDark: borderUsesDarkAppearance, palette: palette)
            .indicating(keyboardModeKind)
        cachedBorderConfig = BorderConfigCacheEntry(
            revision: revision, isDark: borderUsesDarkAppearance, keyboardMode: keyboardModeKind, palette: palette,
            value: value
        )
        return value
    }
}
