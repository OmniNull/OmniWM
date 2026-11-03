// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum ShellInstanceKey: Hashable, Sendable {
    case bar(ShellBarKey)
    case window(UUID)

    var bar: ShellBarKey? {
        guard case let .bar(key) = self else { return nil }
        return key
    }
}

struct ShellWindowContext: Equatable, Sendable {
    let id: UUID
    let width: Double
    let height: Double
    let visible: Bool
    var viewName = "window"
}
