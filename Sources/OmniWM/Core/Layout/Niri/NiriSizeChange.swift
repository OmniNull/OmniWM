// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum NiriSizeChange: Codable, Equatable, Hashable {
    case setFixed(CGFloat)
    case setProportion(CGFloat)
    case adjustFixed(CGFloat)
    case adjustProportion(CGFloat)

    static let maxPixels: CGFloat = 100_000
    static let maxProportion: CGFloat = 10_000

    init(_ preset: PresetSize) {
        switch preset.kind {
        case let .proportion(proportion):
            self = .setProportion(proportion * 100)
        case let .fixed(fixed):
            self = .setFixed(fixed)
        }
    }

    func primarySpanSpec(
        currentPixels: CGFloat,
        axisSpan: CGFloat,
        gaps: CGFloat
    ) -> ProportionalSize {
        switch self {
        case let .setFixed(fixed):
            return .fixed(fixed.clamped(to: 1 ... NiriSizeChange.maxPixels))
        case let .setProportion(proportion):
            return .proportion((proportion / 100).clamped(to: 0 ... NiriSizeChange.maxProportion))
        case let .adjustFixed(delta):
            return .fixed((currentPixels + delta).clamped(to: 1 ... NiriSizeChange.maxPixels))
        case let .adjustProportion(delta):
            let proportionalSpan = axisSpan - gaps
            let currentProportion = proportionalSpan == 0 ? 1 : (currentPixels + gaps) / proportionalSpan
            return .proportion((currentProportion + delta / 100).clamped(to: 0 ... NiriSizeChange.maxProportion))
        }
    }

    func secondaryPixels(
        currentPixels: CGFloat,
        availableSpan: CGFloat,
        gaps: CGFloat
    ) -> CGFloat {
        let proportionalSpan = availableSpan - gaps
        let currentProportion = proportionalSpan == 0 ? 1 : (currentPixels + gaps) / proportionalSpan
        switch self {
        case let .setFixed(fixed):
            return fixed
        case let .setProportion(proportion):
            return proportionalSpan * (proportion / 100) - gaps
        case let .adjustFixed(delta):
            return currentPixels + delta
        case let .adjustProportion(delta):
            return proportionalSpan * (currentProportion + delta / 100) - gaps
        }
    }
}

extension PresetSize {
    func secondarySpan(
        availableSpan: CGFloat,
        gaps: CGFloat
    ) -> CGFloat {
        switch kind {
        case let .proportion(proportion):
            (availableSpan - gaps) * proportion - gaps
        case let .fixed(fixed):
            fixed
        }
    }
}
