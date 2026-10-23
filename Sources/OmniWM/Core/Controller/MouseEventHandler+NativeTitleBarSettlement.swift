// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func handleNativeTitleBarDragFrameChanged(for entry: WindowState) -> Bool {
        guard entry.hiddenState == nil else {
            discardNativeTitleBarDrag(for: entry.token)
            return false
        }
        if state.nativeTitleBarDrag == nil,
           state.awaitsNativeTitleBarDragTarget,
           state.moveTap == nil,
           state.nativeTitleBarDragFallbackReleased
           || pressedMouseButtonsProvider() & MouseButton.left.pressedMask != 0,
           state.nativeTitleBarDragFallbackToken == entry.token,
           entry.mode == .tiling,
           let controller
        {
            return adoptNativeTitleBarFallback(entry, controller: controller)
        }
        guard var drag = state.nativeTitleBarDrag,
              drag.token == entry.token
        else { return false }
        switch drag.phase {
        case .armed:
            return false
        case .dragging:
            drag.receivedFrameChange = true
            if drag.dwindleResizeWorkspaceId != nil
                || (controller?.settings.gestures.adoptNativeResize == true
                    && controller?.workspaceManager.activeLayoutKind(for: entry.workspaceId) == .dwindle)
            {
                updateNativeDwindleResize(&drag, entry: entry, observedFrame: nativeWindowFrameProvider(entry.axRef))
            }
            state.nativeTitleBarDrag = drag
            return true
        case .awaitingFrameChange:
            return settleAwaitedNativeTitleBarFrame(entry, drag: drag)
        case .awaitingFrameWrite:
            drag.receivedFrameChange = true
            if controller?.axManager.pendingFrameWrite(for: entry.windowId) == nil {
                drag.phase = .awaitingCorrection
                state.nativeTitleBarDrag = drag
                requestNativeTitleBarDragCorrection(for: entry)
            } else {
                state.nativeTitleBarDrag = drag
            }
            return true
        case .awaitingCorrection:
            drag.receivedFrameChange = true
            state.nativeTitleBarDrag = drag
            return true
        }
    }

    private func adoptNativeTitleBarFallback(_ entry: WindowState, controller: WMController) -> Bool {
        guard !controller.niriLayoutHandler.hasScrollAnimation(for: entry.workspaceId) else {
            return false
        }
        guard let observedFrame = terminalNativeWindowFrame(for: entry),
              !nativeWindowFrameMatchesManagedTarget(observedFrame, entry: entry)
        else { return false }
        let released = state.nativeTitleBarDragFallbackReleased
        state.awaitsNativeTitleBarDragTarget = false
        state.nativeTitleBarDragFallbackToken = nil
        state.nativeTitleBarDragFallbackReleased = false
        var drag = MouseInputState.NativeTitleBarDrag(token: entry.token)
        if released {
            if settleNativeCrossDisplayMoveIfNeeded(entry, observedFrame: observedFrame) { return true }
            if let pendingFrame = controller.axManager.pendingFrameWrite(for: entry.windowId) {
                awaitNativeTitleBarDragFrameWrite(
                    pendingFrame,
                    entry: entry,
                    drag: drag
                )
            } else {
                drag.phase = .awaitingCorrection
                state.nativeTitleBarDrag = drag
                requestNativeTitleBarDragCorrection(for: entry)
            }
        } else {
            drag.phase = .dragging
            drag.receivedFrameChange = true
            state.nativeTitleBarDrag = drag
            controller.axManager.beginNativeTitleBarDrag(for: entry.token)
        }
        return true
    }

    private func settleAwaitedNativeTitleBarFrame(
        _ entry: WindowState, drag: MouseInputState.NativeTitleBarDrag
    ) -> Bool {
        var drag = drag
        if controller?.niriLayoutHandler.hasScrollAnimation(for: entry.workspaceId) == true {
            return false
        }
        let observedFrame = terminalNativeWindowFrame(for: entry)
        if settleNativeCrossDisplayMoveIfNeeded(entry, observedFrame: observedFrame) { return true }
        if let observedFrame,
           nativeWindowFrameMatchesManagedTarget(observedFrame, entry: entry)
        {
            drag.receivedFrameChange = false
            drag.issuedUnreadableCorrection = false
            state.nativeTitleBarDrag = drag
            return true
        }
        if let pendingFrame = controller?.axManager.pendingFrameWrite(for: entry.windowId) {
            awaitNativeTitleBarDragFrameWrite(
                pendingFrame,
                entry: entry,
                drag: drag
            )
            return true
        }
        if observedFrame == nil, drag.issuedUnreadableCorrection {
            drag.receivedFrameChange = true
            state.nativeTitleBarDrag = drag
            controller?.axManager.invalidateAppliedFrame(for: entry.windowId)
            return true
        }
        if adoptNativeResizeIfEligible(&drag, entry: entry, observedFrame: observedFrame) {
            state.nativeTitleBarDrag = drag
            return true
        }
        drag.issuedUnreadableCorrection = observedFrame == nil
        drag.phase = .awaitingCorrection
        drag.receivedFrameChange = false
        state.nativeTitleBarDrag = drag
        requestNativeTitleBarDragCorrection(for: entry)
        return true
    }

    private func awaitNativeTitleBarDragFrameWrite(
        _ pendingFrame: CGRect,
        entry: WindowState,
        drag: MouseInputState.NativeTitleBarDrag
    ) {
        guard let controller else { return }
        var drag = drag
        drag.phase = .awaitingFrameWrite
        drag.receivedFrameChange = true
        state.nativeTitleBarDrag = drag
        controller.axManager.applyFramesParallel(
            [AXFrameApplicationTarget(pid: entry.pid, window: entry.axRef, frame: pendingFrame)],
            terminalObserver: { [weak self] result in
                self?.handleNativeTitleBarDragPendingFrameSettled(result)
            }
        )
    }

    func nativeWindowFrameMatchesManagedTarget(
        _ observedFrame: CGRect,
        entry: WindowState
    ) -> Bool {
        if let pendingFrame = controller?.axManager.pendingFrameWrite(for: entry.windowId),
           pendingFrame.approximatelyEqual(
               to: observedFrame,
               tolerance: FrameTolerance.frameWrite
           )
        {
            return true
        }
        return controller?.axManager.lastAppliedFrame(for: entry.windowId)?.approximatelyEqual(
            to: observedFrame,
            tolerance: FrameTolerance.frameWrite
        ) == true
    }

    func terminalNativeWindowFrame(for entry: WindowState) -> CGRect? {
        nativeWindowFrameProvider(entry.axRef)
            ?? nativeWindowFrameFallbackProvider(entry.axRef)
    }

    func handleNativeTitleBarDragFrameApplySucceeded(_ result: AXFrameApplyResult) {
        guard let controller, var drag = state.nativeTitleBarDrag,
              drag.phase == .awaitingCorrection || drag.phase == .awaitingFrameWrite,
              drag.token == WindowToken(pid: result.pid, windowId: result.windowId)
        else { return }
        guard let entry = controller.workspaceManager.entry(for: drag.token),
              entry.mode == .tiling
        else {
            discardNativeTitleBarDragState()
            return
        }
        guard sameAXWindowIdentity(result.expectedWindow, entry.axRef) else { return }
        guard let confirmedFrame = result.confirmedFrame else {
            discardNativeTitleBarDragState()
            return
        }
        drag.phase = .awaitingCorrection
        drag.pendingExcludedCorrection = false
        var retainUnreadableFrameChange = false
        if drag.receivedFrameChange {
            let observedFrame = terminalNativeWindowFrame(for: entry)
            if let observedFrame,
               !observedFrame.approximatelyEqual(
                   to: confirmedFrame,
                   tolerance: FrameTolerance.frameWrite
               )
            {
                drag.issuedUnreadableCorrection = false
                drag.receivedFrameChange = false
                state.nativeTitleBarDrag = drag
                requestNativeTitleBarDragCorrection(for: entry)
                return
            }
            if observedFrame == nil {
                controller.axManager.invalidateAppliedFrame(for: entry.windowId)
                if !drag.issuedUnreadableCorrection {
                    drag.issuedUnreadableCorrection = true
                    drag.receivedFrameChange = false
                    state.nativeTitleBarDrag = drag
                    requestNativeTitleBarDragCorrection(for: entry)
                    return
                }
                retainUnreadableFrameChange = true
            } else {
                drag.issuedUnreadableCorrection = false
            }
        }
        drag.phase = .awaitingFrameChange
        drag.receivedFrameChange = retainUnreadableFrameChange
        drag.adoptionStartFrame = nil
        state.nativeTitleBarDrag = drag
    }

    func handleNativeTitleBarDragPendingFrameSettled(_ result: AXFrameApplyResult) {
        guard let drag = state.nativeTitleBarDrag,
              drag.phase == .awaitingFrameWrite,
              drag.token == WindowToken(pid: result.pid, windowId: result.windowId)
        else { return }
        guard let controller,
              let entry = controller.workspaceManager.entry(for: drag.token),
              entry.mode == .tiling
        else {
            discardNativeTitleBarDragState()
            return
        }
        guard sameAXWindowIdentity(result.expectedWindow, entry.axRef) else { return }
        if result.confirmedFrame != nil {
            handleNativeTitleBarDragFrameApplySucceeded(result)
            return
        }
        handleNativeTitleBarDragFrameApplyTerminated(result, allowsAwaitingFrameWrite: true)
    }

    func handleNativeTitleBarDragFrameApplyTerminated(_ result: AXFrameApplyResult) {
        handleNativeTitleBarDragFrameApplyTerminated(result, allowsAwaitingFrameWrite: false)
    }

    private func handleNativeTitleBarDragFrameApplyTerminated(
        _ result: AXFrameApplyResult,
        allowsAwaitingFrameWrite: Bool
    ) {
        guard var drag = state.nativeTitleBarDrag,
              drag.token == WindowToken(pid: result.pid, windowId: result.windowId),
              drag.phase == .awaitingCorrection
              || (allowsAwaitingFrameWrite && drag.phase == .awaitingFrameWrite),
              let controller
        else { return }
        guard let entry = controller.workspaceManager.entry(for: drag.token),
              entry.mode == .tiling
        else {
            discardNativeTitleBarDragState()
            return
        }
        guard sameAXWindowIdentity(result.expectedWindow, entry.axRef) else { return }
        guard drag.terminalFailureRetryRequestId != result.requestId else { return }
        controller.axManager.invalidateAppliedFrame(for: entry.windowId)
        guard drag.terminalFailureRetryRequestId == nil else {
            discardNativeTitleBarDragState()
            return
        }
        drag.terminalFailureRetryRequestId = result.requestId
        drag.phase = .awaitingCorrection
        state.nativeTitleBarDrag = drag
        requestNativeTitleBarDragCorrection(for: entry)
    }
}
