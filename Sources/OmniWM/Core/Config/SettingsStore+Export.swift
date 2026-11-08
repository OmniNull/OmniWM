// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension SettingsStore {
    func toExport() -> SettingsExport {
        SettingsExport(
            hotkeysEnabled: hotkeysEnabled,
            focus: focus.export(),
            mouseWarp: pointer.export(),
            routing: monitors.export(),
            monitorRanking: monitors.ranking,
            gaps: gaps.export(),
            niri: niri.export(),
            workspaceConfigurations: workspaces.configurations,
            defaultLayoutType: workspaces.defaultLayoutType,
            borders: borders.export(),
            overview: overview.export(),
            windowSwitcher: windowSwitcher.export(),
            keyboardModes: keyboardModes.export(),
            workspaceAutoBackAndForth: workspaces.autoBackAndForth,
            hotkeyBindings: hotkeyBindings,
            systemHyperTrigger: systemHyperTrigger,
            hyperKeyModifiers: hyperKeyModifiers,
            workspaceBar: workspaceBar.export(),
            island: island.export(),
            scratchpads: SettingsExport.Scratchpads(labels: scratchpadLabels),
            monitorBarSettings: workspaceBar.monitorOverrides,
            appRules: appRules,
            monitorOrientationSettings: monitors.orientationOverrides,
            monitorNiriSettings: niri.monitorOverrides,
            dwindle: dwindle.export(),
            monitorDwindleSettings: dwindle.monitorOverrides,
            monitorGapSettings: gaps.monitorOverrides.filter(\.hasOverrides),
            preventSleepEnabled: preventSleepEnabled,
            updateChecksEnabled: updateChecksEnabled,
            ipcEnabled: ipcEnabled,
            gestures: gestures.export(),
            statusBar: statusBar.export(),
            statusMenu: statusMenu.export(),
            hiddenBar: hiddenBar.export(),
            animationsEnabled: animationsEnabled,
            animationSpeed: animationSpeed,
            language: language,
            launcher: launcher,
            clipboard: clipboard.export(),
            quakeTerminal: quakeTerminal.export(),
            appearanceMode: appearanceMode,
            tabRailAppIcons: tabRailAppIcons,
            shellPermissions: shellPermissions.export()
        )
    }
}
