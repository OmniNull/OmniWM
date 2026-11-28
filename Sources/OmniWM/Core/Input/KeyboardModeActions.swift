// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMAutomation
import OmniWMIPC

extension IPCKeyboardModeCommand {
    func actionDisplayName() -> LocalizedStringResource {
        switch self {
        case .togglePause: LocalizedStringResource(
                "command.keyboardMode.togglePause", defaultValue: "Pause or Resume Shortcuts", table: "Commands",
                bundle: .omniWM
            )
        case .beginPrefix: LocalizedStringResource(
                "command.keyboardMode.beginPrefix", defaultValue: "Begin Prefix", table: "Commands", bundle: .omniWM
            )
        case .toggleWindowMode: LocalizedStringResource(
                "command.keyboardMode.toggleWindowMode", defaultValue: "Enter or Leave Window Mode", table: "Commands",
                bundle: .omniWM
            )
        case .exit: LocalizedStringResource(
                "command.keyboardMode.exit", defaultValue: "Leave Keyboard Mode", table: "Commands", bundle: .omniWM
            )
        }
    }

    func actionSpec() -> ActionSpec {
        let id: String
        let keywords: [String]
        switch self {
        case .togglePause:
            id = "toggleShortcutPause"
            keywords = ["pause", "resume", "shortcuts", "hotkeys", "passthrough", "disable"]
        case .beginPrefix:
            id = "beginPrefix"
            keywords = ["prefix", "leader", "tmux", "mode", "keys"]
        case .toggleWindowMode:
            id = "toggleWindowMode"
            keywords = ["window mode", "mode", "layer", "keys"]
        case .exit:
            id = "exitKeyboardMode"
            keywords = ["exit", "leave", "mode", "resume"]
        }
        return ActionCatalog.action(
            id: id,
            command: .keyboardMode(self),
            category: .focus,
            binding: .unassigned,
            keywords: keywords
        )
    }
}
