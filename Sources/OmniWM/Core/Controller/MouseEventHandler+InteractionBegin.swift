// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func beginNiriMove(
        window tiledWindow: NiriWindow,
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        at location: CGPoint,
        isInsertMode: Bool = false,
        source: MouseInputState.InteractionSource
    ) -> Bool {
        guard let controller, let monitor = controller.workspaceManager.monitor(for: wsId) else { return false }
        let geometry = controller.niriInteractionGeometry(for: monitor)
        let orientation = resolvedNiriOrientation(
            engine: engine,
            workspaceId: wsId,
            monitor: monitor
        )

        var moveStarted = false
        controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
            if engine.interactiveMoveBegin(
                windowId: tiledWindow.id,
                windowToken: tiledWindow.token,
                startLocation: location,
                isInsertMode: isInsertMode,
                context: .init(
                    workspaceId: wsId,
                    motion: controller.motionPolicy.snapshot(),
                    workingFrame: geometry.workingFrame,
                    gaps: geometry.innerGap,
                    orientation: orientation
                ),
                state: &vstate
            ) {
                moveStarted = true
            }
        }
        guard moveStarted else { return false }

        state.isMoving = true
        state.moveLayout = .niri
        state.activeInteractionSource = source
        state.capturedInteractionButton = source.mouseButton
        NSCursor.closedHand.set()

        if let entry = controller.workspaceManager.entry(for: tiledWindow.token),
           let frame = AXWindowService.framePreferFast(entry.axRef)
        {
            if state.dragGhostController == nil {
                state.dragGhostController = DragGhostController()
            }
            state.dragGhostController?.beginDrag(
                token: entry.token,
                originalFrame: frame,
                cursorLocation: location
            )
        }
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
        state.capturedInteractionButton = source.mouseButton
        state.currentHoveredEdges = edges
        edges.cursor.set()
        return true
    }

    func beginDwindleMove(
        token: WindowToken,
        engine: DwindleLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        at location: CGPoint,
        source: MouseInputState.InteractionSource
    ) -> Bool {
        guard let controller else { return false }
        let now = controller.animationClock.now()
        guard let frame = engine.presentedFrame(for: token, in: wsId, at: now),
              engine.interactiveMoveBegin(token: token, startLocation: location, in: wsId)
        else { return false }

        state.isMoving = true
        state.moveLayout = .dwindle
        state.activeInteractionSource = source
        state.capturedInteractionButton = source.mouseButton
        NSCursor.closedHand.set()
        if state.dragGhostController == nil {
            state.dragGhostController = DragGhostController()
        }
        state.dragGhostController?.beginDrag(token: token, originalFrame: frame, cursorLocation: location)
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
        state.capturedInteractionButton = source.mouseButton
        state.currentHoveredEdges = edges
        state.resizeLayout = .dwindle
        edges.cursor.set()
        return true
    }
}
