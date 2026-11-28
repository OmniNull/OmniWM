// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMAutomation
import OmniWMIPC

extension WMController {
    func performKeyboardModeCommand(_ command: IPCKeyboardModeCommand) -> ExternalCommandResult {
        hotkeys.performKeyboardModeCommand(command) ? .executed : .noChange
    }

    func updateKeyboardModeSettings() {
        hotkeys.configureKeyboardModes(settings.keyboardModes.export())
    }

    func keyboardModeDidChange(_ kind: KeyboardModeKind) {
        if keyboardModeKind != kind {
            keyboardModeKind = kind
            surfaceReconciler.noteBordersAndBarsChanged()
        }
        refreshStatusBar()
        refreshKeyboardModeIndicator()
        if scriptModeObserver != nil {
            ConfigScriptEventObservers.modeChanged(kind, controller: self)
        }
    }

    var keyboardModeName: String? {
        hotkeys.activeNamedKeyMode?.name
    }

    func refreshKeyboardModeIndicator() {
        guard keyboardModeKind != .normal else {
            keyboardModeIndicator.hide()
            return
        }
        let named = hotkeys.activeNamedKeyMode
        let entries = keyboardModeKind == .paused ? [] : named?.entries ?? hotkeys.keyboardModeTable.entries
        let guide = entries.map {
            KeyboardModeGuideEntry(key: $0.binding.displayString, title: $0.command.localizedDisplayName)
        }
        keyboardModeIndicator.show(
            kind: keyboardModeKind,
            name: named?.name,
            guide: guide,
            monitors: workspaceManager.monitors,
            interactionMonitorId: monitorForInteraction()?.id
        )
    }
}
