// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMIPC

extension WMController {
    func performKeyboardModeCommand(_ command: IPCKeyboardModeCommand) -> ExternalCommandResult {
        hotkeys.performKeyboardModeCommand(command) ? .executed : .noChange
    }

    func updateKeyboardModeSettings() {
        hotkeys.configureKeyboardModes(settings.keyboardModes.export())
    }

    func keyboardModeDidChange(_ kind: KeyboardModeKind) {
        keyboardModeKind = kind
        surfaceReconciler.noteBordersAndBarsChanged()
        refreshStatusBar()
        refreshKeyboardModeIndicator()
        if scriptModeObserver != nil {
            ConfigScriptEventObservers.modeChanged(kind, controller: self)
        }
    }

    func refreshKeyboardModeIndicator() {
        guard keyboardModeKind != .normal else {
            keyboardModeIndicator.hide()
            return
        }
        let guide = keyboardModeKind == .paused ? [] : hotkeys.keyboardModeTable.entries.map {
            KeyboardModeGuideEntry(key: $0.binding.displayString, title: $0.command.localizedDisplayName)
        }
        keyboardModeIndicator.show(
            kind: keyboardModeKind,
            guide: guide,
            monitors: workspaceManager.monitors,
            interactionMonitorId: monitorForInteraction()?.id
        )
    }
}
