// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct NiriTopRest {
    weak var column: NiriContainer?
    let heightRevision: Int
}

enum NiriStackPlace {
    case alone
    case top
    case middle
    case bottom
}

extension NiriWindow {
    func restsAtTop(of column: NiriContainer?) -> Bool {
        guard sizingMode == .normal, let rest = topRest, let column else { return false }
        return rest.column === column && rest.heightRevision == heightRevision
    }

    func restingOffset(in column: NiriContainer?, room: CGFloat) -> CGFloat {
        restsAtTop(of: column) ? max(0, room) : 0
    }

    func rest(atTop: Bool, in column: NiriContainer) {
        topRest = atTop ? NiriTopRest(column: column, heightRevision: heightRevision) : nil
    }
}

extension NiriContainerLayoutFrames {
    func restingStart(
        of windows: [NiriWindow],
        in column: NiriContainer,
        spans: [NiriAxisSolver.Output],
        gap: CGFloat
    ) -> CGFloat {
        let start = secondaryStart(gap: gap)
        guard windows.count == 1, orientation == .horizontal, let span = spans.first?.value else { return start }
        return start + windows[0].restingOffset(in: column, room: secondarySpan() - 2 * gap - span)
    }
}

extension NiriLayoutEngine {
    func loneWindow(
        in column: NiriContainer,
        workspaceId: WorkspaceDescriptor.ID,
        orientation: Monitor.Orientation
    ) -> NiriWindow? {
        let windows = projectedWindows(in: column, workspaceId: workspaceId)
        guard orientation == .horizontal,
              windows.count == 1,
              singleWindowLayoutContext(in: workspaceId) == nil
        else { return nil }
        return windows.first
    }

    func stackPlace(
        of window: NiriWindow,
        frame: CGRect,
        in column: NiriContainer,
        workspaceId: WorkspaceDescriptor.ID
    ) -> NiriStackPlace {
        let others = projectedWindows(in: column, workspaceId: workspaceId)
            .filter { $0 !== window }
            .compactMap { $0.renderedFrame ?? $0.frame }
        if others.isEmpty { return .alone }
        if others.allSatisfy({ $0.maxY < frame.maxY }) { return .top }
        if others.allSatisfy({ $0.minY > frame.minY }) { return .bottom }
        return .middle
    }

    func loneRestingOffset(
        of windows: [NiriWindow],
        in column: NiriContainer,
        spans: [NiriAxisSolver.Output],
        context: NiriInteractionContext
    ) -> CGFloat {
        guard windows.count == 1, let span = spans.first?.value else { return 0 }
        return windows[0].restingOffset(in: column, room: context.workingFrame.height - 2 * context.gaps - span)
    }

    func moveLoneWindowIntoItsSpace(
        _ column: NiriContainer,
        cursor: CGPoint,
        releasedFrame: CGRect,
        context: NiriInteractionContext,
        state: ViewportState
    ) {
        guard let window = loneWindow(in: column, workspaceId: context.workspaceId, orientation: context.orientation),
              !window.height.isAuto,
              let placed = liveColumnStrip(context: context, state: state).first(where: { $0.column === column }),
              (placed.minX ... placed.maxX).contains(cursor.x),
              let span = liveWindowSpans(in: column, context: context).first
        else { return }
        let top = context.workingFrame.maxY - context.gaps
        let bottom = context.workingFrame.minY + context.gaps
        let atTop = window.restsAtTop(of: column)
        let inSpace = atTop
            ? cursor.y >= bottom && cursor.y < span.minY
            : cursor.y > span.maxY && cursor.y <= top
        guard inSpace else { return }
        window.rest(atTop: !atTop, in: column)
        guard let moved = liveWindowSpans(in: column, context: context).first else { return }
        window.animateMoveFrom(
            displacement: CGPoint(x: 0, y: releasedFrame.minY - moved.minY),
            clock: animationClock,
            config: context.motion.scaled(windowMovementAnimationConfig),
            displayRefreshRate: displayRefreshRate(in: context.workspaceId),
            animated: context.motion.animationsEnabled
        )
    }
}
