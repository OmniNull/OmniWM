// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension ShellConfig {
    func barLane(of widget: String) -> ShellLane? {
        ShellLane.allCases.first { lane in
            switch lane {
            case .leading: leading.contains(widget)
            case .center: center.contains(widget)
            case .trailing: trailing.contains(widget)
            }
        }
    }

    func lane(of widget: String) -> (lane: ShellLane, rank: Int) {
        if let index = leading.firstIndex(of: widget) {
            return (.leading, index)
        }
        if let index = center.firstIndex(of: widget) {
            return (.center, index)
        }
        return (.trailing, trailing.firstIndex(of: widget) ?? trailing.count)
    }

    func priorityRanks() -> [String: Int] {
        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(priority.count + leading.count + center.count + trailing.count)
        func rank(_ name: String) {
            if ranks[name] == nil { ranks[name] = ranks.count }
        }
        priority.forEach(rank)
        for depth in 0 ..< max(leading.count, trailing.count) {
            if depth < leading.count { rank(leading[depth]) }
            if depth < trailing.count { rank(trailing[trailing.count - 1 - depth]) }
        }
        center.forEach(rank)
        return ranks
    }
}
