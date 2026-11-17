// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct FusionEdgeResizeSlide {
    struct StackMate {
        let window: NiriWindow
        let frame: CGRect
    }

    let neighbourFrames: [WindowToken: CGRect]
    let stackMates: [StackMate]
    let start: CGRect
    let observed: CGRect
}

struct CentredPrimaryResize {
    let edges: ResizeEdge
    let observed: CGRect
    let centre: CGFloat?
}

extension MouseEventHandler {
    static func isCentredResize(_ start: ClosedRange<CGFloat>, _ observed: ClosedRange<CGFloat>) -> Bool {
        let low = observed.lowerBound - start.lowerBound
        let high = observed.upperBound - start.upperBound
        return low * high < 0 && min(abs(low), abs(high)) > FrameTolerance.screenMatch
    }

    nonisolated static func completedNativeResizeLength(
        from start: CGFloat,
        observed: CGFloat,
        asked: CGFloat
    ) -> CGFloat {
        let done = observed - start
        let wanted = asked - start
        guard done * wanted > 0,
              abs(wanted) - abs(done) > AXRecentFrameWriteFailure.maxAcceptedSizeSnap
        else { return observed }
        return asked
    }

    nonisolated static func nativeResizeFrame(_ observed: CGRect, edges: ResizeEdge, size: CGSize) -> CGRect {
        func low(_ origin: CGFloat, growth: CGFloat, lowMoved: Bool, highMoved: Bool) -> CGFloat {
            switch (lowMoved, highMoved) {
            case (true, true): origin - growth / 2
            case (true, false): origin - growth
            case (false, _): origin
            }
        }
        return CGRect(
            x: low(
                observed.minX,
                growth: size.width - observed.width,
                lowMoved: edges.contains(.left),
                highMoved: edges.contains(.right)
            ),
            y: low(
                observed.minY,
                growth: size.height - observed.height,
                lowMoved: edges.contains(.bottom),
                highMoved: edges.contains(.top)
            ),
            width: size.width,
            height: size.height
        )
    }

    func completedNativeResize(
        of drag: MouseInputState.NativeTitleBarDrag,
        edges: ResizeEdge,
        from start: CGRect,
        observed: CGRect,
        entry: WindowState
    ) -> CGRect {
        guard let asked = nativeResizeTarget(of: drag, from: start, observed: observed, entry: entry) else {
            return observed
        }
        let size = CGSize(
            width: Self.completedNativeResizeLength(from: start.width, observed: observed.width, asked: asked.width),
            height: Self.completedNativeResizeLength(
                from: start.height,
                observed: observed.height,
                asked: asked.height
            )
        )
        guard size != observed.size else { return observed }
        MouseTrace.record(
            "title-bar drag completing token=\(TraceFormat.token(entry.token)) observed=\(TraceFormat.rect(observed)) "
                + "asked=\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
        )
        return Self.nativeResizeFrame(observed, edges: edges, size: size)
    }

    func centredPrimaryResize(
        _ edges: ResizeEdge, from start: CGRect, to observed: CGRect, orientation: Monitor.Orientation
    ) -> CentredPrimaryResize {
        let horizontal = orientation == .horizontal
        guard edges == (horizontal ? [.left, .right] : [.bottom, .top]) else {
            return CentredPrimaryResize(edges: edges, observed: observed, centre: nil)
        }
        return CentredPrimaryResize(
            edges: horizontal ? .right : .top,
            observed: CGRect(
                x: horizontal ? start.minX : observed.minX,
                y: horizontal ? observed.minY : start.minY,
                width: observed.width,
                height: observed.height
            ),
            centre: horizontal ? observed.midX : observed.midY
        )
    }

    func keepCentredResizeInPlace(
        _ window: NiriWindow,
        _ primary: CentredPrimaryResize,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        guard let centre = primary.centre,
              let engine = controller?.niriEngine,
              let column = engine.findColumn(containing: window, in: context.workspaceId)
        else { return }
        engine.centreColumn(column, on: centre, animated: false, context: context, state: &state)
    }

    func adoptedSecondarySpan(
        _ edges: ResizeEdge,
        of window: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID,
        frames: (start: CGRect, observed: CGRect),
        orientation: Monitor.Orientation
    ) -> CGFloat? {
        let (start, observed) = frames
        guard !edges.isEmpty, let engine = controller?.niriEngine else { return nil }
        let horizontal = orientation == .horizontal
        guard !horizontal || engine.singleWindowLayoutContext(in: workspaceId) == nil else { return nil }
        guard edges == (horizontal ? [.top, .bottom] : [.left, .right]) else {
            guard !isColumnEndEdge(edges, of: window, in: workspaceId, orientation: orientation) else { return nil }
            return horizontal ? observed.height : observed.width
        }
        guard let column = engine.findColumn(containing: window, in: workspaceId),
              !column.isTabbed
        else { return nil }
        switch engine.stackPlace(
            of: window,
            frame: start,
            in: column,
            workspaceId: workspaceId,
            orientation: orientation
        ) {
        case .top: return horizontal ? start.height + start.minY - observed.minY : start.width + start.minX - observed
            .minX
        case .bottom: return horizontal ? start.height + observed.maxY - start.maxY : start.width + observed
            .maxX - start.maxX
        case .alone,
             .middle: return horizontal ? observed.height : observed.width
        }
    }

    func neighboursGiveWay(
        to window: NiriWindow,
        from start: CGRect,
        to observed: CGRect,
        context: NiriInteractionContext
    ) -> Bool {
        let horizontal = context.orientation == .horizontal
        guard let engine = controller?.niriEngine,
              let column = engine.findColumn(containing: window, in: context.workspaceId),
              !column.isTabbed,
              case let .fixed(span) = horizontal ? window.height : window.windowWidth
        else { return true }
        let others = engine.projectedWindows(in: column, workspaceId: context.workspaceId).filter { $0 !== window }
        let (above, below) = secondaryNeighbours(among: others, from: start, horizontal: horizontal)
        let (up, down) = secondaryChangeSides(
            span - (horizontal ? start.height : start.width),
            frames: (start, observed),
            hasAbove: above != nil,
            hasBelow: below != nil,
            horizontal: horizontal
        )
        var spans = Dictionary(uniqueKeysWithValues: others
            .map { (ObjectIdentifier($0), horizontal ? $0.currentHeightForSizing() : $0.currentWidthForSizing()) })
        for (neighbour, change) in [(above, up), (below, down)] {
            guard let neighbour else { continue }
            let resized = (horizontal ? neighbour.frame.height : neighbour.frame.width) - change
            let clamped = horizontal ? neighbour.window.constraints.clampHeight(resized)
                : neighbour.window.constraints.clampWidth(resized)
            guard resized >= 1, abs(clamped - resized) <= FrameTolerance.screenMatch else { return false }
            spans[ObjectIdentifier(neighbour.window)] = resized
            if horizontal, !neighbour.window.height.isAuto {
                neighbour.window.height = .fixed(resized)
            } else if !horizontal, !neighbour.window.windowWidth.isAuto {
                neighbour.window.windowWidth = .fixed(resized)
            }
        }
        let flexible = others.filter { horizontal ? $0.height.isAuto : $0.windowWidth.isAuto }
        let median = flexible.compactMap { spans[ObjectIdentifier($0)] }.sorted().dropFirst(flexible.count / 2).first
        for other in flexible {
            guard let median, let pixels = spans[ObjectIdentifier(other)] else { continue }
            let specification = WeightedSize.auto(weight: pixels / max(1, median))
            if horizontal {
                other.height = specification
            } else {
                other.windowWidth = specification
            }
        }
        return true
    }

    private func secondaryNeighbours(
        among windows: [NiriWindow],
        from start: CGRect,
        horizontal: Bool
    ) -> (above: (window: NiriWindow, frame: CGRect)?, below: (window: NiriWindow, frame: CGRect)?) {
        var above: (window: NiriWindow, frame: CGRect)?
        var below: (window: NiriWindow, frame: CGRect)?
        let low = horizontal ? start.minY : start.minX
        let high = horizontal ? start.maxY : start.maxX
        var nearestAbove = CGFloat.infinity
        var nearestBelow = -CGFloat.infinity
        for window in windows {
            guard let frame = window.renderedFrame ?? window.frame else { continue }
            let near = horizontal ? frame.minY : frame.minX
            let far = horizontal ? frame.maxY : frame.maxX
            if near >= high - FrameTolerance.screenMatch,
               near < nearestAbove
            {
                above = (window, frame)
                nearestAbove = near
            }
            if far <= low + FrameTolerance.screenMatch,
               far > nearestBelow
            {
                below = (window, frame)
                nearestBelow = far
            }
        }
        return (above, below)
    }

    private func secondaryChangeSides(
        _ growth: CGFloat,
        frames: (start: CGRect, observed: CGRect),
        hasAbove: Bool,
        hasBelow: Bool,
        horizontal: Bool
    ) -> (up: CGFloat, down: CGFloat) {
        let raisedTop = horizontal ? frames.observed.maxY - frames.start.maxY : frames.observed.maxX - frames.start.maxX
        let loweredBottom = horizontal ? frames.start.minY - frames.observed.minY : frames.start.minX - frames.observed
            .minX
        let moved = raisedTop + loweredBottom
        var up = abs(moved) > FrameTolerance.screenMatch ? growth * raisedTop / moved : 0
        if !hasBelow { up = growth }
        if !hasAbove { up = 0 }
        return (up, growth - up)
    }

    func fusionEdgeResizeSlide(
        around window: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID,
        resizedFrom start: CGRect,
        to observed: CGRect,
        includeStackMates: Bool
    ) -> FusionEdgeResizeSlide? {
        guard let engine = controller?.niriEngine,
              let column = engine.findColumn(containing: window, in: workspaceId)
        else { return nil }
        let stack = column.windowNodes
        return FusionEdgeResizeSlide(
            neighbourFrames: engine.captureWindowFrames(in: workspaceId, excluding: Set(stack.map(\.token))),
            stackMates: includeStackMates ? stack.compactMap { mate in
                guard mate !== window, let frame = mate.renderedFrame ?? mate.frame else { return nil }
                return FusionEdgeResizeSlide.StackMate(window: mate, frame: frame)
            } : [],
            start: start,
            observed: observed
        )
    }

    func settleFusionEdgeResize(
        _ window: NiriWindow,
        sliding slide: FusionEdgeResizeSlide,
        monitor: Monitor,
        context: NiriInteractionContext
    ) {
        guard let controller, let engine = controller.niriEngine else { return }
        let workspaceId = context.workspaceId
        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        NiriOperationContext(
            controller: controller,
            engine: engine,
            motion: context.motion,
            wsId: workspaceId,
            windowNode: window,
            monitor: monitor,
            orientation: context.orientation,
            workingFrame: context.workingFrame,
            gaps: context.gaps
        ).preparePredictedAnimation(
            state: state,
            oldFrames: slide.neighbourFrames.merging([window.token: slide.observed]) { $1 }
        )
        for mate in slide.stackMates {
            guard let settled = mate.window.frame else { continue }
            let horizontal = context.orientation == .horizontal
            let secondaryOnly = CGRect(
                x: horizontal ? settled.minX : mate.frame.minX,
                y: horizontal ? mate.frame.minY : settled.minY,
                width: horizontal ? settled.width : mate.frame.width,
                height: horizontal ? mate.frame.height : settled.height
            )
            engine.animateLiveWindow(mate.window, from: secondaryOnly, to: settled, context: context)
        }
        settleNiriResize(window.token, in: workspaceId)
        controller.niriLayoutHandler.startScrollAnimationIfNeeded(for: workspaceId, state: state, engine: engine)
    }

    func isColumnEndEdge(
        _ edges: ResizeEdge,
        of window: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID,
        orientation: Monitor.Orientation
    ) -> Bool {
        guard let engine = controller?.niriEngine,
              let column = engine.findColumn(containing: window, in: workspaceId),
              let frame = window.renderedFrame ?? window.frame
        else { return false }
        let horizontal = orientation == .horizontal
        if column.isTabbed {
            return !edges.isDisjoint(with: horizontal ? [.top, .bottom] : [.left, .right])
        }
        switch engine.stackPlace(
            of: window,
            frame: frame,
            in: column,
            workspaceId: workspaceId,
            orientation: orientation
        ) {
        case .top: return edges.contains(horizontal ? .top : .right)
        case .bottom: return edges.contains(horizontal ? .bottom : .left)
        case .alone,
             .middle: return false
        }
    }
}
