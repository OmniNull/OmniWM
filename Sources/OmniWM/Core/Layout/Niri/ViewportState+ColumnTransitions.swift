// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension ViewportState {
    mutating func transitionToColumn(
        _ newIndex: Int,
        columns: [NiriContainer],
        context: NiriInteractionContext,
        animate: Bool,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false,
        fromColumnIndex: Int? = nil,
        scale: CGFloat = 2.0,
        viewFrame: CGRect? = nil
    ) {
        preservesGestureOffset = false
        guard !columns.isEmpty else { return }
        let clampedIndex = newIndex.clamped(to: 0 ... (columns.count - 1))

        let oldActivePosition = containerPosition(
            at: activeColumnIndex,
            containers: columns,
            gap: context.gaps,
            sizeKeyPath: context.orientation.renderedSpanKeyPath
        )

        let prevActiveColumn = activeColumnIndex
        activeColumnIndex = clampedIndex

        let newActivePosition = containerPosition(
            at: clampedIndex,
            containers: columns,
            gap: context.gaps,
            sizeKeyPath: context.orientation.renderedSpanKeyPath
        )
        let offsetDelta = oldActivePosition - newActivePosition

        rebaseOffset(by: offsetDelta)

        let settledActivePosition = containerPosition(
            at: clampedIndex,
            containers: columns,
            gap: context.gaps,
            sizeKeyPath: context.orientation.settledSpanKeyPath
        )
        let targetOffset = computeVisibleOffset(
            containerIndex: clampedIndex,
            containers: columns,
            context: context,
            currentViewStart: settledActivePosition + viewOffset,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromContainerIndex: fromColumnIndex ?? prevActiveColumn,
            scale: scale,
            viewFrame: viewFrame
        )

        let pixel: CGFloat = 1.0 / max(scale, 1.0)
        let toDiff = targetOffset - viewOffset
        if abs(toDiff) < pixel {
            rebaseOffset(by: toDiff)
            activatePrevColumnOnRemoval = nil
            viewOffsetToRestore = nil
            return
        }

        if animate {
            animateToOffset(targetOffset, motion: context.motion)
        } else {
            jumpOffset(to: targetOffset)
        }

        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
    }

    mutating func ensureContainerVisible(
        containerIndex: Int,
        containers: [NiriContainer],
        context: NiriInteractionContext,
        animate: Bool = true,
        centerMode: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil,
        scale: CGFloat = 2.0,
        viewFrame: CGRect? = nil
    ) {
        preservesGestureOffset = false
        guard !containers.isEmpty, containerIndex >= 0, containerIndex < containers.count else { return }

        let sizeKeyPath = context.orientation.settledSpanKeyPath
        let stationaryOffset = viewOffset
        let activePos = containerPosition(
            at: activeColumnIndex,
            containers: containers,
            gap: context.gaps,
            sizeKeyPath: sizeKeyPath
        )
        let stationaryViewStart = activePos + stationaryOffset
        let pixelEpsilon: CGFloat = 1.0 / max(scale, 1.0)

        let targetOffset = computeVisibleOffset(
            containerIndex: containerIndex,
            containers: containers,
            context: context,
            currentViewStart: stationaryViewStart,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromContainerIndex: fromContainerIndex,
            scale: scale,
            viewFrame: viewFrame
        )

        if abs(targetOffset - stationaryOffset) <= pixelEpsilon {
            return
        }

        if animate {
            animateToOffset(
                targetOffset,
                motion: context.motion,
                config: animationConfig,
                scale: scale
            )
        } else {
            jumpOffset(to: targetOffset)
        }
    }
}

extension ViewportState {
    mutating func retargetColumn(
        to targetIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        orientation: Monitor.Orientation,
        previousPosition: CGFloat? = nil
    ) {
        let oldActivePosition = previousPosition
            ?? containerPosition(
                at: activeColumnIndex,
                containers: columns,
                gap: gap,
                sizeKeyPath: orientation.renderedSpanKeyPath
            )
        let newActivePosition = containerPosition(
            at: targetIndex,
            containers: columns,
            gap: gap,
            sizeKeyPath: orientation.renderedSpanKeyPath
        )
        rebaseOffset(by: oldActivePosition - newActivePosition)
        activeColumnIndex = targetIndex
        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
    }
}
