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

    func priorityOrder(hiddenBarEnabled: Bool) -> [String] {
        var shown = leading + center + trailing
        if let hidden = hiddenBarWidget, hiddenBarOverride?.enabled ?? hiddenBarEnabled, !shown.contains(hidden) {
            shown.append(hidden)
        }
        let ranks = priorityRanks()
        return shown.enumerated()
            .sorted { (ranks[$0.element] ?? .max, $0.offset) < (ranks[$1.element] ?? .max, $1.offset) }
            .map(\.element)
    }

    func priority(moving name: String, to index: Int, hiddenBarEnabled: Bool) -> [String]? {
        var order = priorityOrder(hiddenBarEnabled: hiddenBarEnabled)
        guard let from = order.firstIndex(of: name) else { return nil }
        order.remove(at: from)
        order.insert(name, at: min(max(0, from < index ? index - 1 : index), order.count))
        return order + priority.filter { !order.contains($0) }
    }

    func priority(shifting name: String, by delta: Int, hiddenBarEnabled: Bool) -> [String]? {
        var order = priorityOrder(hiddenBarEnabled: hiddenBarEnabled)
        guard let index = order.firstIndex(of: name), order.indices.contains(index + delta) else { return nil }
        order.swapAt(index, index + delta)
        return order + priority.filter { !order.contains($0) }
    }
}
