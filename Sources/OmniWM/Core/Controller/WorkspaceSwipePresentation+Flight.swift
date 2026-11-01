// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

extension WorkspaceSwipePresentation {
    struct Workspace {
        let id: WorkspaceDescriptor.ID
        let items: [WorkspaceSwipePreview.Item]
    }

    struct Preparation {
        let monitor: Monitor
        let frame: CGRect
        let source: Workspace
        let previous: Workspace?
        let next: Workspace?
    }

    enum Phase {
        case tracking, settling, committing, waitingForPlacement
    }

    final class Flight {
        let preparation: Preparation
        let destination: Workspace
        let axis: WorkspaceSwipeAxis
        let inputSign: Double
        let visualSign: CGFloat
        let motion: WorkspaceSwipeMotion
        var progress = 0.0
        var phase = Phase.tracking
        var committing: Bool {
            phase == .committing || phase == .waitingForPlacement
        }

        var settlement: AXFrameSettlement?
        var handoff: Handoff?
        var carry: ((TimeInterval) -> CGVector?)?
        var carried = CGVector.zero
        var chained = false
        var serial = 0

        init(
            preparation: Preparation,
            destination: Workspace,
            axis: WorkspaceSwipeAxis,
            cumulative: Double,
            isNext: Bool,
            timestamp: TimeInterval,
            recognitionMovement: SwipeEvent?
        ) {
            self.preparation = preparation
            self.destination = destination
            self.axis = axis
            inputSign = cumulative < 0 ? -1 : 1
            visualSign = isNext ? 1 : -1
            motion = WorkspaceSwipeMotion(
                cumulativeUnits: abs(cumulative), timestamp: timestamp,
                recognitionMovement: recognitionMovement.map {
                    SwipeEvent(delta: $0.delta * (cumulative < 0 ? -1 : 1), timestamp: $0.timestamp)
                }
            )
        }

        var stride: CGFloat {
            (axis == .horizontal ? preparation.frame.width : preparation.frame.height) * 1.1
        }

        func offset(destination: Bool) -> CGVector {
            let own = vector((CGFloat(progress) - (destination ? 1 : 0)) * stride * visualSign)
            return CGVector(dx: own.dx + carried.dx, dy: own.dy + carried.dy)
        }

        func residual(at timestamp: TimeInterval) -> CGVector? {
            let inherited = carry?(timestamp)
            if inherited == nil { carry = nil }
            guard inherited != nil || !motion.isComplete(at: timestamp) else { return nil }
            let own = vector((CGFloat(motion.progress(at: timestamp)) - 1) * stride * visualSign)
            return CGVector(dx: own.dx + (inherited?.dx ?? 0), dy: own.dy + (inherited?.dy ?? 0))
        }

        private func vector(_ translation: CGFloat) -> CGVector {
            axis == .horizontal ? CGVector(dx: -translation, dy: 0) : CGVector(dx: 0, dy: translation)
        }
    }
}
