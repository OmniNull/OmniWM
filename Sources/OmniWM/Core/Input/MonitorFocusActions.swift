// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation
import OmniWMIPC

extension IPCMonitorFocusCommand {
    func actionDisplayName() -> LocalizedStringResource {
        switch self {
        case .previous: LocalizedStringResource(
                "command.monitor.previous", defaultValue: "Focus Previous Monitor", table: "Commands", bundle: .omniWM
            )
        case .next: LocalizedStringResource(
                "command.monitor.next", defaultValue: "Focus Next Monitor", table: "Commands", bundle: .omniWM
            )
        case .last: LocalizedStringResource(
                "command.monitor.last", defaultValue: "Focus Last Monitor", table: "Commands", bundle: .omniWM
            )
        }
    }

    func actionSpec() -> ActionSpec {
        let id: String
        let binding: KeyBinding
        switch self {
        case .previous:
            id = "focusMonitorPrevious"
            binding = .unassigned
        case .next:
            id = "focusMonitorNext"
            binding = KeyBinding(keyCode: UInt32(kVK_Tab), modifiers: UInt32(controlKey | cmdKey))
        case .last:
            id = "focusMonitorLast"
            binding = KeyBinding(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(controlKey | cmdKey))
        }
        return ActionCatalog.action(
            id: id,
            command: .monitorFocus(self),
            category: .monitor,
            binding: binding
        )
    }
}
