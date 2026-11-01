// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension LayoutRefreshController {
    func startWindowCloseAnimation(entry: WindowState, monitor: Monitor) {
        guard controller?.motionPolicy.animationsEnabled != false else { return }
        guard let controller, let axRef = entry.axRef else { return }
        guard !controller.workspaceManager.isWindowSuppressedByMacOS(entry.token) else { return }
        guard let frame = fastFrame(for: entry.token, axRef: entry.axRef) else { return }

        let displacement = CGPoint(x: 0, y: -12)
        let animation = SpringAnimation(
            from: 0,
            to: 1,
            startTime: CACurrentMediaTime(),
            config: controller.motionPolicy.snapshot().scaled(.balanced.with(epsilon: 0.01, velocityEpsilon: 0.1)),
            displayRefreshRate: layoutState.refreshRateByDisplay[monitor.displayId] ?? 60.0
        )

        var animations = layoutState.closingAnimationsByDisplay[monitor.displayId] ?? [:]
        guard animations[entry.windowId] == nil else { return }
        animations[entry.windowId] = LayoutRefreshState.ClosingAnimation(
            pid: entry.pid,
            windowId: entry.windowId,
            axRef: axRef,
            fromFrame: frame,
            displacement: displacement,
            animation: animation
        )
        _ = closingAnimationId(for: animation)
        layoutState.closingAnimationsByDisplay[monitor.displayId] = animations

        guard let displayLink = getOrCreateDisplayLink(for: monitor.displayId) else {
            rollbackClosingAnimationRegistration(windowId: entry.windowId, displayId: monitor.displayId)
            return
        }
        displayLink.add(to: .main, forMode: .common)
    }

    private func rollbackClosingAnimationRegistration(windowId: Int, displayId: CGDirectDisplayID) {
        var animations = layoutState.closingAnimationsByDisplay[displayId] ?? [:]
        if let animation = animations.removeValue(forKey: windowId) {
            forgetClosingAnimation(animation)
        }
        if animations.isEmpty {
            layoutState.closingAnimationsByDisplay.removeValue(forKey: displayId)
        } else {
            layoutState.closingAnimationsByDisplay[displayId] = animations
        }
    }

    private func closingAnimationId(for animation: SpringAnimation) -> UUID {
        let objectId = ObjectIdentifier(animation)
        if let animationId = closingAnimationIdsByObjectId[objectId] {
            return animationId
        }
        let animationId = UUID()
        closingAnimationIdsByObjectId[objectId] = animationId
        return animationId
    }

    func forgetClosingAnimation(_ animation: LayoutRefreshState.ClosingAnimation) {
        guard let animationId = closingAnimationIdsByObjectId.removeValue(
            forKey: ObjectIdentifier(animation.animation)
        ) else {
            return
        }
        lastSubmittedClosingFramesByAnimationId.removeValue(forKey: animationId)
    }

    func tickClosingAnimations(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard var animations = layoutState.closingAnimationsByDisplay.removeValue(forKey: displayId),
              !animations.isEmpty
        else {
            return
        }

        var completedWindowIds: [Int] = []
        completedWindowIds.reserveCapacity(animations.count)
        var targets: [AXClosingFrameTarget] = []
        targets.reserveCapacity(animations.count)

        for (windowId, animation) in animations {
            if controller?.workspaceManager.isWindowSuppressedByMacOS(WindowToken(
                pid: animation.pid,
                windowId: windowId
            )) == true {
                completedWindowIds.append(windowId)
                continue
            }
            let frame = animation.currentFrame(at: targetTime)
            let animationId = closingAnimationId(for: animation.animation)
            targets.append(
                AXClosingFrameTarget(
                    animationId: animationId,
                    pid: animation.pid,
                    expectedWindow: animation.axRef,
                    frame: frame,
                    currentFrameHint: lastSubmittedClosingFramesByAnimationId[animationId]
                        ?? animation.fromFrame
                )
            )
            lastSubmittedClosingFramesByAnimationId[animationId] = frame
            if animation.isComplete(at: targetTime) {
                completedWindowIds.append(windowId)
            }
        }

        controller?.axManager.applyClosingFrames(targets)

        for windowId in completedWindowIds {
            if let animation = animations.removeValue(forKey: windowId) {
                forgetClosingAnimation(animation)
            }
        }

        if animations.isEmpty {
            stopDisplayLinkIfIdle(for: displayId)
        } else {
            layoutState.closingAnimationsByDisplay[displayId] = animations
        }
    }
}
