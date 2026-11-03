// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension LayoutRefreshController {
    enum HiddenRevealOperation {
        case none
        case positionPlan(WindowPositionPlan)
        case asyncFrame(CGRect)
    }

    func proportionalPosition(topLeft: CGPoint, in frame: CGRect) -> CGPoint {
        HiddenState.proportionalPosition(topLeft: topLeft, in: frame)
    }

    func preferredHideSides(for monitors: [Monitor]) -> [Monitor.ID: HideSide] {
        let important = 10
        var preferredSides: [Monitor.ID: HideSide] = [:]

        for monitor in monitors {
            let monitorFrame = monitor.frame
            let xOff = monitorFrame.width * 0.1
            let yOff = monitorFrame.height * 0.1

            let bottomRight = CGPoint(x: monitorFrame.maxX, y: monitorFrame.minY)
            let bottomLeft = CGPoint(x: monitorFrame.minX, y: monitorFrame.minY)

            let rightPoints = [
                CGPoint(x: bottomRight.x + 2, y: bottomRight.y - yOff),
                CGPoint(x: bottomRight.x - xOff, y: bottomRight.y + 2),
                CGPoint(x: bottomRight.x + 2, y: bottomRight.y + 2)
            ]

            let leftPoints = [
                CGPoint(x: bottomLeft.x - 2, y: bottomLeft.y - yOff),
                CGPoint(x: bottomLeft.x + xOff, y: bottomLeft.y + 2),
                CGPoint(x: bottomLeft.x - 2, y: bottomLeft.y + 2)
            ]

            func sideScore(_ points: [CGPoint]) -> Int {
                monitors.reduce(0) { partial, other in
                    let c1 = other.frame.contains(points[0]) ? 1 : 0
                    let c2 = other.frame.contains(points[1]) ? 1 : 0
                    let c3 = other.frame.contains(points[2]) ? 1 : 0
                    return partial + c1 + c2 + important * c3
                }
            }

            let leftScore = sideScore(leftPoints)
            let rightScore = sideScore(rightPoints)
            preferredSides[monitor.id] = leftScore < rightScore ? .left : .right
        }

        return preferredSides
    }

    func preferredHideSide(for monitor: Monitor) -> HideSide {
        guard let controller else { return .right }
        return preferredHideSides(for: controller.workspaceManager.monitors)[monitor.id] ?? .right
    }

    func restoreWindowFromHiddenState(
        _ entry: WindowState,
        monitor: Monitor,
        hiddenState: HiddenState
    ) -> HiddenRevealOperation {
        if entry.mode == .floating,
           hiddenState.restoresViaFloatingState,
           let controller,
           let frame = controller.workspaceManager.resolvedFloatingFrame(
               for: entry.token,
               preferredMonitor: monitor
           )
        {
            return .asyncFrame(frame)
        }

        if let plan = makeRestorePositionPlan(
            for: entry,
            monitor: monitor,
            hiddenState: hiddenState
        ) {
            return .positionPlan(plan)
        }

        return .none
    }

    func makeRestorePositionPlan(
        for entry: WindowState,
        monitor: Monitor,
        hiddenState: HiddenState
    ) -> WindowPositionPlan? {
        guard let controller else { return nil }
        guard let frame = fastFrame(for: entry.token, axRef: entry.axRef)
            ?? controller.axManager.lastAppliedFrame(for: entry.windowId)
            ?? entry.observedState.frame
            ?? entry.floatingState?.lastFrame
        else {
            return nil
        }

        let fallbackMonitor = hiddenState.referenceMonitorId
            .flatMap { controller.workspaceManager.monitor(byId: $0) }
        let restoreFrame: CGRect
        if monitor.frame.width > 1, monitor.frame.height > 1 {
            restoreFrame = monitor.frame
        } else {
            restoreFrame = fallbackMonitor?.frame ?? monitor.frame
        }

        let topLeft = topLeftPoint(from: hiddenState.proportionalPosition, in: restoreFrame)
        let restoredOrigin = clampedOrigin(forTopLeft: topLeft, windowSize: frame.size, in: restoreFrame)

        return WindowPositionPlan(
            entry: entry,
            frame: CGRect(origin: restoredOrigin, size: frame.size)
        )
    }

    private func topLeftPoint(from proportionalPosition: CGPoint, in frame: CGRect) -> CGPoint {
        let xRatio = min(max(proportionalPosition.x, 0), 1)
        let yRatio = min(max(proportionalPosition.y, 0), 1)
        return CGPoint(
            x: frame.minX + frame.width * xRatio,
            y: frame.maxY - frame.height * yRatio
        )
    }

    private func clampedOrigin(forTopLeft topLeft: CGPoint, windowSize: CGSize, in frame: CGRect) -> CGPoint {
        let minX = frame.minX
        let maxX = frame.maxX - windowSize.width
        let clampedX: CGFloat
        if maxX >= minX {
            clampedX = min(max(topLeft.x, minX), maxX)
        } else {
            clampedX = minX
        }

        let minTopLeftY = frame.minY + windowSize.height
        let maxTopLeftY = frame.maxY
        let clampedTopLeftY: CGFloat
        if maxTopLeftY >= minTopLeftY {
            clampedTopLeftY = min(max(topLeft.y, minTopLeftY), maxTopLeftY)
        } else {
            clampedTopLeftY = maxTopLeftY
        }

        return CGPoint(x: clampedX, y: clampedTopLeftY - windowSize.height)
    }
}
