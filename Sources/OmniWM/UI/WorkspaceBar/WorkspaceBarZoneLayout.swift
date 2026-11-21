// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct WorkspaceBarZoneLayout: Layout {
    struct Lane: LayoutValueKey {
        static let defaultValue = ShellLane.trailing
    }

    struct Priority: LayoutValueKey {
        static let defaultValue = Int.max
    }

    struct Stops: LayoutValueKey {
        static let defaultValue: [CGFloat]? = nil
    }

    struct Item: Equatable {
        let lane: ShellLane
        let length: CGFloat
        var priority = Int.max
        var stops: [CGFloat]?

        func fitting(_ length: CGFloat) -> CGFloat {
            guard let stops else { return length }
            return stops.last { $0 <= length } ?? 0
        }
    }

    struct Span: Equatable {
        var start: CGFloat
        var length: CGFloat
    }

    let zones: WorkspaceBarZones
    let vertical: Bool
    var spacing: CGFloat = 8
    var inset: CGFloat = 4

    static let tightSpacing: CGFloat = 4

    static func spans(
        of items: [Item],
        length: CGFloat,
        zones: WorkspaceBarZones,
        spacing: CGFloat,
        inset: CGFloat
    ) -> [Span] {
        let bar = Bar(
            items: items,
            sides: Sides(items: items, zones: zones),
            length: length,
            spacing: spacing,
            inset: inset
        )
        var spans = items.map { Span(start: 0, length: $0.length) }
        var gaps = InlineArray<2, CGFloat>(repeating: spacing)
        for side in 0 ..< bar.sides.count {
            gaps[side] = bar.giveWay(on: side, spans: &spans)
        }
        bar.place(&spans, gaps: gaps)
        return spans
    }

    static func room(
        for index: Int,
        among items: [Item],
        length: CGFloat,
        zones: WorkspaceBarZones,
        spacing: CGFloat = 8,
        inset: CGFloat = 4
    ) -> CGFloat {
        Bar(
            items: items,
            sides: Sides(items: items, zones: zones),
            length: length,
            spacing: spacing,
            inset: inset
        ).room(for: index)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let spans = Self.spans(
            of: subviews.indices.map {
                Item(
                    lane: subviews[$0][Lane.self],
                    length: vertical ? sizes[$0].height : sizes[$0].width,
                    priority: subviews[$0][Priority.self],
                    stops: subviews[$0][Stops.self]
                )
            },
            length: vertical ? bounds.height : bounds.width,
            zones: zones,
            spacing: spacing,
            inset: inset
        )
        for index in subviews.indices {
            let size = sizes[index]
            let span = spans[index]
            subviews[index].place(
                at: vertical
                    ? CGPoint(x: bounds.midX - size.width / 2, y: bounds.minY + span.start)
                    : CGPoint(x: bounds.minX + span.start, y: bounds.midY - size.height / 2),
                proposal: vertical
                    ? ProposedViewSize(width: size.width, height: span.length)
                    : ProposedViewSize(width: span.length, height: size.height)
            )
        }
    }
}

private struct Bar {
    let items: [WorkspaceBarZoneLayout.Item]
    let sides: Sides
    let length: CGFloat
    let spacing: CGFloat
    let inset: CGFloat

    func room(on side: Int) -> CGFloat {
        let gap = WorkspaceBarGeometry.notchGap
        guard let notch = sides.notch else { return length - inset * 2 }
        return side == 0 ? notch.lowerBound - gap - inset : length - inset - notch.upperBound - gap
    }

    private var tight: CGFloat {
        min(spacing, WorkspaceBarZoneLayout.tightSpacing)
    }

    func room(for target: Int) -> CGFloat {
        var own = 0
        sides.forEach(items) { index, side in
            if index == target { own = side }
        }
        var room = room(on: own)
        sides.forEach(items) { index, side in
            guard side == own, index != target, items[index].length > 0 else { return }
            room -= items[index].length + tight
        }
        return room
    }

    func giveWay(on side: Int, spans: inout [WorkspaceBarZoneLayout.Span]) -> CGFloat {
        let room = room(on: side)
        while true {
            var total: CGFloat = 0
            var count = 0
            var victim: Int?
            sides.forEach(items) { index, itemSide in
                guard itemSide == side, spans[index].length > 0 else { return }
                total += spans[index].length
                count += 1
                if victim.map({ (items[index].priority, index) > (items[$0].priority, $0) }) != false {
                    victim = index
                }
            }
            let gaps = CGFloat(count - 1)
            guard let victim, total + gaps * spacing > room else { return spacing }
            let overflow = total + gaps * tight - room
            guard overflow > 0 else { return (room - total) / gaps }
            let kept = items[victim].fitting(spans[victim].length - overflow)
            guard kept <= 0 else {
                total -= spans[victim].length - kept
                spans[victim].length = kept
                return gaps > 0 ? min(spacing, (room - total) / gaps) : spacing
            }
            spans[victim].length = 0
        }
    }

    func place(_ spans: inout [WorkspaceBarZoneLayout.Span], gaps: InlineArray<2, CGFloat>) {
        var runs = InlineArray<4, CGFloat?>(repeating: nil)
        sides.forEach(items) { index, side in
            guard spans[index].length > 0 else { return }
            let group = Group(items[index].lane, side: side).rawValue
            runs[group] = runs[group].map { $0 + gaps[side] + spans[index].length } ?? spans[index].length
        }
        func extent(_ group: Group) -> CGFloat {
            runs[group.rawValue] ?? 0
        }
        func clearance(_ group: Group) -> CGFloat {
            runs[group.rawValue].map { $0 + gaps[0] } ?? 0
        }
        var cursors = InlineArray<4, CGFloat>(repeating: 0)
        cursors[Group.leading.rawValue] = inset
        cursors[Group.trailing.rawValue] = length - inset - extent(.trailing)
        let gap = WorkspaceBarGeometry.notchGap
        if let notch = sides.notch {
            cursors[Group.nearCenter.rawValue] = notch.lowerBound - gap - extent(.nearCenter)
            cursors[Group.farCenter.rawValue] = notch.upperBound + gap
        } else {
            let center = extent(.nearCenter)
            let lower = inset + clearance(.leading)
            let upper = length - inset - clearance(.trailing) - center
            cursors[Group.nearCenter.rawValue] = max(lower, min((length - center) / 2, upper))
        }
        sides.forEach(items) { index, side in
            let group = Group(items[index].lane, side: side).rawValue
            spans[index].start = cursors[group]
            if spans[index].length > 0 {
                cursors[group] += spans[index].length + gaps[side]
            }
        }
    }
}

private struct Sides {
    let notch: ClosedRange<CGFloat>?
    let nearCenterCount: Int

    init(items: [WorkspaceBarZoneLayout.Item], zones: WorkspaceBarZones) {
        let centers = items.reduce(0) { $1.lane == .center ? $0 + 1 : $0 }
        switch zones.mode {
        case .rightOfNotch:
            notch = zones.notch
            nearCenterCount = 0
        case .leftOfNotch:
            notch = zones.notch
            nearCenterCount = centers
        case .splitAroundNotch:
            notch = zones.notch
            nearCenterCount = (centers + 1) / 2
        case .off,
             .moveBelowMenuBar:
            notch = nil
            nearCenterCount = centers
        }
    }

    var count: Int {
        notch == nil ? 1 : 2
    }

    func forEach(_ items: [WorkspaceBarZoneLayout.Item], _ body: (Int, Int) -> Void) {
        var centerOrdinal = 0
        for index in items.indices {
            let lane = items[index].lane
            let side = switch lane {
            case _ where notch == nil: 0
            case .leading: 0
            case .center: centerOrdinal < nearCenterCount ? 0 : 1
            case .trailing: 1
            }
            body(index, side)
            if lane == .center {
                centerOrdinal += 1
            }
        }
    }
}

private enum Group: Int {
    case leading
    case nearCenter
    case farCenter
    case trailing

    init(_ lane: ShellLane, side: Int) {
        self = switch lane {
        case .leading: .leading
        case .center: side == 0 ? .nearCenter : .farCenter
        case .trailing: .trailing
        }
    }
}
