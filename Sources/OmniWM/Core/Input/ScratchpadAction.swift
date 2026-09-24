// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

enum ScratchpadAction: Equatable, Hashable {
    case assign(Int)
    case toggle(Int)
}

extension ScratchpadAction {
    func actionDisplayName() -> LocalizedStringResource {
        switch self {
        case let .assign(index): LocalizedStringResource(
                "command.scratchpad.assign", defaultValue: "Assign Focused Window to Scratchpad \(index)",
                table: "Commands", bundle: .omniWM
            )
        case let .toggle(index): LocalizedStringResource(
                "command.scratchpad.toggle", defaultValue: "Toggle Scratchpad \(index)", table: "Commands",
                bundle: .omniWM
            )
        }
    }

    func ipcCommandName() -> IPCCommandName? {
        switch self {
        case .assign:
            .scratchpad(.assign)
        case .toggle:
            .scratchpad(.toggle)
        }
    }

    var compatibility: LayoutCompatibility {
        switch self {
        case .assign,
             .toggle:
            .shared
        }
    }
}
