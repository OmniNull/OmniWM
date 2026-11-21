// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

struct CommandPaletteRowWindow: Equatable {
    struct Slice: Equatable {
        var range: Range<Int>
        var before: Float
        var after: Float

        static let empty = Slice(range: 0 ..< 0, before: 0, after: 0)
    }

    static let shortestRow = Float(CommandPalettePanel.searchFieldHeight)

    private(set) var advances: [String: Float] = [:]
    private(set) var typical = shortestRow
    private var measured: Float = 0
    private(set) var viewport: Float = 0
    private(set) var offset: Float = 0
    private(set) var gap: Float = 0
    private(set) var anchor: String?
    private(set) var anchorTop: Float = 0

    mutating func reset() {
        advances.removeAll(keepingCapacity: true)
        typical = Self.shortestRow
        measured = 0
        viewport = 0
        offset = 0
        gap = 0
        anchor = nil
        anchorTop = 0
    }

    func advance(of id: String) -> Float {
        advances[id] ?? typical
    }

    func slice(ids: [String], selected: Int?, limit: Float) -> Slice {
        guard !ids.isEmpty else { return .empty }
        let view = viewport > 0 ? viewport : limit
        let extent = extent(of: ids, selected: selected)
        var top = min(max(extent.anchorStart.map { $0 - anchorTop } ?? offset, 0), max(extent.total - view, 0))
        if let selection = extent.selection {
            if selection.lowerBound < top {
                top = selection.lowerBound
            } else if selection.upperBound > top + view {
                top = selection.upperBound - view
            }
        }
        return band(of: ids, from: top - view, to: top + 2 * view, total: extent.total)
    }

    private struct Extent {
        var total: Float = 0
        var selection: Range<Float>?
        var anchorStart: Float?
    }

    private func extent(of ids: [String], selected: Int?) -> Extent {
        var extent = Extent()
        for (index, id) in ids.enumerated() {
            let advance = advance(of: id)
            if index == selected { extent.selection = extent.total ..< extent.total + advance }
            if extent.anchorStart == nil, id == anchor { extent.anchorStart = extent.total }
            extent.total += advance
        }
        return extent
    }

    private func band(of ids: [String], from low: Float, to high: Float, total: Float) -> Slice {
        var lower = ids.count
        var upper = 0
        var before: Float = 0
        var position: Float = 0
        var through: Float = 0
        for (index, id) in ids.enumerated() {
            let end = position + advance(of: id)
            if end > low, position < high {
                if lower == ids.count {
                    lower = index
                    before = position
                }
                upper = index + 1
                through = end
            }
            position = end
        }
        guard lower < upper else { return .empty }
        return Slice(
            range: lower ..< upper,
            before: lower > 0 ? max(before - gap, 0) : 0,
            after: upper < ids.count ? max(total - through - gap, 0) : 0
        )
    }

    mutating func record(viewport: Float, offset: Float, gap: Float) -> Bool {
        guard viewport != self.viewport || offset != self.offset || gap != self.gap else { return false }
        self.viewport = viewport
        self.offset = offset
        self.gap = gap
        return true
    }

    mutating func record(anchor id: String?, top: Float) -> Bool {
        guard id != anchor || top != anchorTop else { return false }
        anchor = id
        anchorTop = top
        return true
    }

    mutating func record(advance: Float, for id: String) -> Bool {
        guard advance > 0 else { return false }
        let assumed = self.advance(of: id)
        let previousTypical = typical
        measured += advance - (advances.updateValue(advance, forKey: id) ?? 0)
        typical = measured / Float(advances.count)
        return advance != assumed || typical != previousTypical
    }
}
