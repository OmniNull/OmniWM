// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation

@MainActor @Observable
final class StatusMenuSettings {
    private nonisolated static let defaults = SettingsExport.StatusMenu.defaults()
    @ObservationIgnored var onChange: (() -> Void)?

    var showControls = StatusMenuSettings.defaults.showControls ?? true {
        didSet { onChange?() }
    }

    var showAppMenu = StatusMenuSettings.defaults.showAppMenu ?? true {
        didSet { onChange?() }
    }

    var showControlHelp = StatusMenuSettings.defaults.showControlHelp ?? true {
        didSet { onChange?() }
    }

    var showMenuItems = StatusMenuSettings.defaults.showMenuItems ?? true {
        didSet { onChange?() }
    }

    /// Controls the user turned off individually. Kept separate from `showControls`
    /// so the grid master toggle can be flipped without losing per-tile choices.
    var hiddenControls: Set<String> = [] {
        didSet { onChange?() }
    }

    /// OmniWM rows the user turned off individually, same rationale as `hiddenControls`.
    var hiddenMenuItems: Set<String> = [] {
        didSet { onChange?() }
    }

    func isControlVisible(_ id: String) -> Bool {
        showControls && !hiddenControls.contains(id)
    }

    func setControl(_ id: String, isVisible: Bool) {
        let trimmed = Self.normalizedID(id)
        guard let trimmed else { return }
        if isVisible {
            hiddenControls.remove(trimmed)
        } else {
            hiddenControls.insert(trimmed)
        }
    }

    func isMenuItemVisible(_ item: StatusMenuItem) -> Bool {
        showMenuItems && !hiddenMenuItems.contains(item.rawValue)
    }

    func setMenuItem(_ item: StatusMenuItem, isVisible: Bool) {
        if isVisible {
            hiddenMenuItems.remove(item.rawValue)
        } else {
            hiddenMenuItems.insert(item.rawValue)
        }
    }

    func export() -> SettingsExport.StatusMenu {
        SettingsExport.StatusMenu(
            showControls: showControls,
            showAppMenu: showAppMenu,
            showControlHelp: showControlHelp,
            showMenuItems: showMenuItems,
            hiddenControls: hiddenControls.sorted(),
            hiddenMenuItems: hiddenMenuItems.sorted()
        )
    }

    func apply(_ values: SettingsExport.StatusMenu) {
        let defaults = StatusMenuSettings.defaults
        showControls = values.showControls ?? defaults.showControls ?? true
        showAppMenu = values.showAppMenu ?? defaults.showAppMenu ?? true
        showControlHelp = values.showControlHelp ?? defaults.showControlHelp ?? true
        showMenuItems = values.showMenuItems ?? defaults.showMenuItems ?? true
        hiddenControls = Self.normalizedIDs(values.hiddenControls)
        hiddenMenuItems = Self.normalizedIDs(values.hiddenMenuItems)
    }

    private static func normalizedIDs(_ ids: [String]?) -> Set<String> {
        Set((ids ?? []).compactMap(normalizedID))
    }

    private static func normalizedID(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
