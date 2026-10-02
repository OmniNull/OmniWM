// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct WindowSwitcherSelection {
    private(set) var tokens: [WindowToken] = []
    private(set) var selected: WindowToken?

    mutating func begin(tokens: [WindowToken], current: WindowToken?, reverse: Bool) {
        self.tokens = tokens
        selected = current.flatMap { tokens.contains($0) ? $0 : nil }
        cycle(reverse: reverse)
    }

    mutating func reconcile(tokens: [WindowToken]) {
        let previousIndex = selected.flatMap { self.tokens.firstIndex(of: $0) } ?? 0
        self.tokens = tokens
        guard let selected, tokens.contains(selected) else {
            self.selected = tokens.isEmpty ? nil : tokens[min(previousIndex, tokens.count - 1)]
            return
        }
    }

    mutating func cycle(reverse: Bool) {
        guard !tokens.isEmpty else {
            selected = nil
            return
        }
        guard let selected, let index = tokens.firstIndex(of: selected) else {
            self.selected = reverse ? tokens.last : tokens.first
            return
        }
        self.selected = tokens[(index + (reverse ? -1 : 1) + tokens.count) % tokens.count]
    }

    mutating func select(_ token: WindowToken) {
        guard tokens.contains(token) else { return }
        selected = token
    }

    mutating func moveRow(columns: Int, reverse: Bool) {
        guard columns > 0, let selected, let index = tokens.firstIndex(of: selected), !tokens.isEmpty else { return }
        let rows = (tokens.count + columns - 1) / columns
        let row = (index / columns + (reverse ? -1 : 1) + rows) % rows
        self.selected = tokens[min(row * columns + index % columns, tokens.count - 1)]
    }
}
