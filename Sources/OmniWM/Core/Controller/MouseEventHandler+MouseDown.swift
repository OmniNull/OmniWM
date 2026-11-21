// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    enum FusionDoubleClickLookup {
        case pending
        case done(FusionDoubleClickCandidate?)
        case dwindle(DwindlePressHit?)
    }

    struct PressedStrip {
        let workspaceId: WorkspaceDescriptor.ID
        let layoutKind: ActiveLayoutKind
        let hasEdgePeeks: Bool
        var doubleClick = FusionDoubleClickLookup.pending
    }

    func pressedStrip(at location: CGPoint) -> PressedStrip? {
        guard let controller,
              let workspaceId = workspaceIdForPointer(at: location) ?? controller.activeWorkspace()?.id
        else { return nil }
        let layoutKind = controller.workspaceManager.activeLayoutKind(for: workspaceId)
        return PressedStrip(
            workspaceId: workspaceId,
            layoutKind: layoutKind,
            hasEdgePeeks: layoutKind == .niri && controller.niriEngine?.edgePeeksPossible == true
        )
    }

    func handleMouseDownFromTap(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton,
        windowIdUnderPointer: Int?,
        windowServerFramesAtMouseDown: [WindowToken: CGRect]?,
        strip: PressedStrip? = nil
    ) -> Bool {
        guard let controller else { return false }
        guard canHandleManagedMouseInteraction(controller: controller) else { return false }

        if shouldBlockOwnWindowInput(at: location) {
            return false
        }
        guard !state.isMoving, !state.isResizing else { return false }

        guard var strip = strip ?? pressedStrip(at: location) else { return false }
        let nativeDwindleResize = keepsNativeDwindleResizePress(
            at: location, modifiers: modifiers, button: button, in: &strip, windowId: windowIdUnderPointer
        )

        if button == .left,
           modifiers.isDisjoint(with: Self.relevantModifierFlags) || nativeDwindleResize
           || strip.layoutKind == .niri
        {
            holdEdgeResizeAtThePeek(at: location, modifiers: modifiers, in: strip)
            recordPointerFocusIntent(
                at: location,
                strip: strip,
                windowIdUnderPointer: windowIdUnderPointer,
                windowServerFramesAtMouseDown: windowServerFramesAtMouseDown
            )
        }

        return false
    }

    private func keepsNativeDwindleResizePress(
        at location: CGPoint, modifiers: CGEventFlags, button: MouseButton,
        in strip: inout PressedStrip, windowId: Int?
    ) -> Bool {
        guard button == .left, Self.modifierFlagsMatch(modifiers, required: .maskAlternate),
              strip.layoutKind == .dwindle, let controller, let engine = controller.dwindleEngine else { return false }
        let now = controller.animationClock.now()
        guard let token = engine.hitTestFocusableWindow(point: location, in: strip.workspaceId, at: now),
              windowId == nil || windowId == token.windowId,
              let frame = engine.presentedFrame(for: token, in: strip.workspaceId, at: now),
              Self.isNativeResizePress(at: location, in: frame)
        else { return false }
        strip.doubleClick = .dwindle(DwindlePressHit(token: token, zone: nil))
        return true
    }

    private func recordPointerFocusIntent(
        at location: CGPoint,
        strip: PressedStrip,
        windowIdUnderPointer: Int?,
        windowServerFramesAtMouseDown: [WindowToken: CGRect]?
    ) {
        guard let controller else { return }
        state.awaitsNativeTitleBarDragTarget = windowIdUnderPointer == nil
        state.nativeTitleBarDragFallbackReleased = false
        let exact = nativeTitleBarDragCandidate(windowIdUnderPointer: windowIdUnderPointer)
        let exactToken = exact?.token
        let focusIntentToken = exactToken ?? (windowIdUnderPointer == nil
            ? geometricFocusIntentCandidate(at: location, in: strip)
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

    func resizeEdges(for location: CGPoint, in frame: CGRect) -> ResizeEdge {
        var edges: ResizeEdge = location.x < frame.midX ? [.left] : [.right]
        edges.insert(location.y < frame.midY ? .bottom : .top)
        return edges
    }

    func shouldAcceptInteractionButton(_ button: MouseButton) -> Bool {
        state.activeInteractionSource == nil || state.activeInteractionSource == .mouse(button)
    }

    func isCapturedInteraction(_ button: MouseButton) -> Bool {
        tapInputs.capturedInteractionButton == button
    }
}
