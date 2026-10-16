// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Synchronization

final class ShellResourceOperation: Sendable {
    private let active = Mutex(true)

    var isActive: Bool {
        active.withLock { $0 }
    }

    func cancel() {
        active.withLock { $0 = false }
    }

    func whileActive<T>(_ body: () -> T) -> T? {
        active.withLock { active in active ? body() : nil }
    }
}
