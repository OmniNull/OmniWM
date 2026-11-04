// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension NiriContainer {
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

        widthAnimation = Self.spanSpring(
            (from: cachedWidth, to: newWidth),
            continuing: widthAnimation,
            clock: clock,
            config: config,
            displayRefreshRate: displayRefreshRate
        )
        targetWidth = newWidth
        return true
    }

    func tickWidthAnimation(at time: TimeInterval) -> Bool {
        guard let anim = widthAnimation else { return false }

        let sample = Self.spanSample(anim, target: targetWidth, at: time)
        cachedWidth = sample.span
        guard sample.isComplete else { return true }
        widthAnimation = nil
        targetWidth = nil
        return false
    }

    var hasWidthAnimationRunning: Bool {
        widthAnimation != nil
    }

    @discardableResult
    func animateHeightTo(
        newHeight: CGFloat,
        clock: AnimationClock?,
        config: SpringConfig,
        displayRefreshRate: Double = 60.0,
        animated: Bool
    ) -> Bool {
        guard animated else {
            cachedHeight = newHeight
            heightAnimation = nil
            targetHeight = nil
            return false
        }

        heightAnimation = Self.spanSpring(
            (from: cachedHeight, to: newHeight),
            continuing: heightAnimation,
            clock: clock,
            config: config,
            displayRefreshRate: displayRefreshRate
        )
        targetHeight = newHeight
        return true
    }

    func tickHeightAnimation(at time: TimeInterval) -> Bool {
        guard let anim = heightAnimation else { return false }

        let sample = Self.spanSample(anim, target: targetHeight, at: time)
        cachedHeight = sample.span
        guard sample.isComplete else { return true }
        heightAnimation = nil
        targetHeight = nil
        return false
    }

    var hasHeightAnimationRunning: Bool {
        heightAnimation != nil
    }

    private static func spanSpring(
        _ span: (from: CGFloat, to: CGFloat),
        continuing running: SpringAnimation?,
        clock: AnimationClock?,
        config: SpringConfig,
        displayRefreshRate: Double
    ) -> SpringAnimation {
        let now = clock?.now() ?? CACurrentMediaTime()
        return SpringAnimation(
            from: Double(span.from > 0 ? span.from : span.to),
            to: Double(span.to),
            initialVelocity: running?.velocity(at: now) ?? 0,
            startTime: now,
            config: config,
            displayRefreshRate: displayRefreshRate
        )
    }

    private static func spanSample(
        _ animation: SpringAnimation,
        target: CGFloat?,
        at time: TimeInterval
    ) -> (span: CGFloat, isComplete: Bool) {
        let lowerEndpoint = min(CGFloat(animation.from), target ?? CGFloat(animation.from))
        let span = max(CGFloat(animation.value(at: time)), lowerEndpoint)
        guard animation.isComplete(at: time) else { return (span, false) }
        return (target ?? span, true)
    }
}
