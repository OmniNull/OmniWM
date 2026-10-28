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
}

extension MouseEventHandler {
    func naturalEdgeResizeSlide(
        around window: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID
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
            }
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
}
