// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct DwindleSettings {
    static let splitRatioPresets: [CGFloat] = [0.6, 1.0, 1.4]

    var defaultSplitRatio: CGFloat = 1.0
    var splitWidthMultiplier: CGFloat = 1.0
    var smartSplit: Bool = true
    var resizeStep: CGFloat = 0.1

    var singleWindowFit: SingleWindowFit = .fullScreen

    var innerGap: CGFloat = 8.0

    func clampedRatio(_ ratio: CGFloat) -> CGFloat {
        min(max(ratio, 0.1), 1.9)
    }

    func ratioToFraction(_ ratio: CGFloat) -> CGFloat {
        min(max(ratio / 2.0, 0), 1)
    }

    func resizeRatioRange(from ratio: CGFloat) -> ClosedRange<CGFloat> {
        let physicalRatio = 2 * ratioToFraction(ratio)
        return min(clampedRatio(-.infinity), physicalRatio) ... max(clampedRatio(.infinity), physicalRatio)
    }
}
