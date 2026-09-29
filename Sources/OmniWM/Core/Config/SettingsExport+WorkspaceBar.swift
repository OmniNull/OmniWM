// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension SettingsExport {
    struct WorkspaceBar: Codable, Equatable {
        var enabled: Bool
        var hoverPreviewsEnabled: Bool
        var notificationBadges: WorkspaceBarNotificationBadgeMode
        var notificationBadgeRefreshIntervalSeconds: Double
        var showLabels: Bool
        var showFloatingWindows: Bool
        var windowLevel: WorkspaceBarWindowLevel
        var position: WorkspaceBarPosition
        var notchMode: WorkspaceBarNotchMode
        var notchActiveZoneWidth: Double
        var systemStatsButton: Bool
        var deduplicateAppIcons: Bool
        var hideEmptyWorkspaces: Bool
        var excludedBundleIDs: [String]
        var iconOverrides: [String: String]
        var reserveLayoutSpace: Bool
        var autoHide: Bool = false
        var revealModifier: WorkspaceBarRevealModifier
        var revealHoldMilliseconds: Double
        var hideInNativeFullscreen: Bool
        var height: Double
        var backgroundOpacity: Double
        var inactiveIconOpacity: Double?
        var transparentBackground: Bool
        var solidBlackBackground: Bool
        var showItemBackgrounds: Bool
        var showAccentHighlights: Bool
        var xOffset: Double
        var yOffset: Double
        var accentColor: SettingsColor?
        var textColor: SettingsColor?
    }
}

extension SettingsExport.WorkspaceBar {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults()
        enabled = try container.decode(Bool.self, forKey: .enabled)
        hoverPreviewsEnabled = try container.decodeIfPresent(Bool.self, forKey: .hoverPreviewsEnabled)
            ?? defaults.hoverPreviewsEnabled
        notificationBadges = try container.decodeIfPresent(
            WorkspaceBarNotificationBadgeMode.self,
            forKey: .notificationBadges
        ) ?? defaults.notificationBadges
        notificationBadgeRefreshIntervalSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .notificationBadgeRefreshIntervalSeconds
        ) ?? defaults.notificationBadgeRefreshIntervalSeconds
        showLabels = try container.decode(Bool.self, forKey: .showLabels)
        showFloatingWindows = try container.decode(Bool.self, forKey: .showFloatingWindows)
        windowLevel = try container.decode(WorkspaceBarWindowLevel.self, forKey: .windowLevel)
        position = try container.decode(WorkspaceBarPosition.self, forKey: .position)
        notchMode = try container.decode(WorkspaceBarNotchMode.self, forKey: .notchMode)
        notchActiveZoneWidth = try container.decode(Double.self, forKey: .notchActiveZoneWidth)
        systemStatsButton = try container.decode(Bool.self, forKey: .systemStatsButton)
        deduplicateAppIcons = try container.decode(Bool.self, forKey: .deduplicateAppIcons)
        hideEmptyWorkspaces = try container.decode(Bool.self, forKey: .hideEmptyWorkspaces)
        excludedBundleIDs = try container.decode([String].self, forKey: .excludedBundleIDs)
        iconOverrides = try container.decode([String: String].self, forKey: .iconOverrides)
        reserveLayoutSpace = try container.decode(Bool.self, forKey: .reserveLayoutSpace)
        autoHide = try container.decodeIfPresent(Bool.self, forKey: .autoHide) ?? defaults.autoHide
        revealModifier = try container.decode(WorkspaceBarRevealModifier.self, forKey: .revealModifier)
        revealHoldMilliseconds = try container.decode(Double.self, forKey: .revealHoldMilliseconds)
        hideInNativeFullscreen = try container.decode(Bool.self, forKey: .hideInNativeFullscreen)
        height = try container.decode(Double.self, forKey: .height)
        backgroundOpacity = try container.decode(Double.self, forKey: .backgroundOpacity)
        inactiveIconOpacity = try container.decodeIfPresent(Double.self, forKey: .inactiveIconOpacity)
        transparentBackground = try container.decodeIfPresent(Bool.self, forKey: .transparentBackground)
            ?? defaults.transparentBackground
        solidBlackBackground = try container.decodeIfPresent(Bool.self, forKey: .solidBlackBackground)
            ?? defaults.solidBlackBackground
        showItemBackgrounds = try container.decodeIfPresent(Bool.self, forKey: .showItemBackgrounds)
            ?? defaults.showItemBackgrounds
        showAccentHighlights = try container.decodeIfPresent(Bool.self, forKey: .showAccentHighlights)
            ?? defaults.showAccentHighlights
        xOffset = try container.decode(Double.self, forKey: .xOffset)
        yOffset = try container.decode(Double.self, forKey: .yOffset)
        accentColor = try container.decodeIfPresent(SettingsColor.self, forKey: .accentColor)
        textColor = try container.decodeIfPresent(SettingsColor.self, forKey: .textColor)
    }

    static func defaults() -> Self {
        Self(
            enabled: true,
            hoverPreviewsEnabled: true,
            notificationBadges: .off,
            notificationBadgeRefreshIntervalSeconds: 5,
            showLabels: true,
            showFloatingWindows: false,
            windowLevel: .popup,
            position: .overlappingMenuBar,
            notchMode: .moveBelowMenuBar,
            notchActiveZoneWidth: 180,
            systemStatsButton: false,
            deduplicateAppIcons: false,
            hideEmptyWorkspaces: false,
            excludedBundleIDs: [],
            iconOverrides: [:],
            reserveLayoutSpace: false,
            autoHide: false,
            revealModifier: .off,
            revealHoldMilliseconds: 200,
            hideInNativeFullscreen: false,
            height: 24.0,
            backgroundOpacity: 0.1,
            inactiveIconOpacity: nil,
            transparentBackground: false,
            solidBlackBackground: false,
            showItemBackgrounds: true,
            showAccentHighlights: true,
            xOffset: 0.0,
            yOffset: 0.0,
            accentColor: nil,
            textColor: nil
        )
    }
}

@MainActor
extension SettingsExport.WorkspaceBar {
    private struct NormalizedIconOverride {
        let foldedBundleID: String
        let bundleID: String
        let value: String
    }

    static func normalizedExcludedBundleIDs(_ bundleIDs: [String]) -> Set<String> {
        var normalized: Set<String> = []
        normalized.reserveCapacity(bundleIDs.count)
        for rawBundleID in bundleIDs {
            let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty,
                  !normalized.contains(where: {
                      $0.caseInsensitiveCompare(bundleID) == .orderedSame
                  })
            else {
                continue
            }
            normalized.insert(bundleID)
        }
        return normalized
    }

    static func sortedExcludedBundleIDs(_ bundleIDs: Set<String>) -> [String] {
        bundleIDs.sorted { lhs, rhs in
            let order = lhs.caseInsensitiveCompare(rhs)
            return order == .orderedSame ? lhs < rhs : order == .orderedAscending
        }
    }

    static func normalizedIconOverrides(_ overrides: [String: String]) -> [String: String] {
        let candidates = overrides.compactMap { rawBundleID, rawValue -> NormalizedIconOverride? in
            let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty, !value.isEmpty else { return nil }
            return NormalizedIconOverride(
                foldedBundleID: bundleID.lowercased(),
                bundleID: bundleID,
                value: value
            )
        }.sorted { lhs, rhs in
            if lhs.foldedBundleID != rhs.foldedBundleID {
                return lhs.foldedBundleID < rhs.foldedBundleID
            }
            if lhs.bundleID != rhs.bundleID {
                return lhs.bundleID < rhs.bundleID
            }
            return lhs.value < rhs.value
        }

        var normalized: [String: String] = [:]
        normalized.reserveCapacity(candidates.count)
        var seenBundleIDs: Set<String> = []
        seenBundleIDs.reserveCapacity(candidates.count)
        for candidate in candidates where seenBundleIDs.insert(candidate.foldedBundleID).inserted {
            normalized[candidate.bundleID] = candidate.value
        }
        return normalized
    }
}
