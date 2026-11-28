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
            focusNativeFullscreenOnWorkspaceSwitch: workspaces.focusNativeFullscreenOnSwitch,
            workspaceSwitchWrapAround: workspaces.switchWrapAround,
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
            slideWorkspaceSwitches: slideWorkspaceSwitches,
            pausePalettePasteDuringSecureInput: pausePalettePasteDuringSecureInput,
            showSecureInputExplanation: showSecureInputExplanation,
            language: language,
            launcher: launcher,
            commandPalette: commandPalette.export(),
            clipboard: clipboard.export(),
            quakeTerminal: quakeTerminal.export(),
            appTheming: appTheming.export(),
            tabRailAppIcons: tabRailAppIcons,
            shellPermissions: shellPermissions.export()
        )
    }

    func applyServiceSettings(_ export: SettingsExport) {
        preventSleepEnabled = export.preventSleepEnabled
        updateChecksEnabled = export.updateChecksEnabled
        ipcEnabled = export.ipcEnabled
        gestures.apply(export.gestures)
        statusBar.apply(export.statusBar)
        statusMenu.apply(export.statusMenu)
        hiddenBar.apply(export.hiddenBar)
        animationsEnabled = export.animationsEnabled
        animationSpeed = export.animationSpeed
        slideWorkspaceSwitches = export.slideWorkspaceSwitches
        pausePalettePasteDuringSecureInput = export.pausePalettePasteDuringSecureInput
        showSecureInputExplanation = export.showSecureInputExplanation
        language = export.language
        clipboard.apply(export.clipboard)
        launcher = export.launcher
        commandPalette.apply(export.commandPalette)

        quakeTerminal.apply(export.quakeTerminal, baseline: SettingsStore.defaultExport.quakeTerminal)

        tabRailAppIcons = export.tabRailAppIcons
        shellPermissions.apply(export.shellPermissions)
        appTheming.apply(export.appTheming)
    }
}
