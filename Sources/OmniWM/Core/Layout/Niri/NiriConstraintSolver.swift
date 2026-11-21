// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum NiriAxisSolver {
    @usableFromInline
    static let minimumRenderableSpan: CGFloat = 1

    struct Input: Hashable {
        let weight: CGFloat
        let minConstraint: CGFloat
        let maxConstraint: CGFloat
        let hasMaxConstraint: Bool
        let isConstraintFixed: Bool
        let hasFixedValue: Bool
        let fixedValue: CGFloat?
    }

    struct Output {
        let value: CGFloat
        let wasConstrained: Bool
    }
}

struct NiriAxisSolveKey: Equatable {
    let containerRevision: UInt64
    let configurationRevision: UInt64
    let availableSpace: CGFloat
    let gap: CGFloat
    let isTabbed: Bool
    let isVertical: Bool
}

extension NiriAxisSolver {
    @inlinable
    static func solve(
        windows: [Input],
        availableSpace: CGFloat,
        gapSize: CGFloat,
        isTabbed: Bool = false
    ) -> [Output] {
        guard !windows.isEmpty else { return [] }

        if isTabbed {
            let usableSpace = max(0, availableSpace - gapSize * 2)
            return solveTabbed(windows: windows, availableSpace: usableSpace)
        }

        let totalGaps = gapSize * CGFloat(windows.count + 1)
        let usableSpace = max(0, availableSpace - totalGaps)
        let epsilon: CGFloat = 0.001
        let minConstraints = windows.map { sanitizedMinimum($0.minConstraint) }

        let floors = minConstraints.map { max(Self.minimumRenderableSpan, $0) }
        let floorSum = floors.reduce(0, +)
        if floorSum > usableSpace + epsilon {
            let scale = usableSpace / floorSum
            return floors.map { floor in
                Output(value: max(Self.minimumRenderableSpan, floor * scale), wasConstrained: true)
            }
        }

        let maxConstraints = windows.map { window in
            sanitizedMaximum(window.hasMaxConstraint ? window.maxConstraint : nil)
        }
        let weights = windows.map { sanitizedNonNegative($0.weight) }

        var fixedAllocation = FixedAllocation(
            windows: windows,
            minimums: minConstraints,
            maximums: maxConstraints
        )
        let remainingSpace = fixedAllocation.fit(availableSpace: usableSpace, floors: floors)
        var values = fixedAllocation.values.map { $0 ?? 0 }
        var weightedAllocation = WeightedAllocation(
            indices: fixedAllocation.nonFixedIndices,
            weights: weights,
            minimums: minConstraints
        )
        if maxConstraints.contains(where: { $0 != nil }) {
            weightedAllocation.distributeCapped(
                remainingSpace: remainingSpace, maximums: maxConstraints, values: &values
            )
        } else {
            weightedAllocation.distribute(remainingSpace: remainingSpace, values: &values)
        }

        return windows.enumerated().map { index, window in
            let isAtMinimum = minConstraints[index] > epsilon &&
                abs(values[index] - minConstraints[index]) <= epsilon
            let isAtMaximum = maxConstraints[index].map { abs(values[index] - $0) <= epsilon } ?? false
            return Output(
                value: max(Self.minimumRenderableSpan, values[index]),
                wasConstrained: window.isConstraintFixed || fixedAllocation
                    .wasScaled[index] || isAtMinimum || isAtMaximum
            )
        }
    }

    @inlinable
    static func solveTabbed(
        windows: [Input],
        availableSpace: CGFloat
    ) -> [Output] {
        let maxMinConstraint = windows.map(\.minConstraint).max() ?? 1
        let fixedValue = windows.first(where: { $0.hasFixedValue && $0.fixedValue != nil })?.fixedValue

        var sharedValue: CGFloat = if let fixed = fixedValue {
            max(fixed, maxMinConstraint)
        } else {
            max(availableSpace, maxMinConstraint)
        }

        let maxMaxConstraint = windows.compactMap {
            sanitizedMaximum($0.hasMaxConstraint ? $0.maxConstraint : nil)
        }
        .min()
        if let maxC = maxMaxConstraint {
            sharedValue = min(sharedValue, max(maxC, maxMinConstraint))
        }

        sharedValue = max(Self.minimumRenderableSpan, sharedValue)

        return windows.map { window in
            let wasConstrained = sharedValue == window.minConstraint ||
                (window.hasMaxConstraint && sharedValue == window.maxConstraint)
            return Output(value: sharedValue, wasConstrained: wasConstrained)
        }
    }

    @inlinable
    static func sanitizedNonNegative(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    @inlinable
    static func sanitizedMinimum(_ value: CGFloat) -> CGFloat {
        sanitizedNonNegative(value)
    }

    @inlinable
    static func sanitizedMaximum(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return max(0, value)
    }

    @inlinable
    static func clampedFixedValue(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat?
    ) -> CGFloat {
        var clamped = sanitizedNonNegative(value)
        clamped = max(clamped, minimum)
        if let maximum {
            clamped = min(clamped, maximum)
        }
        return clamped
    }
}

extension NiriAxisSolver {
    struct FixedAllocation {
        private(set) var values: [CGFloat?]
        private(set) var wasScaled: [Bool]
        let nonFixedIndices: [Int]

        init(windows: [Input], minimums: [CGFloat], maximums: [CGFloat?]) {
            let values: [CGFloat?] = windows.enumerated().map { index, window in
                if window.hasFixedValue, let fixedValue = window.fixedValue {
                    return clampedFixedValue(fixedValue, minimum: minimums[index], maximum: maximums[index])
                }
                if window.isConstraintFixed {
                    return clampedFixedValue(minimums[index], minimum: minimums[index], maximum: maximums[index])
                }
                return nil
            }
            self.values = values
            wasScaled = [Bool](repeating: false, count: windows.count)
            nonFixedIndices = windows.indices.filter { values[$0] == nil }
        }

        mutating func fit(availableSpace: CGFloat, floors: [CGFloat]) -> CGFloat {
            let epsilon: CGFloat = 0.001
            var fixedSum = values.compactMap(\.self).reduce(0, +)
            let fixedBudget = max(
                0,
                availableSpace - nonFixedIndices.reduce(CGFloat.zero) { $0 + floors[$1] }
            )
            if fixedSum > fixedBudget, fixedSum > epsilon {
                let fixedFloorSum = values.indices.reduce(CGFloat.zero) { partialResult, index in
                    values[index] == nil ? partialResult : partialResult + floors[index]
                }
                let allowedSurplus = max(0, fixedBudget - fixedFloorSum)
                let surplus = fixedSum - fixedFloorSum
                let surplusScale = surplus > epsilon ? allowedSurplus / surplus : 0
                for index in values.indices {
                    guard let fixedValue = values[index] else { continue }
                    let scaledValue = floors[index] + max(0, fixedValue - floors[index]) * surplusScale
                    wasScaled[index] = abs(scaledValue - fixedValue) > epsilon
                    values[index] = scaledValue
                }
                fixedSum = values.compactMap(\.self).reduce(0, +)
            }
            return max(0, availableSpace - fixedSum)
        }
    }

    struct WeightedCandidate {
        let index: Int
        let weight: CGFloat
        let minimum: CGFloat
    }

    struct WeightedAllocation {
        private var candidates: [WeightedCandidate]
        private var pendingWeight: CGFloat = 0

        init(indices: [Int], weights: [CGFloat], minimums: [CGFloat]) {
            let epsilon: CGFloat = 0.001
            var candidates: [WeightedCandidate] = []
            candidates.reserveCapacity(indices.count)
            for index in indices {
                let weight = max(weights[index], epsilon)
                candidates.append(WeightedCandidate(index: index, weight: weight, minimum: minimums[index]))
                pendingWeight += weight
            }
            candidates.sort { lhs, rhs in
                let lhsThreshold = lhs.minimum / lhs.weight
                let rhsThreshold = rhs.minimum / rhs.weight
                if abs(lhsThreshold - rhsThreshold) > epsilon {
                    return lhsThreshold > rhsThreshold
                }
                return lhs.index < rhs.index
            }
            self.candidates = candidates
        }

        mutating func distributeCapped(
            remainingSpace: CGFloat,
            maximums: borrowing [CGFloat?],
            values: inout [CGFloat]
        ) {
            var remaining = remainingSpace
            while !candidates.isEmpty {
                distribute(remainingSpace: remaining, values: &values)
                var capped = false
                for index in candidates.indices.reversed() {
                    let candidate = candidates[index]
                    guard let maximum = maximums[candidate.index], values[candidate.index] > maximum else { continue }
                    values[candidate.index] = maximum
                    remaining -= maximum
                    candidates.remove(at: index)
                    capped = true
                }
                guard capped else { return }
                pendingWeight = candidates.reduce(0) { $0 + $1.weight }
            }
        }

        mutating func distribute(remainingSpace: CGFloat, values: inout [CGFloat]) {
            let epsilon: CGFloat = 0.001
            var pinnedMinimumSum: CGFloat = 0
            var firstUnpinnedIndex = 0
            while firstUnpinnedIndex < candidates.count, pendingWeight > epsilon {
                let distributableSpace = max(0, remainingSpace - pinnedMinimumSum)
                let candidate = candidates[firstUnpinnedIndex]
                let share = distributableSpace * (candidate.weight / pendingWeight)
                guard share + epsilon < candidate.minimum else {
                    break
                }

                values[candidate.index] = candidate.minimum
                pinnedMinimumSum += candidate.minimum
                pendingWeight -= candidate.weight
                firstUnpinnedIndex += 1
            }

            if firstUnpinnedIndex < candidates.count, pendingWeight > epsilon {
                let distributableSpace = max(0, remainingSpace - pinnedMinimumSum)
                for candidate in candidates[firstUnpinnedIndex...] {
                    values[candidate.index] = distributableSpace * (candidate.weight / pendingWeight)
                }
            }
        }
    }
}
