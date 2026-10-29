// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct NaturalEdgeResizeSlide {
    struct StackMate {
        let window: NiriWindow
        let frame: CGRect
    }

    let neighbourFrames: [WindowToken: CGRect]
    let stackMates: [StackMate]
    let wasAtTop: Bool
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

    func centredPrimaryResize(_ edges: ResizeEdge, from start: CGRect, to observed: CGRect) -> CentredPrimaryResize {
        guard edges == [.left, .right] else {
            return CentredPrimaryResize(edges: edges, observed: observed, centre: nil)
        }
        return CentredPrimaryResize(
            edges: .right,
            observed: CGRect(x: start.minX, y: observed.minY, width: observed.width, height: observed.height),
            centre: observed.midX
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
        from start: CGRect,
        to observed: CGRect
    ) -> CGFloat? {
        guard !edges.isEmpty, let engine = controller?.niriEngine else { return nil }
        let vertical = !edges.isDisjoint(with: [.top, .bottom])
        guard !vertical || engine.singleWindowLayoutContext(in: workspaceId) == nil else { return nil }
        guard edges == [.top, .bottom] else {
            guard !isColumnEndEdge(edges, of: window, in: workspaceId) else { return nil }
            return vertical ? observed.height : observed.width
        }
        guard let column = engine.findColumn(containing: window, in: workspaceId),
              !column.isTabbed
        else { return nil }
        switch engine.stackPlace(of: window, frame: start, in: column, workspaceId: workspaceId) {
        case .top: return start.height + start.minY - observed.minY
        case .bottom: return start.height + observed.maxY - start.maxY
        case .alone,
             .middle: return observed.height
        }
    }

    func neighboursGiveWay(
        to window: NiriWindow,
        from start: CGRect,
        to observed: CGRect,
        context: NiriInteractionContext
    ) -> Bool {
        guard let engine = controller?.niriEngine,
              let column = engine.findColumn(containing: window, in: context.workspaceId),
              !column.isTabbed,
              case let .fixed(height) = window.height
        else { return true }
        let others = engine.projectedWindows(in: column, workspaceId: context.workspaceId).filter { $0 !== window }
        let placed = others
            .compactMap { other in (other.renderedFrame ?? other.frame).map { (window: other, frame: $0) } }
        let above = placed.filter { $0.frame.minY >= start.maxY - FrameTolerance.screenMatch }
            .min { $0.frame.minY < $1.frame.minY }
        let below = placed.filter { $0.frame.maxY <= start.minY + FrameTolerance.screenMatch }
            .max { $0.frame.maxY < $1.frame.maxY }
        let (up, down) = heightChangeSides(
            height - start.height,
            from: start,
            to: observed,
            hasAbove: above != nil,
            hasBelow: below != nil
        )
        var heights = Dictionary(uniqueKeysWithValues: others
            .map { (ObjectIdentifier($0), $0.currentHeightForSizing()) })
        for (neighbour, change) in [(above, up), (below, down)] {
            guard let neighbour else { continue }
            let resized = neighbour.frame.height - change
            guard resized >= 1,
                  abs(neighbour.window.constraints.clampHeight(resized) - resized) <= FrameTolerance.screenMatch
            else { return false }
            heights[ObjectIdentifier(neighbour.window)] = resized
            if !neighbour.window.height.isAuto {
                neighbour.window.height = .fixed(resized)
            }
        }
        let flexible = others.filter(\.height.isAuto)
        let median = flexible.compactMap { heights[ObjectIdentifier($0)] }.sorted().dropFirst(flexible.count / 2).first
        for other in flexible {
            guard let median, let pixels = heights[ObjectIdentifier(other)] else { continue }
            other.height = .auto(weight: pixels / max(1, median))
        }
        return true
    }

    private func heightChangeSides(
        _ growth: CGFloat,
        from start: CGRect,
        to observed: CGRect,
        hasAbove: Bool,
        hasBelow: Bool
    ) -> (up: CGFloat, down: CGFloat) {
        let raisedTop = observed.maxY - start.maxY
        let loweredBottom = start.minY - observed.minY
        let moved = raisedTop + loweredBottom
        var up = abs(moved) > FrameTolerance.screenMatch ? growth * raisedTop / moved : 0
        if !hasBelow { up = growth }
        if !hasAbove { up = 0 }
        return (up, growth - up)
    }

    func naturalEdgeResizeSlide(
        around window: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID,
        resizedFrom start: CGRect,
        to observed: CGRect
    ) -> NaturalEdgeResizeSlide? {
        guard let controller,
              controller.settings.niri.naturalWindowDrag,
              let engine = controller.niriEngine,
              let column = engine.findColumn(containing: window, in: workspaceId)
        else { return nil }
        let stack = column.windowNodes
        return NaturalEdgeResizeSlide(
            neighbourFrames: engine.captureWindowFrames(in: workspaceId, excluding: Set(stack.map(\.token))),
            stackMates: stack.compactMap { mate in
                guard mate !== window, let frame = mate.renderedFrame ?? mate.frame else { return nil }
                return NaturalEdgeResizeSlide.StackMate(window: mate, frame: frame)
            },
            wasAtTop: window.restsAtTop(of: column),
            start: start,
            observed: observed
        )
    }

    func settleNaturalEdgeResize(
        _ window: NiriWindow,
        sliding slide: NaturalEdgeResizeSlide,
        monitor: Monitor,
        context: NiriInteractionContext
    ) {
        guard let controller, let engine = controller.niriEngine else { return }
        let workspaceId = context.workspaceId
        if !window.height.isAuto,
           let column = engine.findColumn(containing: window, in: workspaceId),
           engine.loneWindow(in: column, workspaceId: workspaceId, orientation: context.orientation) === window
        {
            window.rest(atTop: endAfterResize(slide, context: context), in: column)
        }
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
            let verticalOnly = CGRect(
                x: settled.minX,
                y: mate.frame.minY,
                width: settled.width,
                height: mate.frame.height
            )
            engine.animateLiveWindow(mate.window, from: verticalOnly, to: settled, context: context)
        }
        settleNiriResize(window.token, in: workspaceId)
        controller.niriLayoutHandler.startScrollAnimationIfNeeded(for: workspaceId, state: state, engine: engine)
    }

    private func endAfterResize(_ slide: NaturalEdgeResizeSlide, context: NiriInteractionContext) -> Bool {
        let room = context.workingFrame.height - 2 * context.gaps
        guard slide.observed.height < room - FrameTolerance.screenMatch else { return false }
        let vertical = Self.nativeResizeEdges(from: slide.start, to: slide.observed).intersection([.top, .bottom])
        if vertical.contains(.bottom) { return true }
        if vertical.contains(.top) { return false }
        return slide.wasAtTop
    }

    func isColumnEndEdge(
        _ edges: ResizeEdge,
        of window: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller,
              controller.settings.niri.naturalWindowDrag,
              let engine = controller.niriEngine,
              let column = engine.findColumn(containing: window, in: workspaceId),
              let frame = window.renderedFrame ?? window.frame
        else { return false }
        if column.isTabbed {
            return !edges.isDisjoint(with: [.top, .bottom])
        }
        switch engine.stackPlace(of: window, frame: frame, in: column, workspaceId: workspaceId) {
        case .alone: return isLoneWindowEndEdge(edges, of: window, frame: frame, in: column, workspaceId: workspaceId)
        case .top: return edges.contains(.top)
        case .bottom: return edges.contains(.bottom)
        case .middle: return false
        }
    }

    private func isLoneWindowEndEdge(
        _ edges: ResizeEdge,
        of window: NiriWindow,
        frame: CGRect,
        in column: NiriContainer,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let engine = controller?.niriEngine,
              let context = liveColumnContext(for: workspaceId),
              engine.loneWindow(in: column, workspaceId: workspaceId, orientation: context.orientation) === window,
              frame.height < context.workingFrame.height - 2 * context.gaps - FrameTolerance.screenMatch
        else { return false }
        return edges.contains(window.restsAtTop(of: column) ? .top : .bottom)
    }
}
