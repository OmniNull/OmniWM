// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

enum WorkspaceBarScratchpadLayout {
    struct WidthBudget {
        let availableWidth: CGFloat
        let baseWidth: CGFloat
    }

    static let compactLabelMaximumWidth: CGFloat = 20
    private static let itemWidthSafetyMargin: CGFloat = 1

    static func compactedItems(
        _ items: [WorkspaceBarScratchpadItem],
        widthBudget: WidthBudget,
        barHeight: CGFloat,
        icons: Int,
        hasAdjacentContent: Bool
    ) -> [WorkspaceBarScratchpadItem] {
        let expanded = items.map { $0.presented(as: .expanded) }
        let requiredWidth = widthBudget.baseWidth
            + (hasAdjacentContent && !expanded.isEmpty ? 8 : 0)
            + estimatedWidth(of: expanded, barHeight: barHeight, icons: icons)
        guard requiredWidth > widthBudget.availableWidth else { return expanded }
        let compacted = expanded.map { item in
            item.presented(as: item.isRevealed ? .expanded : .compact)
        }
        let compactedRequiredWidth = widthBudget.baseWidth
            + (hasAdjacentContent && !compacted.isEmpty ? 8 : 0)
            + estimatedWidth(of: compacted, barHeight: barHeight, icons: icons)
        guard compactedRequiredWidth > widthBudget.availableWidth else { return compacted }
        return compacted.map { $0.presented(as: .compact) }
    }

    static func estimatedWidth(
        of items: [WorkspaceBarScratchpadItem],
        barHeight: CGFloat,
        icons: Int
    ) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        let scale = barHeight / 32
        return items.reduce(0) { width, item in
            width + estimatedWidth(of: item, scale: scale, icons: icons)
        } + CGFloat(items.count - 1) * 8
    }

    private static func estimatedWidth(
        of item: WorkspaceBarScratchpadItem,
        scale: CGFloat,
        icons: Int
    ) -> CGFloat {
        let iconSize = 18 * scale
        let font = NSFont.systemFont(ofSize: 13 * scale, weight: .medium)
        let labelWidth = (item.name as NSString).size(withAttributes: [.font: font]).width
        switch item.presentation {
        case .expanded:
            let iconCount = min(icons, item.windows.count)
            let overflowCount = max(0, item.windows.count - iconCount)
            var widths = [max(14, iconSize), labelWidth]
            widths.append(contentsOf: repeatElement(iconSize, count: iconCount))
            if overflowCount > 0 {
                widths.append(badgeWidth(for: "+\(overflowCount)", iconSize: iconSize))
            }
            return 16
                + widths.reduce(0, +)
                + CGFloat(max(0, widths.count - 1)) * 5
                + itemWidthSafetyMargin
        case .compact:
            return 10
                + min(labelWidth, compactLabelMaximumWidth)
                + 3
                + badgeWidth(for: "\(item.windowCount)", iconSize: iconSize)
                + itemWidthSafetyMargin
        }
    }

    private static func badgeWidth(for text: String, iconSize: CGFloat) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        return max(
            max(12, iconSize * 0.55),
            (text as NSString).size(withAttributes: [.font: font]).width + 6
        )
    }
}
