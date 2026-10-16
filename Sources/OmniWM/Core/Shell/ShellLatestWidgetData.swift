// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Synchronization

final class ShellLatestWidgetData: Sendable {
    struct Snapshot: Sendable {
        var revision: UInt64 = 0
        var data = ShellWidgetData()
    }

    private let snapshot = Mutex(Snapshot())

    @discardableResult
    func publish(_ data: ShellWidgetData) -> UInt64 {
        snapshot.withLock { snapshot in
            let changed = data.changedKeys(from: snapshot.data)
            guard changed != 0 else { return 0 }
            snapshot.data = data
            snapshot.revision += 1
            return changed
        }
    }

    func read(after revision: UInt64) -> Snapshot? {
        snapshot.withLock { $0.revision == revision ? nil : $0 }
    }
}
