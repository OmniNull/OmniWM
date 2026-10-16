// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct WorkspaceBarZoneLayout: Layout {
    struct Lane: LayoutValueKey {
        static let defaultValue = ShellLane.trailing
    }

    let zones: WorkspaceBarZones
    let vertical: Bool
    var spacing: CGFloat = 8
    var inset: CGFloat = 4

    static func offsets(
        of items: [(lane: ShellLane, length: CGFloat)],
        length: CGFloat,
        zones: WorkspaceBarZones,
        spacing: CGFloat,
        inset: CGFloat
    ) -> [CGFloat] {
        var offsets = Array(repeating: CGFloat.zero, count: items.count)
        func extent(_ indices: ArraySlice<Int>) -> CGFloat {
            indices.reduce(0) { $0 + items[$1].length } + CGFloat(max(0, indices.count - 1)) * spacing
        }
        func run(_ indices: ArraySlice<Int>, from start: CGFloat, into offsets: inout [CGFloat]) {
            var cursor = start
            for index in indices {
                offsets[index] = cursor
                cursor += items[index].length + spacing
            }
        }
        func lane(_ lane: ShellLane) -> ArraySlice<Int> {
            ArraySlice(items.indices.filter { items[$0].lane == lane })
        }
        let center = lane(.center)
        let trailing = lane(.trailing)
        run(lane(.leading), from: inset, into: &offsets)
        run(trailing, from: length - inset - extent(trailing), into: &offsets)
        let gap = WorkspaceBarGeometry.notchGap
        switch (zones.notch, zones.mode) {
        case let (notch?, .rightOfNotch):
            run(center, from: notch.upperBound + gap, into: &offsets)
        case let (notch?, .leftOfNotch):
            run(center, from: notch.lowerBound - gap - extent(center), into: &offsets)
        case let (notch?, .splitAroundNotch):
            let left = center.prefix((center.count + 1) / 2)
            run(left, from: notch.lowerBound - gap - extent(left), into: &offsets)
            run(center.dropFirst(left.count), from: notch.upperBound + gap, into: &offsets)
        default:
            run(center, from: (length - extent(center)) / 2, into: &offsets)
        }
        return offsets
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let offsets = Self.offsets(
            of: subviews.indices.map { (subviews[$0][Lane.self], vertical ? sizes[$0].height : sizes[$0].width) },
            length: vertical ? bounds.height : bounds.width,
            zones: zones,
            spacing: spacing,
            inset: inset
        )
        for index in subviews.indices {
            let size = sizes[index]
            subviews[index].place(
                at: vertical
                    ? CGPoint(x: bounds.midX - size.width / 2, y: bounds.minY + offsets[index])
                    : CGPoint(x: bounds.minX + offsets[index], y: bounds.midY - size.height / 2),
                proposal: ProposedViewSize(size)
            )
        }
    }
}
