// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    func feasibleRatioRange(
        for split: DwindleNode,
        innerGap: CGFloat,
        excludedTokens: Set<WindowToken>,
        bounds: ClosedRange<CGFloat>
    ) -> ClosedRange<CGFloat>? {
        guard case let .split(orientation, _) = split.kind,
              let rect = split.cachedFrame,
              let first = split.firstChild(),
              let second = split.secondChild()
        else {
            return bounds
        }

        let boundaryEdges = tilingBoundaryEdges(of: split, excluding: excludedTokens)
        let childEdges = splitChildBoundaryEdges(boundaryEdges, orientation: orientation)
        let firstMinSize = computeProjectedMinSizeForSubtree(
            first,
            boundaryEdges: childEdges.first,
            excludedTokens: excludedTokens,
            innerGap: innerGap
        )
        let secondMinSize = computeProjectedMinSizeForSubtree(
            second,
            boundaryEdges: childEdges.second,
            excludedTokens: excludedTokens,
            innerGap: innerGap
        )

        let firstMin: CGFloat
        let secondMin: CGFloat
        let axisLength: CGFloat
        switch orientation {
        case .horizontal:
            firstMin = firstMinSize.width
            secondMin = secondMinSize.width
            axisLength = rect.width
        case .vertical:
            firstMin = firstMinSize.height
            secondMin = secondMinSize.height
            axisLength = rect.height
        }

        guard axisLength > 0 else { return bounds }
        guard firstMin + secondMin <= axisLength else { return nil }

        let lower = max(bounds.lowerBound, 2 * firstMin / axisLength)
        let upper = min(bounds.upperBound, 2 * (axisLength - secondMin) / axisLength)
        guard lower <= upper else {
            let limit = 2 * firstMin / axisLength > bounds.upperBound ? bounds.upperBound : bounds.lowerBound
            return limit ... limit
        }
        return lower ... upper
    }

    func clampedRatioRespectingMinimums(
        _ ratio: CGFloat,
        for split: DwindleNode,
        innerGap: CGFloat,
        excludedTokens: Set<WindowToken> = [],
        referenceRatio: CGFloat? = nil
    ) -> CGFloat {
        guard let range = feasibleRatioRange(
            for: split,
            innerGap: innerGap,
            excludedTokens: excludedTokens,
            bounds: settings.resizeRatioRange(from: referenceRatio ?? split.splitRatio ?? settings.defaultSplitRatio)
        ) else {
            return split.splitRatio ?? settings.clampedRatio(ratio)
        }
        return min(max(ratio, range.lowerBound), range.upperBound)
    }

    func splitRect(
        _ rect: CGRect,
        orientation: DwindleOrientation,
        ratio: CGFloat,
        minimums: (first: CGSize, second: CGSize)
    ) -> (CGRect, CGRect) {
        splitRect(
            rect,
            orientation: orientation,
            ratio: ratio,
            minimums: (first: minimums.first, second: minimums.second),
            settings: settings
        )
    }

    func splitRect(
        _ rect: CGRect,
        orientation: DwindleOrientation,
        ratio: CGFloat,
        minimums: (first: CGSize, second: CGSize),
        settings: DwindleSettings
    ) -> (CGRect, CGRect) {
        var fraction = settings.ratioToFraction(ratio)

        switch orientation {
        case .horizontal:
            let totalMin = minimums.first.width + minimums.second.width
            if totalMin > rect.width {
                fraction = minimums.first.width / max(totalMin, 1)
            } else {
                let minFraction = minimums.first.width / rect.width
                let maxFraction = (rect.width - minimums.second.width) / rect.width
                fraction = max(minFraction, min(maxFraction, fraction))
            }

            let firstW = rect.width * fraction
            let secondW = rect.width - firstW
            let r1 = CGRect(x: rect.minX, y: rect.minY, width: firstW, height: rect.height)
            let r2 = CGRect(x: rect.minX + firstW, y: rect.minY, width: secondW, height: rect.height)
            return (r1, r2)

        case .vertical:
            let totalMin = minimums.first.height + minimums.second.height
            if totalMin > rect.height {
                fraction = minimums.first.height / max(totalMin, 1)
            } else {
                let minFraction = minimums.first.height / rect.height
                let maxFraction = (rect.height - minimums.second.height) / rect.height
                fraction = max(minFraction, min(maxFraction, fraction))
            }

            let firstH = rect.height * fraction
            let secondH = rect.height - firstH
            let r1 = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstH)
            let r2 = CGRect(x: rect.minX, y: rect.minY + firstH, width: rect.width, height: secondH)
            return (r1, r2)
        }
    }

    func singleWindowRect(
        screen: CGRect,
        borderSafeFillScreen: CGRect,
        minSize: CGSize,
        settings: DwindleSettings
    ) -> CGRect {
        let baseFrame = settings.singleWindowFit.usesFullscreenLayoutFrame ? borderSafeFillScreen : screen
        let fit = settings.singleWindowFit.frame(in: baseFrame)
        var rect = fit
        rect.size.width = min(max(fit.width, minSize.width), baseFrame.width)
        rect.size.height = min(max(fit.height, minSize.height), baseFrame.height)
        rect.origin.x = min(max(baseFrame.minX, fit.midX - rect.width / 2), baseFrame.maxX - rect.width)
        rect.origin.y = min(max(baseFrame.minY, fit.midY - rect.height / 2), baseFrame.maxY - rect.height)
        return rect
    }
}
