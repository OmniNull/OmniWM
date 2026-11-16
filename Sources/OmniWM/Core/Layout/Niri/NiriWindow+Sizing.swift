// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension NiriWindow {
    var heightWeight: CGFloat {
        switch height {
        case let .auto(weight): weight
        case .fixed,
             .preset: 1.0
        }
    }

    var widthWeight: CGFloat {
        switch windowWidth {
        case let .auto(weight): weight
        case .fixed,
             .preset: 1.0
        }
    }

    func secondarySizing(orientation: Monitor.Orientation) -> WeightedSize {
        orientation == .horizontal ? height : windowWidth
    }

    func setSecondarySizing(_ specification: WeightedSize, orientation: Monitor.Orientation) {
        if orientation == .horizontal { height = specification } else { windowWidth = specification }
    }

    func currentWidthForSizing() -> CGFloat {
        switch windowWidth {
        case let .fixed(width):
            width
        case .auto,
             .preset:
            resolvedWidth ?? frame?.width ?? max(1, widthWeight)
        }
    }

    func currentHeightForSizing() -> CGFloat {
        switch height {
        case let .fixed(height):
            height
        case .auto,
             .preset:
            resolvedHeight ?? frame?.height ?? max(1, heightWeight)
        }
    }

    static func normalizeWidthWeights(in windows: [NiriWindow]) {
        guard !windows.isEmpty else { return }

        let widths = windows.map { max(1, $0.resolvedWidth ?? $0.frame?.width ?? $0.widthWeight) }
        let median = max(1, widths.sorted()[widths.count / 2])

        for (window, width) in zip(windows, widths) where window.windowWidth.isAuto {
            window.windowWidth = .auto(weight: width / median)
        }
    }

    static func normalizeHeightWeights(in windows: [NiriWindow]) {
        guard !windows.isEmpty else { return }

        let heights = windows.map { max(1, $0.resolvedHeight ?? $0.frame?.height ?? $0.heightWeight) }
        let median = max(1, heights.sorted()[heights.count / 2])

        for (window, height) in zip(windows, heights) {
            window.height = .auto(weight: height / median)
        }
    }

    func nextSecondaryPresetIndex(
        forwards: Bool,
        presets: [PresetSize],
        availableSpan: CGFloat,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> Int {
        let presetCount = presets.count
        let nextIndex: Int
        let specification = switch orientation {
        case .horizontal: height
        case .vertical: windowWidth
        }
        switch specification {
        case let .preset(currentIndex) where sizingMode != .maximized:
            if forwards {
                nextIndex = (currentIndex + 1) % presetCount
            } else {
                nextIndex = (currentIndex - 1 + presetCount) % presetCount
            }
        default:
            let current = switch orientation {
            case .horizontal: currentHeightForSizing()
            case .vertical: currentWidthForSizing()
            }
            if forwards {
                nextIndex = presets.firstIndex { preset in
                    current + 1 < preset.secondarySpan(
                        availableSpan: availableSpan,
                        gaps: gaps
                    )
                } ?? 0
            } else {
                nextIndex = presets.lastIndex { preset in
                    preset.secondarySpan(
                        availableSpan: availableSpan,
                        gaps: gaps
                    ) + 1 < current
                } ?? (presetCount - 1)
            }
        }
        return nextIndex
    }

    func axisSolverInput(
        orientation: Monitor.Orientation,
        hasFixedValue: Bool,
        fixedValue: CGFloat?
    ) -> NiriAxisSolver.Input {
        switch orientation {
        case .horizontal:
            NiriAxisSolver.Input(
                weight: max(0.1, heightWeight),
                minConstraint: constraints.minSize.height,
                maxConstraint: constraints.maxSize.height,
                hasMaxConstraint: constraints.hasMaxHeight,
                isConstraintFixed: constraints.isFixed,
                hasFixedValue: hasFixedValue,
                fixedValue: fixedValue
            )
        case .vertical:
            NiriAxisSolver.Input(
                weight: max(0.1, widthWeight),
                minConstraint: constraints.minSize.width,
                maxConstraint: constraints.maxSize.width,
                hasMaxConstraint: constraints.hasMaxWidth,
                isConstraintFixed: constraints.isFixed,
                hasFixedValue: hasFixedValue,
                fixedValue: fixedValue
            )
        }
    }
}
