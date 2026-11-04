// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WindowMarkHotkeyAction {
    func actionDisplayName() -> LocalizedStringResource {
        switch self {
        case .set: LocalizedStringResource(
                "command.windowMark.set", defaultValue: "Set Mark on Focused Window", table: "Commands",
                bundle: .omniWM
            )
        case .remove: LocalizedStringResource(
                "command.windowMark.remove", defaultValue: "Remove Mark from Focused Window", table: "Commands",
                bundle: .omniWM
            )
        }
    }
}
