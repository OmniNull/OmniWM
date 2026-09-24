// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation
import OmniWMIPC

extension IPCWindowStateCommand {
    func actionDisplayName() -> LocalizedStringResource {
        switch self {
        case .toggleFloating: LocalizedStringResource(
                "command.windowState.toggleFloating", defaultValue: "Toggle Focused Window Floating", table: "Commands",
                bundle: .omniWM
            )
        case .close: LocalizedStringResource(
                "command.windowState.close", defaultValue: "Close Focused Window", table: "Commands", bundle: .omniWM
            )
        }
    }

    func actionSpec() -> ActionSpec {
        let id: String
        let binding: KeyBinding
        let keywords: [String]
        let category: HotkeyCategory
        switch self {
        case .toggleFloating:
            id = "toggleFocusedWindowFloating"
            binding = .unassigned
            keywords = ["float", "floating"]
            category = .layout
        case .close:
            id = "closeFocusedWindow"
            binding = .unassigned
            keywords = ["close", "quit", "window"]
            category = .focus
        }
        return ActionCatalog.action(
            id: id,
            command: .windowState(self),
            category: category,
            binding: binding,
            keywords: keywords
        )
    }
}
