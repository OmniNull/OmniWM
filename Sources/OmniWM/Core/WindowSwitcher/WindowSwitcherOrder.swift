// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

enum WindowSwitcherOrder: String, Codable {
    case omniLayout
    case lastUsed

    func orderedItems(_ items: [WindowSwitcherItem], recent: [WindowToken]) -> [WindowSwitcherItem] {
        guard self == .lastUsed else { return items }
        var remaining = Dictionary(uniqueKeysWithValues: items.map { ($0.handle.id, $0) })
        let ordered = recent.compactMap { remaining.removeValue(forKey: $0) }
        return ordered + items.filter { remaining[$0.handle.id] != nil }
    }
}
