// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func beginNiriGestureMove(
        window: NiriWindow, engine: NiriLayoutEngine, wsId: WorkspaceDescriptor.ID, at location: CGPoint
    ) -> Bool {
        guard let controller, liveDragSession == nil, let context = liveColumnContext(for: wsId)
        else { return false }
        finishPendingLiveStackDrop()
        guard let frame = window.renderedFrame ?? window.frame else { return false }
        let start = controller.niriLayoutHandler.layoutChangeStart(in: wsId)
        let began = controller.workspaceManager.withNiriViewportState(
            for: wsId, committingIf: { $0 },
            { viewport in
                engine.liveColumnMoveBegin(
                    windowId: window.id, windowToken: window.token, canCarry: true, context: context, state: &viewport
                )
            }
        )
        guard began else { return false }

        state.isMoving = true
        state.moveLayout = .niri
        state.activeInteractionSource = .trackpadGesture
        startCarryingNiriWindow(
            .init(token: window.token, anchorLocation: location, startFrame: frame), in: context, layoutStart: start,
            referenceOffset: context.primaryStart(of: frame) + context.primarySpan(of: frame) / 2
                - context.primaryCoordinate(of: location)
        )
        engine.liveColumnMove?.floatingFrame = frame
        livePointer.location = location
        recordLivePointerSample(location)
        NSCursor.closedHand.set()
        return true
    }

    func beginNiriResize(
        window tiledWindow: NiriWindow,
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        at location: CGPoint,
        source: MouseInputState.InteractionSource
    ) -> Bool {
        guard let controller,
              let monitor = controller.workspaceManager.monitor(for: wsId),
              let frame = tiledWindow.renderedFrame ?? tiledWindow.frame,
              engine.interactiveResizeTarget(windowId: tiledWindow.id, in: wsId) != nil
        else { return false }

        let edges = resizeEdges(for: location, in: frame)
        let orientation = resolvedNiriOrientation(
            engine: engine,
            workspaceId: wsId,
            monitor: monitor
        )
        controller.niriLayoutHandler.cancelActiveAnimations(for: wsId)
        let currentViewOffset = controller.workspaceManager.niriViewportState(for: wsId).viewOffset
        guard engine.interactiveResizeBegin(
            windowId: tiledWindow.id,
            edges: edges,
            startLocation: location,
            in: wsId,
            orientation: orientation,
            viewOffset: currentViewOffset
        ) else { return false }

        state.isResizing = true
        state.resizeLayout = .niri
        state.activeInteractionSource = source
        tapInputs.capturedInteractionButton = source.mouseButton
        state.currentHoveredEdges = edges
        edges.cursor.set()

        return true
    }

    func beginDwindleGestureMove(
        token: WindowToken, engine: DwindleLayoutEngine, wsId: WorkspaceDescriptor.ID, at location: CGPoint
    ) -> Bool {
        guard let controller,
              let frame = engine.presentedFrame(for: token, in: wsId, at: controller.animationClock.now())
        else { return false }
        finishPendingLiveStackDrop()
        let began = controller.workspaceManager.withEngineMutationScope(in: wsId, source: .mouse) {
            engine.liveMoveBegin(token: token, startLocation: location, startFrame: frame, in: wsId)
        }
        guard began else { return false }

        state.isMoving = true
        state.moveLayout = .dwindle
        state.activeInteractionSource = .trackpadGesture
        NSCursor.closedHand.set()
        return true
    }

    func beginDwindleResize(
        token: WindowToken,
        engine: DwindleLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        at location: CGPoint,
        edgePolicy: DwindleResizeEdgePolicy = .exact,
        source: MouseInputState.InteractionSource
    ) -> Bool {
        guard let controller,
              let monitor = controller.workspaceManager.monitor(for: wsId),
              let node = engine.findNode(for: token, in: wsId),
              let frame = node.presentedFrame(at: controller.animationClock.now())
        else { return false }

        controller.dwindleLayoutHandler.refreshEngineConstraints(workspaceId: wsId, monitor: monitor)
        let innerGap = controller.resolvedDwindleSettings(for: monitor).innerGap
        guard engine.interactiveResizeBegin(
                  token: token,
                  edges: resizeEdges(for: location, in: frame),
                  startLocation: location,
                  in: wsId,
                  innerGap: innerGap,
                  edgePolicy: edgePolicy
              ),
              let edges = engine.interactiveResize?.edges
        else {
            return false
        }

        controller.layoutRefreshController.stopDwindleAnimation(for: monitor.displayId)
        engine.cancelAnimations(in: wsId)
        state.isResizing = true
        state.activeInteractionSource = source
        tapInputs.capturedInteractionButton = source.mouseButton
        state.currentHoveredEdges = edges
        state.resizeLayout = .dwindle
        edges.cursor.set()

        return true
    }
}
