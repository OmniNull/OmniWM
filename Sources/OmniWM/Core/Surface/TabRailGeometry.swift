// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

enum TabRailMetrics {
    static let trackWidth: CGFloat = 10
    static let totalWidth: CGFloat = trackWidth
    static let hitWidth: CGFloat = 22
    static let trackCornerRadius: CGFloat = 5
    static let segmentCornerRadius: CGFloat = 2.5
    static let preferredSegmentHeight: CGFloat = 28
    static let minimumSegmentHeight: CGFloat = 2
    static let preferredSegmentGap: CGFloat = 4
    static let minimumSegmentGap: CGFloat = 0
    static let minVisibleIntersection: CGFloat = 10
    static let minimumRailHeight: CGFloat = 8
    static let segmentWidth: CGFloat = 3
    static let segmentVerticalInset: CGFloat = 2
    static let trackEndInset: CGFloat = 6
    static let trackBorderWidth: CGFloat = 0.5
    static let hoverCardSize = CGSize(width: 260, height: 52)
    static let hoverCardGap: CGFloat = 8

    static func selectedColor(hovered: Bool) -> NSColor {
        let baseAlpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.86
        return NSColor.controlAccentColor.withAlphaComponent(min(1, baseAlpha + (hovered ? 0.1 : 0)))
    }

    static func unselectedColor(hovered: Bool, railHovered: Bool) -> NSColor {
        let baseAlpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.82 : 0.58
        let hoverAlpha: CGFloat = hovered ? 0.24 : (railHovered ? 0.08 : 0)
        return NSColor.labelColor.withAlphaComponent(min(0.92, baseAlpha + hoverAlpha))
    }

    static var hoverColor: NSColor {
        let alpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.2 : 0.1
        return NSColor.controlAccentColor.withAlphaComponent(alpha)
    }

    static var trackBorderColor: NSColor {
        let alpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.72 : 0.28
        return NSColor.separatorColor.withAlphaComponent(alpha)
    }
}

@MainActor
enum TabRailPlacement {
    static func frame(
        for visibleTileFrame: CGRect, tabCount: Int, style: TabRailStyle, displayFrame: CGRect? = nil
    ) -> CGRect {
        guard tabCount > 0,
              TabRailManager.isRenderable(visibleTileFrame: visibleTileFrame)
        else { return .zero }
        let width = style.hitWidth
        let height = style.fittedHeight(tabCount: tabCount, availableHeight: visibleTileFrame.height)
        guard height > 1 else { return .zero }
        let x = visibleTileFrame.minX - (width - style.reservedWidth)
        let y = visibleTileFrame.minY + (visibleTileFrame.height - height) / 2
        let frame = CGRect(x: x, y: y, width: width, height: height)
        return displayFrame.map { frame.intersection($0) } ?? frame
    }
}

enum TabRailOrderingPolicy {
    static func shouldReorder(
        forceOrdering: Bool,
        wasOrderedIn: Bool,
        lastActiveWindowId: Int?,
        activeWindowId: Int?
    ) -> Bool {
        forceOrdering || !wasOrderedIn || lastActiveWindowId != activeWindowId
    }
}

struct TabRailLayout: Equatable {
    struct Item: Equatable {
        let visualIndex: Int
        let hitRect: CGRect
        let pillRect: CGRect
    }

    static let empty = TabRailLayout(railRect: .zero, barRect: .zero, items: [])

    let railRect: CGRect
    let barRect: CGRect
    let items: [Item]

    init(railRect: CGRect, barRect: CGRect, items: [Item]) {
        self.railRect = railRect
        self.barRect = barRect
        self.items = items
    }

    init(tabCount: Int, bounds: CGRect, activeVisualIndex: Int = 0, scale: CGFloat = 2) {
        guard tabCount > 0,
              bounds.width > 0,
              bounds.height >= TabRailMetrics.minimumRailHeight
        else {
            self = .empty
            return
        }

        let segmentGap = Self.segmentGap(tabCount: tabCount, availableHeight: bounds.height)
        let segmentHeight = Self.segmentHeight(
            tabCount: tabCount,
            availableHeight: bounds.height,
            segmentGap: segmentGap
        )
        guard segmentHeight > 0 else {
            self = .empty
            return
        }

        let totalHeight = Self.totalHeight(tabCount: tabCount, segmentHeight: segmentHeight, segmentGap: segmentGap)
        let railY = bounds.minY + max(0, (bounds.height - totalHeight) / 2)
        let railRect = CGRect(x: bounds.minX, y: railY, width: bounds.width, height: min(bounds.height, totalHeight))
        let sourceBarRect = Self.visualRailRect(in: railRect)

        var items: [Item] = []
        items.reserveCapacity(tabCount)

        for visualIndex in 0 ..< tabCount {
            let y = railRect.maxY
                - CGFloat(visualIndex + 1) * segmentHeight
                - CGFloat(visualIndex) * segmentGap
            let hitRect = CGRect(
                x: railRect.minX,
                y: y,
                width: railRect.width,
                height: segmentHeight
            ).intersection(railRect)
            let pillRect = CGRect(
                x: sourceBarRect.minX,
                y: hitRect.minY + TabRailMetrics.segmentVerticalInset,
                width: sourceBarRect.width,
                height: max(0, hitRect.height - TabRailMetrics.segmentVerticalInset * 2)
            )
            guard !hitRect.isNull, hitRect.width > 0, hitRect.height > 0 else { continue }
            items.append(Item(visualIndex: visualIndex, hitRect: hitRect, pillRect: pillRect))
        }

        self = Self.packedLayout(
            items: items,
            railRect: railRect,
            sourceBarRect: sourceBarRect,
            activeVisualIndex: min(max(0, activeVisualIndex), tabCount - 1),
            scale: scale
        )
    }

    private static func packedLayout(
        items: [Item],
        railRect: CGRect,
        sourceBarRect: CGRect,
        activeVisualIndex: Int,
        scale: CGFloat
    ) -> Self {
        let sourceRects = Dictionary(uniqueKeysWithValues: items.map { ($0.visualIndex, $0.pillRect) })
        let packedHeight = TabRailSegmentGeometry.packedHeight(
            sourceRects: sourceRects,
            selectedVisualIndex: activeVisualIndex,
            verticalMargin: TabRailMetrics.segmentVerticalInset,
            endInset: TabRailMetrics.trackEndInset,
            scale: scale
        )
        let trackHeight = min(sourceBarRect.height, packedHeight)
        let barRect = CGRect(
            x: sourceBarRect.minX,
            y: sourceBarRect.midY - trackHeight / 2,
            width: sourceBarRect.width,
            height: trackHeight
        )
        let markerRects = TabRailSegmentGeometry.equallyPaddedRects(
            sourceRects: sourceRects,
            trackBounds: barRect,
            selectedVisualIndex: activeVisualIndex,
            verticalMargin: TabRailMetrics.segmentVerticalInset,
            scale: scale
        )
        let hitRects = TabRailSegmentGeometry.hitRects(markerRects: markerRects, railRect: railRect)
        let packedItems = items.compactMap { item -> Item? in
            guard let markerRect = markerRects[item.visualIndex],
                  let hitRect = hitRects[item.visualIndex] else { return nil }
            return Item(visualIndex: item.visualIndex, hitRect: hitRect, pillRect: markerRect)
        }
        return Self(railRect: railRect, barRect: barRect, items: packedItems)
    }

    static func fittedHeight(tabCount: Int, availableHeight: CGFloat) -> CGFloat {
        guard tabCount > 0, availableHeight >= TabRailMetrics.minimumRailHeight else { return 0 }
        let segmentGap = segmentGap(tabCount: tabCount, availableHeight: availableHeight)
        let segmentHeight = segmentHeight(
            tabCount: tabCount,
            availableHeight: availableHeight,
            segmentGap: segmentGap
        )
        guard segmentHeight >= TabRailMetrics.minimumSegmentHeight else { return 0 }
        return min(
            availableHeight,
            totalHeight(tabCount: tabCount, segmentHeight: segmentHeight, segmentGap: segmentGap)
        )
    }

    static func visualRailRect(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.maxX - TabRailMetrics.totalWidth,
            y: bounds.minY,
            width: TabRailMetrics.totalWidth,
            height: bounds.height
        )
    }

    private static func totalHeight(tabCount: Int, segmentHeight: CGFloat, segmentGap: CGFloat) -> CGFloat {
        CGFloat(tabCount) * segmentHeight + CGFloat(max(0, tabCount - 1)) * segmentGap
    }

    private static func segmentGap(tabCount: Int, availableHeight: CGFloat) -> CGFloat {
        guard tabCount > 1 else { return 0 }
        let preferredHeight = totalHeight(
            tabCount: tabCount,
            segmentHeight: TabRailMetrics.preferredSegmentHeight,
            segmentGap: TabRailMetrics.preferredSegmentGap
        )
        guard preferredHeight > availableHeight else {
            return TabRailMetrics.preferredSegmentGap
        }
        let scale = max(0, availableHeight / preferredHeight)
        return max(
            TabRailMetrics.minimumSegmentGap,
            min(TabRailMetrics.preferredSegmentGap, TabRailMetrics.preferredSegmentGap * scale)
        )
    }

    private static func segmentHeight(
        tabCount: Int,
        availableHeight: CGFloat,
        segmentGap: CGFloat
    ) -> CGFloat {
        let totalGapHeight = CGFloat(max(0, tabCount - 1)) * segmentGap
        let availableForSegments = max(0, availableHeight - totalGapHeight)
        let fitHeight = availableForSegments / CGFloat(tabCount)
        guard fitHeight >= TabRailMetrics.minimumSegmentHeight else { return 0 }
        return min(TabRailMetrics.preferredSegmentHeight, fitHeight)
    }
}
