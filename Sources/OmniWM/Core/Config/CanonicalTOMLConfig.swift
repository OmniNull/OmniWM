// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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
    var windowSwitcher: SettingsExport.WindowSwitcher
    var keyboardModes: SettingsExport.KeyboardModes
    var workspaceBar: SettingsExport.WorkspaceBar
    var island: SettingsExport.Island
    var gestures: SettingsExport.Gestures
    var statusBar: SettingsExport.StatusBar
    var statusMenu: SettingsExport.StatusMenu
    var hiddenBar: SettingsExport.HiddenBar
    var launcher: LauncherConfiguration
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
    var shellPermissions: ShellPermissionDecisions

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
        var workspaceAutoBackAndForth: Bool?
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
        focus.edgeNavigationInterval = FocusSettings.normalizedEdgeNavigationInterval(focus.edgeNavigationInterval)
        mouseWarp = try container.decode(SettingsExport.MouseWarp.self, forKey: .mouseWarp)
        routing = try container.decode(SettingsExport.Routing.self, forKey: .routing)
        monitors = try container.decodeIfPresent(Monitors.self, forKey: .monitors)
        gaps = try container.decode(SettingsExport.Gaps.self, forKey: .gaps)
        niri = try container.decode(SettingsExport.Niri.self, forKey: .niri)
        niri.edgeGaps = niri.edgeGaps ?? true
        niri.moveWindowStacksIntoColumn = niri.moveWindowStacksIntoColumn ?? true
        dwindle = try container.decode(SettingsExport.Dwindle.self, forKey: .dwindle)
        borders = try container.decode(SettingsExport.Borders.self, forKey: .borders)
        overview = try container.decode(SettingsExport.Overview.self, forKey: .overview)
        windowSwitcher = try container.decodeIfPresent(SettingsExport.WindowSwitcher.self, forKey: .windowSwitcher)
            ?? SettingsExport.WindowSwitcher()
        keyboardModes = try container.decodeIfPresent(SettingsExport.KeyboardModes.self, forKey: .keyboardModes)
            ?? SettingsExport.KeyboardModes()
        workspaceBar = try container.decode(SettingsExport.WorkspaceBar.self, forKey: .workspaceBar)
        island = try container.decodeIfPresent(SettingsExport.Island.self, forKey: .island) ?? .defaults()
        gestures = try container.decode(SettingsExport.Gestures.self, forKey: .gestures)
        statusBar = try container.decode(SettingsExport.StatusBar.self, forKey: .statusBar)
        statusMenu = try Self.decodeStatusMenu(from: container)
        hiddenBar = try container.decode(SettingsExport.HiddenBar.self, forKey: .hiddenBar)
        launcher = try container.decodeIfPresent(LauncherConfiguration.self, forKey: .launcher) ?? .init()
        clipboard = try container.decode(SettingsExport.Clipboard.self, forKey: .clipboard)
        quakeTerminal = try container.decode(SettingsExport.QuakeTerminal.self, forKey: .quakeTerminal)
        scratchpads = try container.decode(SettingsExport.Scratchpads.self, forKey: .scratchpads)
        appearance = try container.decode(Appearance.self, forKey: .appearance)
        hotkeys = try Self.decodeHotkeys(from: container)
        workspaces = try container.decode([WorkspaceConfiguration].self, forKey: .workspaces)
        appRules = try container.decode([AppRule].self, forKey: .appRules)
        monitorBarOverrides = try container
            .decodeIfPresent([MonitorBarSettings].self, forKey: .monitorBarOverrides) ?? []
        monitorOrientationOverrides = try container.decodeIfPresent(
            [MonitorOrientationSettings].self,
            forKey: .monitorOrientationOverrides
        ) ?? []
        monitorNiriOverrides = try container
            .decodeIfPresent([MonitorNiriSettings].self, forKey: .monitorNiriOverrides) ?? []
        monitorDwindleOverrides = try container.decodeIfPresent(
            [MonitorDwindleSettings].self,
            forKey: .monitorDwindleOverrides
        ) ?? []
        monitorGapOverrides = try container
            .decodeIfPresent([MonitorGapSettings].self, forKey: .monitorGapOverrides) ?? []
        shellPermissions = try container
            .decodeIfPresent(ShellPermissionDecisions.self, forKey: .shellPermissions) ?? ShellPermissionDecisions()
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
            language: export.language,
            workspaceAutoBackAndForth: export.workspaceAutoBackAndForth
        )
        focus = export.focus
        focus.edgeNavigationInterval = FocusSettings.normalizedEdgeNavigationInterval(focus.edgeNavigationInterval)
        mouseWarp = export.mouseWarp
        routing = export.routing
        monitors = export.monitorRanking.isEmpty ? nil : Monitors(ranking: export.monitorRanking)
        gaps = export.gaps
        niri = export.niri
        dwindle = export.dwindle
        borders = export.borders
        overview = export.overview
        windowSwitcher = export.windowSwitcher
        keyboardModes = export.keyboardModes
        workspaceBar = export.workspaceBar
        island = export.island
        gestures = export.gestures
        statusBar = export.statusBar
        statusMenu = export.statusMenu
        hiddenBar = export.hiddenBar
        launcher = export.launcher
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
        shellPermissions = export.shellPermissions
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
            windowSwitcher: windowSwitcher,
            keyboardModes: keyboardModes,
            workspaceAutoBackAndForth: general.workspaceAutoBackAndForth ?? false,
            hotkeyBindings: hotkeys,
            systemHyperTrigger: general.systemHyperTrigger,
            hyperKeyModifiers: general.hyperKeyModifiers,
            workspaceBar: workspaceBar,
            island: island,
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
            statusMenu: statusMenuForExport(),
            hiddenBar: hiddenBar,
            animationsEnabled: general.animationsEnabled,
            animationSpeed: AnimationSpeed.normalized(general.animationSpeed ?? 1),
            language: general.language,
            launcher: launcher,
            clipboard: clipboard,
            quakeTerminal: quakeTerminal,
            appearanceMode: appearance.mode,
            tabRailAppIcons: appearance.tabRailAppIcons,
            shellPermissions: shellPermissions
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

    private static func decodeHotkeys(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [HotkeyBinding] {
        let persisted = try container.decode([PersistedHotkeyBinding].self, forKey: .hotkeys)
        return try HotkeyBindingRegistry.resolve(persisted)
    }

    private static func decodeStatusMenu(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> SettingsExport.StatusMenu {
        try container.decodeIfPresent(SettingsExport.StatusMenu.self, forKey: .statusMenu) ?? .defaults()
    }

    private func statusMenuForExport() -> SettingsExport.StatusMenu {
        var statusMenu = statusMenu
        let defaults = SettingsExport.StatusMenu.defaults()
        statusMenu.showControls = statusMenu.showControls ?? defaults.showControls
        statusMenu.showAppMenu = statusMenu.showAppMenu ?? defaults.showAppMenu
        statusMenu.showControlHelp = statusMenu.showControlHelp ?? defaults.showControlHelp
        statusMenu.showMenuItems = statusMenu.showMenuItems ?? defaults.showMenuItems
        statusMenu.hiddenControls = statusMenu.hiddenControls ?? defaults.hiddenControls
        statusMenu.hiddenMenuItems = statusMenu.hiddenMenuItems ?? defaults.hiddenMenuItems
        return statusMenu
    }

    private func statusBarForExport() -> SettingsExport.StatusBar {
        var statusBar = statusBar
        statusBar.showIcon = statusBar.showIcon ?? true
        return statusBar
    }

    private func gesturesForExport() -> SettingsExport.Gestures {
        var gestures = gestures
        gestures.workspaceSwipeEdgeBehavior = gestures.workspaceSwipeEdgeBehavior ?? .cycle
        gestures.overviewGestureEnabled = gestures.overviewGestureEnabled ?? false
        gestures.overviewGestureFingerCount = gestures.overviewGestureFingerCount ?? .four
        gestures.windowMoveEnabled = gestures.windowMoveEnabled ?? false
        gestures.windowMoveFingerCount = gestures.windowMoveFingerCount ?? .four
        gestures.windowResizeEnabled = gestures.windowResizeEnabled ?? false
        gestures.windowResizeFingerCount = gestures.windowResizeFingerCount ?? .three
        gestures.windowGestureSensitivity = gestures.windowGestureSensitivity ?? 1.0
        gestures.resizePreviewStyle = gestures.resizePreviewStyle ?? .live
        gestures.dwindleGroupDragAcrossDisplays = gestures.dwindleGroupDragAcrossDisplays ?? .group
        gestures.adoptNativeResize = gestures.adoptNativeResize ?? false
        gestures.adoptNativeMoveAcrossDisplays = gestures.adoptNativeMoveAcrossDisplays ?? false
        return gestures
    }
}
