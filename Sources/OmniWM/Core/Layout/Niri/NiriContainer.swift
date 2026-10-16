// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

class NiriContainer: NiriNode {
    var displayMode: ColumnDisplay = .normal

    private(set) var activeTileIdx: Int = 0

    var width: ProportionalSize = .default

    var cachedWidth: CGFloat = 0

    var presetWidthIdx: Int?

    var isFullWidth: Bool = false

    var savedWidth: ProportionalSize?

    var hasManualSingleWindowWidthOverride: Bool = false

    var height: ProportionalSize = .default

    var cachedHeight: CGFloat = 0

    var isFullHeight: Bool = false

    var savedHeight: ProportionalSize?

    var hasManualSingleWindowHeightOverride: Bool = false

    var moveAnimation: MoveAnimation?
    private var moveAnimationOrientation: Monitor.Orientation?

    var widthAnimation: SpringAnimation?
    var targetWidth: CGFloat?
    var fittedWidth: CGFloat?
    var fittedHeight: CGFloat?

    var settledWidth: CGFloat {
        targetWidth ?? cachedWidth
    }

    private var _cachedWindowNodes: [NiriWindow]?

    private(set) var axisSolveRevision: UInt64 = 0

    override init() {
        super.init()
    }

    override func invalidateChildrenCache() {
        axisSolveRevision &+= 1
        _cachedWindowNodes = nil
        super.invalidateChildrenCache()
    }

    override func invalidateAxisSolveInputs() {
        axisSolveRevision &+= 1
    }

    func resolvedPrimarySpan(
        _ spec: ProportionalSize,
        orientation: Monitor.Orientation,
        availableSpace: CGFloat,
        gaps: CGFloat,
        contentInset: CGFloat = 0,
        applyingPackingHints: Bool = true
    ) -> CGFloat {
        let bounds = orientation == .horizontal ? widthBounds(contentInset: contentInset) : heightBounds()
        var result: CGFloat = switch spec {
        case let .proportion(proportion):
            (availableSpace - gaps) * proportion - gaps
        case let .fixed(size):
            size
        }
        let effectiveMaxConstraint = bounds.max.map { max($0, bounds.min) }
        if result < bounds.min { result = bounds.min }
        if applyingPackingHints {
            result = packedPrimarySpan(
                result,
                orientation: orientation,
                limit: availableSpace - gaps * 2,
                contentInset: contentInset
            )
        }
        if let effectiveMaxConstraint, result > effectiveMaxConstraint { result = effectiveMaxConstraint }
        return result
    }

    func packedPrimarySpan(
        _ span: CGFloat,
        orientation: Monitor.Orientation,
        limit: CGFloat,
        contentInset: CGFloat = 0
    ) -> CGFloat {
        Self.packedPrimarySpan(
            span,
            windows: windowNodes,
            orientation: orientation,
            limit: limit,
            contentInset: contentInset
        )
    }

    static func packedPrimarySpan(
        _ span: CGFloat,
        windows: [NiriWindow],
        orientation: Monitor.Orientation,
        limit: CGFloat,
        contentInset: CGFloat
    ) -> CGFloat {
        windows.reduce(span) { packed, window in
            guard let hint = window.packingHints.primary(for: orientation) else { return packed }
            return max(packed, hint.packed(span - contentInset, limit: limit - contentInset) + contentInset)
        }
    }

    func invalidateCachedPrimarySpans() {
        if targetWidth == nil {
            cachedWidth = 0
        }
        cachedHeight = 0
    }

    func widthBounds(contentInset: CGFloat = 0) -> (min: CGFloat, max: CGFloat?) {
        var minWidth: CGFloat = 1
        var maxWidth: CGFloat?

        for window in windowNodes {
            let constraints = window.constraints.normalized()
            minWidth = max(minWidth, constraints.minSize.width)
            if constraints.hasMaxWidth {
                let candidateMax = constraints.maxSize.width
                maxWidth = min(maxWidth ?? candidateMax, candidateMax)
            }
        }

        return (
            minWidth + contentInset,
            maxWidth.map { max($0, minWidth) + contentInset }
        )
    }

    func heightBounds() -> (min: CGFloat, max: CGFloat?) {
        var minHeight: CGFloat = 1
        var maxHeight: CGFloat?

        for window in windowNodes {
            let constraints = window.constraints.normalized()
            minHeight = max(minHeight, constraints.minSize.height)
            if constraints.hasMaxHeight {
                let candidateMax = constraints.maxSize.height
                maxHeight = min(maxHeight ?? candidateMax, candidateMax)
            }
        }

        return (minHeight, maxHeight.map { max($0, minHeight) })
    }

    func clampedToWidthBounds(_ width: CGFloat, contentInset: CGFloat = 0) -> CGFloat {
        let bounds = widthBounds(contentInset: contentInset)
        let clamped = max(width, bounds.min)
        guard let maxWidth = bounds.max else { return clamped }
        return min(clamped, maxWidth)
    }

    func clampedToHeightBounds(_ height: CGFloat) -> CGFloat {
        let bounds = heightBounds()
        let clamped = max(height, bounds.min)
        guard let maxHeight = bounds.max else { return clamped }
        return min(clamped, maxHeight)
    }

    func resolveAndCacheWidth(
        workingAreaWidth: CGFloat,
        gaps: CGFloat,
        contentInset: CGFloat = 0
    ) {
        cachedWidth = resolvedWidthPixels(
            isFullWidth ? .proportion(1) : width,
            availableSpan: workingAreaWidth,
            gaps: gaps,
            contentInset: contentInset
        )
    }

    func resolveAndCacheHeight(workingAreaHeight: CGFloat, gaps: CGFloat) {
        cachedHeight = resolvedHeightPixels(
            isFullHeight ? .proportion(1) : height,
            availableSpan: workingAreaHeight,
            gaps: gaps
        )
    }

    func invalidateCachedPrimarySpan(orientation: Monitor.Orientation) {
        switch orientation {
        case .horizontal:
            cachedWidth = 0
            widthAnimation = nil
            targetWidth = nil
        case .vertical:
            cachedHeight = 0
        }
    }

    override var size: CGFloat {
        get { width.value }
        set {
            width = .proportion(newValue)
        }
    }

    var windowNodes: [NiriWindow] {
        if let cached = _cachedWindowNodes { return cached }
        let result = children.compactMap { $0 as? NiriWindow }
        _cachedWindowNodes = result
        return result
    }

    var isTabbed: Bool {
        displayMode == .tabbed
    }

    var activeWindow: NiriWindow? {
        let windows = windowNodes
        guard !windows.isEmpty else { return nil }
        let idx = activeTileIdx.clamped(to: 0 ... (windows.count - 1))
        return windows[idx]
    }

    func clampActiveTileIdx() {
        let count = windowNodes.count
        if count == 0 {
            activeTileIdx = 0
        } else {
            activeTileIdx = activeTileIdx.clamped(to: 0 ... (count - 1))
        }
    }

    func setActiveTileIdx(_ idx: Int) {
        let count = windowNodes.count
        if count == 0 {
            activeTileIdx = 0
        } else {
            activeTileIdx = idx.clamped(to: 0 ... (count - 1))
        }
    }

    func adjustActiveTileIdxForRemoval(of node: NiriNode) {
        let windows = windowNodes
        guard let idx = windows.firstIndex(where: { $0 === node }) else { return }
        if idx == activeTileIdx {
            if windows.count > 1, idx >= windows.count - 1 {
                activeTileIdx = max(0, idx - 1)
            }
        } else if idx < activeTileIdx {
            activeTileIdx = max(0, activeTileIdx - 1)
        }
    }
}

extension NiriContainer {
    func animateMoveFrom(
        displacement: CGPoint,
        clock: AnimationClock?,
        config: SpringConfig = .default,
        displayRefreshRate: Double = 60.0,
        animated: Bool
    ) {
        guard animated else {
            moveAnimation = nil
            moveAnimationOrientation = nil
            return
        }

        let orientation: Monitor.Orientation
        let displacementValue: CGFloat
        if displacement.x != 0 {
            orientation = .horizontal
            displacementValue = displacement.x
        } else if displacement.y != 0 {
            orientation = .vertical
            displacementValue = displacement.y
        } else {
            moveAnimation = nil
            moveAnimationOrientation = nil
            return
        }

        let now = clock?.now() ?? CACurrentMediaTime()
        let currentOffset = renderOffset(at: now)
        let currentValue = switch orientation {
        case .horizontal: currentOffset.x
        case .vertical: currentOffset.y
        }
        let currentVelocity = moveAnimationOrientation == orientation
            ? moveAnimation?.currentVelocity(at: now) ?? 0
            : 0
        let animation = SpringAnimation(
            from: 1,
            to: 0,
            initialVelocity: currentVelocity,
            startTime: now,
            config: config,
            displayRefreshRate: displayRefreshRate
        )
        moveAnimation = MoveAnimation(
            animation: animation,
            fromOffset: displacementValue + currentValue
        )
        moveAnimationOrientation = orientation
    }

    func renderOffset(at time: TimeInterval = CACurrentMediaTime()) -> CGPoint {
        guard let animation = moveAnimation,
              let orientation = moveAnimationOrientation
        else {
            return .zero
        }
        let value = animation.currentOffset(at: time)
        return switch orientation {
        case .horizontal: CGPoint(x: value, y: 0)
        case .vertical: CGPoint(x: 0, y: value)
        }
    }

    func tickMoveAnimation(at time: TimeInterval) -> Bool {
        guard let anim = moveAnimation else { return false }
        if anim.isComplete(at: time) {
            moveAnimation = nil
            moveAnimationOrientation = nil
            return false
        }
        return true
    }

    var hasMoveAnimationRunning: Bool {
        moveAnimation != nil
    }

    @discardableResult
    func offsetMoveAnimCurrent(
        _ offset: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        guard let anim = moveAnimation,
              moveAnimationOrientation == orientation
        else {
            return false
        }
        let now = CACurrentMediaTime()
        let value = anim.animation.value(at: now)
        if value > 0.001 {
            moveAnimation = MoveAnimation(
                animation: anim.animation,
                fromOffset: anim.fromOffset + offset / CGFloat(value)
            )
        }
        return true
    }

    @discardableResult
    func animateWidthTo(
        newWidth: CGFloat,
        clock: AnimationClock?,
        config: SpringConfig,
        displayRefreshRate: Double = 60.0,
        animated: Bool
    ) -> Bool {
        guard animated else {
            cachedWidth = newWidth
            widthAnimation = nil
            targetWidth = nil
            return false
        }

        let now = clock?.now() ?? CACurrentMediaTime()
        let currentWidth = cachedWidth > 0 ? cachedWidth : newWidth
        let currentVel = widthAnimation?.velocity(at: now) ?? 0

        widthAnimation = SpringAnimation(
            from: Double(currentWidth),
            to: Double(newWidth),
            initialVelocity: currentVel,
            startTime: now,
            config: config,
            displayRefreshRate: displayRefreshRate
        )
        targetWidth = newWidth
        return true
    }

    func tickWidthAnimation(at time: TimeInterval) -> Bool {
        guard let anim = widthAnimation else { return false }

        let lowerEndpoint = min(CGFloat(anim.from), targetWidth ?? CGFloat(anim.from))
        cachedWidth = max(CGFloat(anim.value(at: time)), lowerEndpoint)

        if anim.isComplete(at: time) {
            if let target = targetWidth {
                cachedWidth = target
            }
            widthAnimation = nil
            targetWidth = nil
            return false
        }
        return true
    }

    var hasWidthAnimationRunning: Bool {
        widthAnimation != nil
    }

    func stopAnimations() {
        moveAnimation = nil
        moveAnimationOrientation = nil
        if let targetWidth {
            cachedWidth = targetWidth
        }
        widthAnimation = nil
        targetWidth = nil
    }
}
