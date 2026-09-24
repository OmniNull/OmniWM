// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation
import OmniWMIPC

extension IPCFullscreenCommand {
    func actionDisplayName() -> LocalizedStringResource {
        switch self {
        case .managed: LocalizedStringResource(
                "command.fullscreen.toggle", defaultValue: "Toggle Fullscreen", table: "Commands", bundle: .omniWM
            )
        case .native: LocalizedStringResource(
                "command.fullscreen.toggleNative", defaultValue: "Toggle Native Fullscreen", table: "Commands",
                bundle: .omniWM
            )
        }
    }

    func actionSpec() -> ActionSpec {
        let id: String
        let binding: KeyBinding
        switch self {
        case .managed:
            id = "toggleFullscreen"
            binding = KeyBinding(keyCode: UInt32(kVK_Return), modifiers: UInt32(optionKey))
        case .native:
            id = "toggleNativeFullscreen"
            binding = .unassigned
        }
        return ActionCatalog.action(
            id: id,
            command: .fullscreen(self),
            category: .layout,
            binding: binding
        )
    }
}
