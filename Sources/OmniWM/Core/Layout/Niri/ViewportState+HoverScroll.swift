// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

enum NiriHoverScroll {
    static func scrollAmount(
        state: ViewportState,
        columnIndex: Int,
        columns: [NiriContainer],
        context: NiriInteractionContext,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool,
        scale: CGFloat,
        viewFrame: CGRect?
    ) -> CGFloat {
        guard columns.indices.contains(columnIndex) else { return 0 }

        var simulated = state
        let previousIndex = simulated.activeColumnIndex
        simulated.retargetColumn(
            to: columnIndex,
            columns: columns,
            gap: context.gaps,
            orientation: context.orientation
        )
        let offsetBefore = simulated.viewOffset
        let activePosition = simulated.containerPosition(
            at: simulated.activeColumnIndex,
            containers: columns,
            gap: context.gaps,
            sizeKeyPath: context.orientation.settledSpanKeyPath
        )
        let targetOffset = simulated.computeVisibleOffset(
            containerIndex: columnIndex,
            containers: columns,
            context: context,
            currentViewStart: activePosition + offsetBefore,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromContainerIndex: previousIndex,
            scale: scale,
            viewFrame: viewFrame
        )
        return abs(targetOffset - offsetBefore)
    }

    static func geometricScrollAmount(
        frame: CGRect,
        workingFrame: CGRect,
        orientation: Monitor.Orientation
    ) -> CGFloat {
        let (frameStart, frameEnd, workingStart, workingEnd) = switch orientation {
        case .horizontal:
            (frame.minX, frame.maxX, workingFrame.minX, workingFrame.maxX)
        case .vertical:
            (frame.minY, frame.maxY, workingFrame.minY, workingFrame.maxY)
        }
        return max(0, workingStart - frameStart, frameEnd - workingEnd)
    }

    static func allows(amount: CGFloat, percent: Int, extent: CGFloat, scale: CGFloat) -> Bool {
        let limit = CGFloat(percent) / 100 * extent
        let pixelTolerance = 1 / max(scale, 1)
        return amount <= limit + pixelTolerance
    }
}
