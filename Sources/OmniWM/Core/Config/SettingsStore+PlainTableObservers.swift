// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension SettingsStore {
    func scheduleSaveOnPlainTableChanges() {
        statusBar.onChange = { [weak self] in self?.scheduleSave() }
        statusMenu.onChange = { [weak self] in self?.scheduleSave() }
        windowSwitcher.onChange = { [weak self] in self?.scheduleSave() }
        keyboardModes.onChange = { [weak self] in self?.scheduleSave() }
        commandPalette.onChange = { [weak self] in self?.scheduleSave() }
        hiddenBar.onChange = { [weak self] in self?.scheduleSave() }
        clipboard.onChange = { [weak self] in self?.scheduleSave() }
        quakeTerminal.onChange = { [weak self] in self?.scheduleSave() }
    }
}
