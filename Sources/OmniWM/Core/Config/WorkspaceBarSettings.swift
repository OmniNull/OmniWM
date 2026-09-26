// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import Foundation
import OmniWMIPC

@MainActor @Observable
final class WorkspaceBarSettings {
    private nonisolated static let defaults = SettingsExport.WorkspaceBar.defaults()
    @ObservationIgnored var onChange: (() -> Void)?

    var enabled = WorkspaceBarSettings.defaults.enabled {
        didSet { onChange?() }
    }

    var showLabels = WorkspaceBarSettings.defaults.showLabels {
        didSet { onChange?() }
    }

    var showFloatingWindows = WorkspaceBarSettings.defaults.showFloatingWindows {
        didSet { onChange?() }
    }

    var windowLevel = WorkspaceBarSettings.defaults.windowLevel {
        didSet { onChange?() }
    }

    var position = WorkspaceBarSettings.defaults.position {
        didSet { onChange?() }
    }

    var notchMode = WorkspaceBarSettings.defaults.notchMode {
        didSet { onChange?() }
    }

    var notchActiveZoneWidth = WorkspaceBarSettings.defaults.notchActiveZoneWidth {
        didSet { onChange?() }
    }

    var systemStatsButton = WorkspaceBarSettings.defaults.systemStatsButton {
        didSet { onChange?() }
    }

    var deduplicateAppIcons = WorkspaceBarSettings.defaults.deduplicateAppIcons {
        didSet { onChange?() }
    }

    var hideEmptyWorkspaces = WorkspaceBarSettings.defaults.hideEmptyWorkspaces {
        didSet { onChange?() }
    }

    private(set) var excludedBundleIDs = SettingsExport.WorkspaceBar.normalizedExcludedBundleIDs(
        WorkspaceBarSettings.defaults.excludedBundleIDs
    ) {
        didSet { onChange?() }
    }

    private(set) var iconOverrides = SettingsExport.WorkspaceBar.normalizedIconOverrides(
        WorkspaceBarSettings.defaults.iconOverrides
    ) {
        didSet { onChange?() }
    }

    var reserveLayoutSpace = WorkspaceBarSettings.defaults.reserveLayoutSpace {
        didSet { onChange?() }
    }

    var revealModifier = WorkspaceBarSettings.defaults.revealModifier {
        didSet { onChange?() }
    }

    var revealHoldMilliseconds = WorkspaceBarSettings.defaults.revealHoldMilliseconds {
        didSet { onChange?() }
    }

    var hideInNativeFullscreen = WorkspaceBarSettings.defaults.hideInNativeFullscreen {
        didSet { onChange?() }
    }

    var height = WorkspaceBarSettings.defaults.height {
        didSet { onChange?() }
    }

    var backgroundOpacity = WorkspaceBarSettings.defaults.backgroundOpacity {
        didSet { onChange?() }
    }

    var inactiveIconOpacity = WorkspaceBarSettings.defaults.inactiveIconOpacity {
        didSet {
            let normalized = Self.normalizedInactiveIconOpacity(inactiveIconOpacity)
            guard normalized == inactiveIconOpacity else {
                inactiveIconOpacity = normalized
                return
            }
            onChange?()
        }
    }

    var transparentBackground = WorkspaceBarSettings.defaults.transparentBackground {
        didSet { onChange?() }
    }

    var solidBlackBackground = WorkspaceBarSettings.defaults.solidBlackBackground {
        didSet { onChange?() }
    }

    var showItemBackgrounds = WorkspaceBarSettings.defaults.showItemBackgrounds {
        didSet { onChange?() }
    }

    var showAccentHighlights = WorkspaceBarSettings.defaults.showAccentHighlights {
        didSet { onChange?() }
    }

    var xOffset = WorkspaceBarSettings.defaults.xOffset {
        didSet { onChange?() }
    }

    var yOffset = WorkspaceBarSettings.defaults.yOffset {
        didSet { onChange?() }
    }

    var accentColor = WorkspaceBarSettings.defaults.accentColor {
        didSet { onChange?() }
    }

    var textColor = WorkspaceBarSettings.defaults.textColor {
        didSet { onChange?() }
    }

    var monitorOverrides: [MonitorBarSettings] = [] {
        didSet {
            var normalized = monitorOverrides
            var changed = false
            for index in normalized.indices {
                let opacity = Self.normalizedInactiveIconOpacity(normalized[index].inactiveIconOpacity)
                if normalized[index].inactiveIconOpacity != opacity {
                    normalized[index].inactiveIconOpacity = opacity
                    changed = true
                }
            }
            if changed {
                monitorOverrides = normalized
                return
            }
            onChange?()
        }
    }

    func export() -> SettingsExport.WorkspaceBar {
        SettingsExport.WorkspaceBar(
            enabled: enabled,
            showLabels: showLabels,
            showFloatingWindows: showFloatingWindows,
            windowLevel: windowLevel,
            position: position,
            notchMode: notchMode,
            notchActiveZoneWidth: notchActiveZoneWidth,
            systemStatsButton: systemStatsButton,
            deduplicateAppIcons: deduplicateAppIcons,
            hideEmptyWorkspaces: hideEmptyWorkspaces,
            excludedBundleIDs: SettingsExport.WorkspaceBar.sortedExcludedBundleIDs(
                excludedBundleIDs
            ),
            iconOverrides: iconOverrides,
            reserveLayoutSpace: reserveLayoutSpace,
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

    func applyIdentity(_ bar: SettingsExport.WorkspaceBar) {
        enabled = bar.enabled
        showLabels = bar.showLabels
        showFloatingWindows = bar.showFloatingWindows
        windowLevel = bar.windowLevel
        position = bar.position
        notchMode = bar.notchMode
        notchActiveZoneWidth = min(max(bar.notchActiveZoneWidth, 100), 400)
        systemStatsButton = bar.systemStatsButton
        deduplicateAppIcons = bar.deduplicateAppIcons
        hideEmptyWorkspaces = bar.hideEmptyWorkspaces
        excludedBundleIDs = SettingsExport.WorkspaceBar.normalizedExcludedBundleIDs(
            bar.excludedBundleIDs
        )
        iconOverrides = SettingsExport.WorkspaceBar.normalizedIconOverrides(
            bar.iconOverrides
        )
    }

    func applyAppearance(_ bar: SettingsExport.WorkspaceBar, monitorOverrides: [MonitorBarSettings]) {
        reserveLayoutSpace = bar.reserveLayoutSpace
        revealModifier = bar.revealModifier
        revealHoldMilliseconds = WorkspaceBarSettings.validatedRevealHoldMilliseconds(
            bar.revealHoldMilliseconds
        )
        hideInNativeFullscreen = bar.hideInNativeFullscreen
        height = bar.height
        backgroundOpacity = bar.backgroundOpacity
        inactiveIconOpacity = bar.inactiveIconOpacity
        transparentBackground = bar.transparentBackground
        solidBlackBackground = bar.solidBlackBackground
        showItemBackgrounds = bar.showItemBackgrounds
        showAccentHighlights = bar.showAccentHighlights
        xOffset = bar.xOffset
        yOffset = bar.yOffset
        accentColor = bar.accentColor
        textColor = bar.textColor
        self.monitorOverrides = monitorOverrides
    }

    func settings(for monitor: Monitor) -> MonitorBarSettings? {
        MonitorSettingsStore.get(for: monitor, in: monitorOverrides)
    }

    func update(_ settings: MonitorBarSettings, for monitor: Monitor) {
        MonitorSettingsStore.update(settings, for: monitor, in: &monitorOverrides)
    }

    func remove(for monitor: Monitor) {
        MonitorSettingsStore.remove(for: monitor, from: &monitorOverrides)
    }

    func resolved(for monitor: Monitor) -> ResolvedBarSettings {
        resolved(override: settings(for: monitor))
    }

    private func resolved(override: MonitorBarSettings?) -> ResolvedBarSettings {
        let position = override?.position ?? self.position
        return ResolvedBarSettings(
            enabled: override?.enabled ?? enabled,
            showLabels: override?.showLabels ?? showLabels,
            showFloatingWindows: override?.showFloatingWindows ?? showFloatingWindows,
            deduplicateAppIcons: override?.deduplicateAppIcons ?? deduplicateAppIcons,
            hideEmptyWorkspaces: override?.hideEmptyWorkspaces ?? hideEmptyWorkspaces,
            excludedBundleIDs: excludedBundleIDs,
            reserveLayoutSpace: override?.reserveLayoutSpace ?? reserveLayoutSpace,
            notchMode: position.usesNotch ? (override?.notchMode ?? notchMode) : .off,
            notchActiveZoneWidth: override?.notchActiveZoneWidth ?? notchActiveZoneWidth,
            systemStatsButton: systemStatsButton,
            position: position,
            windowLevel: override?.windowLevel ?? windowLevel,
            height: override?.height ?? height,
            backgroundOpacity: override?.backgroundOpacity ?? backgroundOpacity,
            inactiveIconOpacity: override?.inactiveIconOpacity ?? inactiveIconOpacity,
            transparentBackground: override?.transparentBackground ?? transparentBackground,
            solidBlackBackground: override?.solidBlackBackground ?? solidBlackBackground,
            showItemBackgrounds: override?.showItemBackgrounds ?? showItemBackgrounds,
            showAccentHighlights: override?.showAccentHighlights ?? showAccentHighlights,
            xOffset: override?.xOffset ?? xOffset,
            yOffset: override?.yOffset ?? yOffset,
            accentColor: accentColor,
            textColor: textColor
        )
    }

    @discardableResult
    func addExcludedBundleID(_ rawBundleID: String) -> Bool {
        let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty,
              !excludedBundleIDs.contains(where: {
                  $0.caseInsensitiveCompare(bundleID) == .orderedSame
              })
        else {
            return false
        }
        excludedBundleIDs.insert(bundleID)
        return true
    }

    @discardableResult
    func removeExcludedBundleID(_ rawBundleID: String) -> Bool {
        let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return false }
        guard let storedBundleID = excludedBundleIDs.first(where: {
            $0.caseInsensitiveCompare(bundleID) == .orderedSame
        }) else {
            return false
        }
        excludedBundleIDs.remove(storedBundleID)
        return true
    }

    func iconOverrideValue(for rawBundleID: String) -> String? {
        let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return nil }
        return iconOverrides.first { storedBundleID, _ in
            storedBundleID.caseInsensitiveCompare(bundleID) == .orderedSame
        }?.value
    }

    @discardableResult
    func setIconOverride(_ rawValue: String, for rawBundleID: String) -> Bool {
        let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty, !value.isEmpty else { return false }

        if let storedBundleID = iconOverrides.keys.first(where: {
            $0.caseInsensitiveCompare(bundleID) == .orderedSame
        }) {
            guard iconOverrides[storedBundleID] != value else { return false }
            iconOverrides[storedBundleID] = value
            return true
        }

        iconOverrides[bundleID] = value
        return true
    }

    @discardableResult
    func removeIconOverride(for rawBundleID: String) -> Bool {
        let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return false }
        guard let storedBundleID = iconOverrides.keys.first(where: {
            $0.caseInsensitiveCompare(bundleID) == .orderedSame
        }) else {
            return false
        }
        iconOverrides.removeValue(forKey: storedBundleID)
        return true
    }

    static func validatedRevealHoldMilliseconds(_ value: Double) -> Double {
        guard value.isFinite else { return defaults.revealHoldMilliseconds }
        return min(max(value, 0), 1000)
    }

    private static func normalizedInactiveIconOpacity(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }
}
