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

extension MouseEventHandler {
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
        if let column = loneColumn(of: window, in: workspaceId, context: context) {
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
        ).preparePredictedAnimation(state: state, oldFrames: slide.neighbourFrames)
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

    private func loneColumn(
        of window: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID,
        context: NiriInteractionContext
    ) -> NiriContainer? {
        guard context.orientation == .horizontal,
              !window.height.isAuto,
              let engine = controller?.niriEngine,
              engine.singleWindowLayoutContext(in: workspaceId) == nil,
              let column = engine.findColumn(containing: window, in: workspaceId),
              engine.projectedWindows(in: column, workspaceId: workspaceId).count == 1
        else { return nil }
        return column
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
              !column.isTabbed,
              let frame = window.renderedFrame ?? window.frame
        else { return false }
        let stack = engine.projectedWindows(in: column, workspaceId: workspaceId)
        if stack.count == 1 {
            return isLoneWindowEndEdge(edges, of: window, frame: frame, in: column, workspaceId: workspaceId)
        }
        let others = stack.filter { $0 !== window }.compactMap { $0.renderedFrame ?? $0.frame }
        if edges.contains(.top) {
            return others.allSatisfy { $0.maxY < frame.maxY }
        }
        if edges.contains(.bottom) {
            return others.allSatisfy { $0.minY > frame.minY }
        }
        return false
    }

    private func isLoneWindowEndEdge(
        _ edges: ResizeEdge,
        of window: NiriWindow,
        frame: CGRect,
        in column: NiriContainer,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let engine = controller?.niriEngine,
              engine.singleWindowLayoutContext(in: workspaceId) == nil,
              let context = liveColumnContext(for: workspaceId),
              context.orientation == .horizontal,
              frame.height < context.workingFrame.height - 2 * context.gaps - FrameTolerance.screenMatch
        else { return false }
        return edges.contains(window.restsAtTop(of: column) ? .top : .bottom)
    }
}
