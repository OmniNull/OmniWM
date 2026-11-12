// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WorkspaceBarSettings {
    func export() -> SettingsExport.WorkspaceBar {
        SettingsExport.WorkspaceBar(
            enabled: enabled,
            hoverPreviewsEnabled: hoverPreviewsEnabled,
            notificationBadges: notificationBadges,
            notificationBadgeRefreshIntervalSeconds: notificationBadgeRefreshIntervalSeconds,
            showLabels: showLabels,
            showFloatingWindows: showFloatingWindows,
            windowLevel: windowLevel,
            position: position,
            notchMode: notchMode,
            notchActiveZoneWidth: notchActiveZoneWidth,
            fullWidth: fullWidth,
            fullWidthNotchMode: fullWidthNotchMode,
            systemStatsButton: systemStatsButton,
            deduplicateAppIcons: deduplicateAppIcons,
            hideEmptyWorkspaces: hideEmptyWorkspaces,
            excludedBundleIDs: SettingsExport.WorkspaceBar.sortedExcludedBundleIDs(
                excludedBundleIDs
            ),
            iconOverrides: iconOverrides,
            reserveLayoutSpace: reserveLayoutSpace,
            autoHide: autoHide,
            autoHideRevealDelayMilliseconds: autoHideRevealDelayMilliseconds,
            autoHideHideDelayMilliseconds: autoHideHideDelayMilliseconds,
            revealModifier: revealModifier,
            revealHoldMilliseconds: revealHoldMilliseconds,
            hideInNativeFullscreen: hideInNativeFullscreen,
            height: height,
            backgroundOpacity: backgroundOpacity,
            inactiveIconOpacity: inactiveIconOpacity,
            transparentBackground: transparentBackground,
            solidBlackBackground: solidBlackBackground,
            showItemBackgrounds: showItemBackgrounds,
            showAccentHighlights: showAccentHighlights,
            xOffset: xOffset,
            yOffset: yOffset,
            accentColor: accentColor,
            textColor: textColor
        )
    }
}
