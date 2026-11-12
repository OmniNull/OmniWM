// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WMController {
    func configureAppTheming() {
        settings.appTheming.onValuesChange = { [weak self] in
            self?.appThemingSettingsDidChange()
        }
    }

    func startAppTheming() {
        updateAppThemeService(reloadsEnabledApps: false)
    }

    func appThemingSettingsDidChange() {
        if let appThemeService, settings.appTheming.values.anyEnabled {
            appThemeService.settingsDidChange()
        } else {
            updateAppThemeService(reloadsEnabledApps: true)
        }
    }

    private func updateAppThemeService(reloadsEnabledApps: Bool) {
        guard settings.appTheming.values.anyEnabled else {
            appThemeService?.stop()
            appThemeService = nil
            pendingAppThemeApprovals = []
            return
        }
        guard appThemeService == nil else { return }
        let service = makeAppThemeService(settings.appTheming, appThemeEngine, reloadsEnabledApps)
        service.onGhosttyThemesChanged = { [weak self] in
            self?.reloadQuakeTerminalThemes()
        }
        service.approve(pendingAppThemeApprovals)
        pendingAppThemeApprovals = []
        workspaceBarManager.offerAppTheme(to: service)
        appThemeService = service
        service.start()
        service.settingsDidChange()
    }

    var appThemePreview: AppThemePreview {
        if let appThemeService { return appThemeService.preview }
        let values = settings.appTheming.values
        return AppThemePreview(
            engine: appThemeEngine,
            values: values,
            dark: AppThemeService.liveSystemIsDark()
        ) { [weak self] in
            self.map { AppThemePalette(theme: $0.workspaceBarManager.appTheme(), terminalColors: values.terminalColors) }
        }
    }

    func turnOnAppTheme(_ app: AppThemeBuiltIn, approving changes: [AppThemeChange]) {
        if let appThemeService {
            appThemeService.confirm(changes, enabling: app)
            return
        }
        pendingAppThemeApprovals = changes
        settings.appTheming.values.setEnabled(app, true)
    }

    func appThemePaletteDidChange(_ theme: ShellTheme) {
        appThemeService?.paletteDidChange(theme)
    }

    func appThemeShellIsOff(theme: @escaping @MainActor () -> ShellTheme, refresh: Bool = false) {
        appThemeService?.useThemeWhileShellIsOff(theme, refresh: refresh)
    }

    private func reloadQuakeTerminalThemes() {
        guard appliedQuakeTerminalSelection == .ghostty else { return }
        quakeTerminalController.reloadOpacityConfig()
    }
}
