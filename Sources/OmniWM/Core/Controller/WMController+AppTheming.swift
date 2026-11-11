// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WMController {
    func makeAppThemeService() -> AppThemeService {
        let service = AppThemeService.live(settings: settings.appTheming)
        service.onGhosttyThemesChanged = { [weak self] in
            self?.reloadQuakeTerminalThemes()
        }
        settings.appTheming.onValuesChange = { [weak service] in
            service?.settingsDidChange()
        }
        service.start()
        return service
    }

    func appThemePaletteDidChange(_ theme: ShellTheme) {
        appThemeService.paletteDidChange(theme)
    }

    func appThemeShellIsOff(theme: @escaping @MainActor () -> ShellTheme, refresh: Bool = false) {
        appThemeService.useThemeWhileShellIsOff(theme, refresh: refresh)
    }

    private func reloadQuakeTerminalThemes() {
        guard appliedQuakeTerminalSelection == .ghostty else { return }
        quakeTerminalController.reloadOpacityConfig()
    }
}
