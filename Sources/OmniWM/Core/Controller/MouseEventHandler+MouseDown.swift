// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func handleMouseDownFromTap(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton,
        windowIdUnderPointer: Int?,
        windowServerFramesAtMouseDown: [WindowToken: CGRect]?
    ) -> Bool {
        guard let controller else { return false }
        guard canHandleManagedMouseInteraction(controller: controller) else { return false }

        if shouldBlockOwnWindowInput(at: location) {
            return false
        }
        guard !state.isMoving, !state.isResizing else { return false }

        guard let wsId = workspaceIdForPointer(at: location) ?? controller.activeWorkspace()?.id else {
            return false
        }

        let startsFusionDrag = button == .left && macOSFusionTakesModifiers(modifiers, in: wsId)
        if button == .left, startsFusionDrag || modifiers.isDisjoint(with: Self.relevantModifierFlags) {
            finishNiriSlideBeforePress(in: wsId)
            recordPointerFocusIntent(
                at: location,
                workspaceId: wsId,
                windowIdUnderPointer: windowIdUnderPointer,
                windowServerFramesAtMouseDown: windowServerFramesAtMouseDown
            )
        }

        let layoutType = controller.workspaceManager.descriptor(for: wsId)
            .map { controller.settings.workspaces.layoutType(for: $0.name) }
        if layoutType == .dwindle {
            return handleDwindleMouseDown(at: location, modifiers: modifiers, button: button, wsId: wsId)
        }

        guard let engine = controller.niriEngine else { return false }

        if button == .left,
           !startsFusionDrag,
           Self.mouseMoveModifiersMatch(
               modifiers,
               required: controller.settings.gestures.mouseMoveModifierKey.cgEventFlags
           ),
           !leavesCentredResizeToMacOS(at: location, modifiers: modifiers, engine: engine, workspaceId: wsId)
        {
            beginNiriMouseMove(at: location, engine: engine, workspaceId: wsId, button: button)
            return false
        }

        guard button == .right,
              Self.modifierFlagsMatch(
                  modifiers,
                  required: controller.settings.gestures.mouseResizeModifierKey.cgEventFlag
              )
        else { return false }

        return beginNiriMouseResize(at: location, engine: engine, workspaceId: wsId, button: button)
    }

    private func finishNiriSlideBeforePress(in workspaceId: WorkspaceDescriptor.ID) {
        guard let controller,
              controller.settings.niri.macOSFusion,
              controller.workspaceManager.activeLayoutKind(for: workspaceId) == .niri,
              let engine = controller.niriEngine,
              !engine.isLiveColumnMoveActive(in: workspaceId),
              !engine.isLiveStackDropPending(in: workspaceId),
              hasPendingNiriAnimationWork(
                  state: controller.workspaceManager.niriViewportState(for: workspaceId),
                  driver: controller.workspaceManager.animationDriver,
                  engine: engine,
                  workspaceId: workspaceId
              )
        else { return }
        controller.niriLayoutHandler.cancelAnimationMotion(for: workspaceId)
        refreshLiveColumnLayout(in: workspaceId, engine: engine)
        MouseTrace.record("press finished the running slide ws=\(workspaceId)")
    }

    func macOSFusionTakesModifiers(_ modifiers: CGEventFlags, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller,
              controller.settings.niri.macOSFusion,
              controller.workspaceManager.activeLayoutKind(for: workspaceId) == .niri
        else { return false }
        return Self.mouseMoveModifiersMatch(
            modifiers,
            required: controller.settings.niri.macOSFusionModifier.cgEventFlags
        )
    }

    private func leavesCentredResizeToMacOS(
        at location: CGPoint,
        modifiers: CGEventFlags,
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard controller?.settings.niri.macOSFusion == true,
              modifiers.contains(.maskAlternate),
              let window = engine.hitTestTiled(point: location, in: workspaceId),
              !window.constraints.isFixed,
              let frame = window.renderedFrame ?? window.frame
        else { return false }
        return Self.isOnResizeEdge(location, of: frame)
    }

    static func isOnResizeEdge(_ location: CGPoint, of frame: CGRect) -> Bool {
        let threshold = ResizeConfiguration.default.edgeThreshold
        return frame.contains(location) && !frame.insetBy(dx: threshold, dy: threshold).contains(location)
    }

    private func beginNiriMouseMove(
        at location: CGPoint, engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID, button: MouseButton
    ) {
        guard let window = engine.hitTestTiled(point: location, in: workspaceId) else { return }
        _ = beginNiriMove(window: window, engine: engine, wsId: workspaceId, at: location, source: .mouse(button))
    }

    private func beginNiriMouseResize(
        at location: CGPoint, engine: NiriLayoutEngine, workspaceId wsId: WorkspaceDescriptor.ID, button: MouseButton
    ) -> Bool {
        guard let controller else { return false }
        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return false }
        let window = engine.hitTestTiled(point: location, in: wsId)
            ?? focusedBorderResizeToken(
                at: location,
                in: wsId,
                scale: controller.backingScaleFactor(for: monitor),
                appliedBorder: controller.surfaceReconciler.appliedScene.border
            )
            .flatMap { engine.findNode(for: $0, in: wsId) }
        guard let window else { return false }
        return beginNiriResize(window: window, engine: engine, wsId: wsId, at: location, source: .mouse(button))
    }

    private func recordPointerFocusIntent(
        at location: CGPoint,
        workspaceId wsId: WorkspaceDescriptor.ID,
        windowIdUnderPointer: Int?,
        windowServerFramesAtMouseDown: [WindowToken: CGRect]?
    ) {
        guard let controller else { return }
        state.awaitsNativeTitleBarDragTarget = windowIdUnderPointer == nil
        state.nativeTitleBarDragFallbackReleased = false
        let exactToken = nativeTitleBarDragCandidate(windowIdUnderPointer: windowIdUnderPointer)
        let focusIntentToken = exactToken ?? (windowIdUnderPointer == nil
            ? geometricFocusIntentCandidate(at: location, workspaceId: wsId)
            : nil)
        captureNativeCrossDisplayMove(for: focusIntentToken)
        captureNativeResizeStart(
            for: focusIntentToken,
            at: location,
            windowServerFramesAtMouseDown: windowServerFramesAtMouseDown
        )
        if let token = focusIntentToken {
            controller.axEventHandler.noteMouseFocusIntent(token: token)
        } else {
            controller.axEventHandler.noteUnmanagedPointerClick()
        }
        state.nativeTitleBarDragFallbackToken = exactToken == nil ? focusIntentToken : nil
        state.liveDragTracedDecline = nil
        MouseTrace.record(
            "title-bar press windowUnderPointer=\(windowIdUnderPointer.map(String.init) ?? "nil") "
                + "exact=\(TraceFormat.token(exactToken)) fallback=\(TraceFormat.token(focusIntentToken))"
        )
        if let exactToken {
            state.awaitsNativeTitleBarDragTarget = false
            let token = exactToken
            state.nativeTitleBarDrag = .init(token: token)
        }
    }

    private func handleDwindleMouseDown(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton,
        wsId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller, let engine = controller.dwindleEngine else { return false }
        if button == .left {
            guard Self.mouseMoveModifiersMatch(
                      modifiers,
                      required: controller.settings.gestures.mouseMoveModifierKey.cgEventFlags
                  ),
                  let token = engine.hitTestFocusableWindow(
                      point: location,
                      in: wsId,
                      at: controller.animationClock.now()
                  )
            else { return false }
            _ = beginDwindleMove(
                token: token, engine: engine, wsId: wsId, at: location,
                source: .mouse(button)
            )
            return false
        }
        guard button == .right,
              Self.modifierFlagsMatch(
                  modifiers,
                  required: controller.settings.gestures.mouseResizeModifierKey.cgEventFlag
              )
        else { return false }

        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return false }
        let token = engine.hitTestFocusableWindow(point: location, in: wsId, at: controller.animationClock.now())
            ?? focusedBorderResizeToken(
                at: location,
                in: wsId,
                scale: controller.backingScaleFactor(for: monitor),
                appliedBorder: controller.surfaceReconciler.appliedScene.border
            )
        guard let token else { return false }
        return beginDwindleResize(token: token, engine: engine, wsId: wsId, at: location, source: .mouse(button))
    }

    func focusedBorderResizeToken(
        at location: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        scale: CGFloat,
        appliedBorder: DesiredBorderSurface?
    ) -> WindowToken? {
        guard let controller,
              let appliedBorder,
              appliedBorder.token == controller.workspaceManager.borderFocusToken,
              let entry = controller.workspaceManager.entry(for: appliedBorder.token),
              entry.workspaceId == workspaceId,
              entry.mode == .tiling
        else {
            return nil
        }
        let geometry = appliedBorder.config.resolvedGeometry(for: appliedBorder.frame, scale: scale)
        guard geometry.width > 0,
              geometry.targetFrame.insetBy(dx: -geometry.width, dy: -geometry.width).contains(location),
              !geometry.targetFrame.contains(location)
        else {
            return nil
        }
        return appliedBorder.token
    }

    func resizeEdges(for location: CGPoint, in frame: CGRect) -> ResizeEdge {
        var edges: ResizeEdge = location.x < frame.midX ? [.left] : [.right]
        edges.insert(location.y < frame.midY ? .bottom : .top)
        return edges
    }

    func shouldAcceptInteractionButton(_ button: MouseButton) -> Bool {
        state.activeInteractionSource == nil || state.activeInteractionSource == .mouse(button)
    }

    func isCapturedInteraction(_ button: MouseButton) -> Bool {
        state.capturedInteractionButton == button
    }
}
