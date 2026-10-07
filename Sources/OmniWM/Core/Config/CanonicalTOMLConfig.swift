// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct CanonicalTOMLConfig: Codable, Equatable {
    var schemaVersion: Int
    var general: General
    var focus: SettingsExport.Focus
    var mouseWarp: SettingsExport.MouseWarp
    var routing: SettingsExport.Routing
    var monitors: Monitors?
    var gaps: SettingsExport.Gaps
    var niri: SettingsExport.Niri
    var dwindle: SettingsExport.Dwindle
    var borders: SettingsExport.Borders
    var overview: SettingsExport.Overview
    var workspaceBar: SettingsExport.WorkspaceBar
    var gestures: SettingsExport.Gestures
    var statusBar: SettingsExport.StatusBar
    var hiddenBar: SettingsExport.HiddenBar
    var clipboard: SettingsExport.Clipboard
    var quakeTerminal: SettingsExport.QuakeTerminal
    var scratchpads: SettingsExport.Scratchpads
    var appearance: Appearance
    var hotkeys: [HotkeyBinding]
    var workspaces: [WorkspaceConfiguration]
    var appRules: [AppRule]
    var monitorBarOverrides: [MonitorBarSettings]
    var monitorOrientationOverrides: [MonitorOrientationSettings]
    var monitorNiriOverrides: [MonitorNiriSettings]
    var monitorDwindleOverrides: [MonitorDwindleSettings]
    var monitorGapOverrides: [MonitorGapSettings]

    struct General: Codable, Equatable {
        var hotkeysEnabled: Bool
        var systemHyperTrigger: SystemHyperTrigger
        var hyperKeyModifiers: HyperKeyModifiers
        var defaultLayoutType: LayoutType
        var preventSleepEnabled: Bool
        var updateChecksEnabled: Bool
        var ipcEnabled: Bool
        var animationsEnabled: Bool
        var animationSpeed: Double?
        var language: String?
    }

    struct Monitors: Codable, Equatable {
        var ranking: [OutputId]
    }

    struct Appearance: Codable, Equatable {
        var mode: AppearanceMode
        var tabRailAppIcons: Bool
    }
}

extension CanonicalTOMLConfig.Appearance {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(AppearanceMode.self, forKey: .mode)
        tabRailAppIcons = try container.decodeIfPresent(Bool.self, forKey: .tabRailAppIcons) ?? false
    }
}

extension CanonicalTOMLConfig {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        general = try container.decode(General.self, forKey: .general)
        KeySymbolMapper.setHyperKeyModifiers(general.hyperKeyModifiers)
        focus = try container.decode(SettingsExport.Focus.self, forKey: .focus)
        mouseWarp = try container.decode(SettingsExport.MouseWarp.self, forKey: .mouseWarp)
        routing = try container.decode(SettingsExport.Routing.self, forKey: .routing)
        monitors = try container.decodeIfPresent(Monitors.self, forKey: .monitors)
        gaps = try container.decode(SettingsExport.Gaps.self, forKey: .gaps)
        niri = try container.decode(SettingsExport.Niri.self, forKey: .niri)
        niri.edgeGaps = niri.edgeGaps ?? true
        dwindle = try container.decode(SettingsExport.Dwindle.self, forKey: .dwindle)
        borders = try container.decode(SettingsExport.Borders.self, forKey: .borders)
        overview = try container.decode(SettingsExport.Overview.self, forKey: .overview)
        workspaceBar = try container.decode(SettingsExport.WorkspaceBar.self, forKey: .workspaceBar)
        gestures = try container.decode(SettingsExport.Gestures.self, forKey: .gestures)
        statusBar = try container.decode(SettingsExport.StatusBar.self, forKey: .statusBar)
        hiddenBar = try container.decode(SettingsExport.HiddenBar.self, forKey: .hiddenBar)
        clipboard = try container.decode(SettingsExport.Clipboard.self, forKey: .clipboard)
        quakeTerminal = try container.decode(SettingsExport.QuakeTerminal.self, forKey: .quakeTerminal)
        scratchpads = try container.decode(SettingsExport.Scratchpads.self, forKey: .scratchpads)
        appearance = try container.decode(Appearance.self, forKey: .appearance)
        let persistedHotkeys = try container.decode([PersistedHotkeyBinding].self, forKey: .hotkeys)
        hotkeys = try HotkeyBindingRegistry.resolve(persistedHotkeys)
        workspaces = try container.decode([WorkspaceConfiguration].self, forKey: .workspaces)
        appRules = try container.decode([AppRule].self, forKey: .appRules)
        monitorBarOverrides = try container.decode([MonitorBarSettings].self, forKey: .monitorBarOverrides)
        monitorOrientationOverrides = try container.decode(
            [MonitorOrientationSettings].self,
            forKey: .monitorOrientationOverrides
        )
        monitorNiriOverrides = try container.decode([MonitorNiriSettings].self, forKey: .monitorNiriOverrides)
        monitorDwindleOverrides = try container.decode([MonitorDwindleSettings].self, forKey: .monitorDwindleOverrides)
        monitorGapOverrides = try container.decode([MonitorGapSettings].self, forKey: .monitorGapOverrides)
    }
}

extension CanonicalTOMLConfig {
    init(export: SettingsExport) {
        schemaVersion = SettingsTOMLCodec.currentSchemaVersion
        general = General(
            hotkeysEnabled: export.hotkeysEnabled,
            systemHyperTrigger: export.systemHyperTrigger,
            hyperKeyModifiers: export.hyperKeyModifiers,
            defaultLayoutType: export.defaultLayoutType,
            preventSleepEnabled: export.preventSleepEnabled,
            updateChecksEnabled: export.updateChecksEnabled,
            ipcEnabled: export.ipcEnabled,
            animationsEnabled: export.animationsEnabled,
            animationSpeed: AnimationSpeed.normalized(export.animationSpeed),
            language: export.language
        )
        focus = export.focus
        mouseWarp = export.mouseWarp
        routing = export.routing
        monitors = export.monitorRanking.isEmpty ? nil : Monitors(ranking: export.monitorRanking)
        gaps = export.gaps
        niri = export.niri
        dwindle = export.dwindle
        borders = export.borders
        overview = export.overview
        workspaceBar = export.workspaceBar
        gestures = export.gestures
        statusBar = export.statusBar
        hiddenBar = export.hiddenBar
        clipboard = export.clipboard
        quakeTerminal = export.quakeTerminal
        scratchpads = export.scratchpads
        appearance = Appearance(mode: export.appearanceMode, tabRailAppIcons: export.tabRailAppIcons)
        hotkeys = export.hotkeyBindings
        workspaces = export.workspaceConfigurations
        appRules = export.appRules
        monitorBarOverrides = export.monitorBarSettings
        monitorOrientationOverrides = export.monitorOrientationSettings
        monitorNiriOverrides = export.monitorNiriSettings
        monitorDwindleOverrides = export.monitorDwindleSettings
        monitorGapOverrides = export.monitorGapSettings
    }

    func toSettingsExport() -> SettingsExport {
        SettingsExport(
            hotkeysEnabled: general.hotkeysEnabled,
            focus: focus,
            mouseWarp: mouseWarp,
            routing: routing,
            monitorRanking: monitors?.ranking ?? [],
            gaps: gaps,
            niri: niri,
            workspaceConfigurations: workspaces,
            defaultLayoutType: general.defaultLayoutType,
            borders: borders,
            overview: overviewForExport(),
            hotkeyBindings: hotkeys,
            systemHyperTrigger: general.systemHyperTrigger,
            hyperKeyModifiers: general.hyperKeyModifiers,
            workspaceBar: workspaceBar,
            scratchpads: scratchpads,
            monitorBarSettings: monitorBarOverrides,
            appRules: appRules,
            monitorOrientationSettings: monitorOrientationOverrides,
            monitorNiriSettings: monitorNiriOverrides,
            dwindle: dwindle,
            monitorDwindleSettings: monitorDwindleOverrides,
            monitorGapSettings: monitorGapOverrides,
            preventSleepEnabled: general.preventSleepEnabled,
            updateChecksEnabled: general.updateChecksEnabled,
            ipcEnabled: general.ipcEnabled,
            gestures: gesturesForExport(),
            statusBar: statusBarForExport(),
            hiddenBar: hiddenBar,
            animationsEnabled: general.animationsEnabled,
            animationSpeed: AnimationSpeed.normalized(general.animationSpeed ?? 1),
            language: general.language,
            clipboard: clipboard,
            quakeTerminal: quakeTerminal,
            appearanceMode: appearance.mode,
            tabRailAppIcons: appearance.tabRailAppIcons
        )
    }

    private func overviewForExport() -> SettingsExport.Overview {
        var overview = overview
        overview.enabled = overview.enabled ?? true
        overview.matchFocusBorder = overview.matchFocusBorder ?? true
        overview.invertScrollDirection = overview.invertScrollDirection ?? false
        overview.mouseScrollSpeed = overview.mouseScrollSpeed ?? 1
        return overview
    }

    private func statusBarForExport() -> SettingsExport.StatusBar {
        var statusBar = statusBar
        statusBar.showIcon = statusBar.showIcon ?? true
        return statusBar
    }

    private func gesturesForExport() -> SettingsExport.Gestures {
        var gestures = gestures
        gestures.overviewGestureEnabled = gestures.overviewGestureEnabled ?? false
        gestures.overviewGestureFingerCount = gestures.overviewGestureFingerCount ?? .four
        gestures.windowMoveEnabled = gestures.windowMoveEnabled ?? false
        gestures.windowMoveFingerCount = gestures.windowMoveFingerCount ?? .four
        gestures.windowResizeEnabled = gestures.windowResizeEnabled ?? false
        gestures.windowResizeFingerCount = gestures.windowResizeFingerCount ?? .three
        gestures.windowGestureSensitivity = gestures.windowGestureSensitivity ?? 1.0
        return gestures
    }
}
