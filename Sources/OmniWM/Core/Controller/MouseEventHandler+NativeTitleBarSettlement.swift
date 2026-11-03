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
           state.nativeTitleBarDragFallbackReleased
           || pressedMouseButtonsProvider() & MouseButton.left.pressedMask != 0,
           state.nativeTitleBarDragFallbackToken == entry.token,
           entry.mode == .tiling,
           let controller
        {
            return adoptNativeTitleBarFallback(entry, controller: controller)
        }
        if state.nativeTitleBarDrag?.token != entry.token,
           handleRetainedNativeResizeCorrection(for: entry)
        {
            return true
        }
        guard var drag = state.nativeTitleBarDrag,
              drag.token == entry.token
        else { return false }
        switch drag.phase {
        case .armed:
            return false
        case .dragging:
            return updateNativeTitleBarDraggingFrame(entry, drag: &drag)
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

    private func updateNativeTitleBarDraggingFrame(
        _ entry: WindowState, drag: inout MouseInputState.NativeTitleBarDrag
    ) -> Bool {
        drag.receivedFrameChange = true
        if drag.dwindleResizeWorkspaceId != nil
            || (controller?.settings.gestures.adoptNativeResize == true
                && controller?.workspaceManager.activeLayoutKind(for: entry.workspaceId) == .dwindle)
        {
            updateNativeDwindleResize(
                &drag,
                entry: entry,
                observedFrame: entry.axRef.flatMap(nativeWindowFrameProvider)
            )
        }
        state.nativeTitleBarDrag = drag
        return true
    }

    private func adoptNativeTitleBarFallback(_ entry: WindowState, controller: WMController) -> Bool {
        guard !controller.niriLayoutHandler.hasScrollAnimation(for: entry.workspaceId) else {
            return false
        }
        guard let observedFrame = terminalNativeWindowFrame(for: entry),
              !nativeWindowFrameMatchesManagedTarget(observedFrame, entry: entry)
        else { return false }
        let released = state.nativeTitleBarDragFallbackReleased
        let hasResizeStart = state.nativeResizeStart?.token == entry.token
            && state.nativeResizeStart?.wasDragged == true
        if !released || state.moveTap != nil,
           state.nativeResizeStart?.token == entry.token,
           state.nativeResizeStart?.wasDragged == false || state.moveTap != nil
        {
            state.nativeResizeStart?.hasDeferredFrameChange = true
            return true
        }
        guard state.moveTap == nil else { return false }
        state.awaitsNativeTitleBarDragTarget = false
        state.nativeTitleBarDragFallbackToken = nil
        state.nativeTitleBarDragFallbackReleased = false
        let drag = MouseInputState.NativeTitleBarDrag(token: entry.token)
        if released {
            if settleNativeCrossDisplayMoveIfNeeded(entry, observedFrame: observedFrame) { return true }
            if let pendingFrame = controller.axManager.pendingFrameWrite(for: entry.windowId),
               !hasResizeStart || !controller.settings.gestures.adoptNativeResize
               || controller.axManager.hasInFlightFrameWrite(for: entry.token)
            {
                awaitNativeTitleBarDragFrameWrite(
                    pendingFrame,
                    entry: entry,
                    drag: drag
                )
                return true
            }
        }
        state.nativeTitleBarDrag = drag
        beginNativeTitleBarDragIfNeeded(button: .left)
        if !hasResizeStart {
            state.nativeTitleBarDrag?.adoptionStartFrame = nil
        }
        if released {
            finishNativeTitleBarDragIfNeeded(button: .left)
        } else {
            _ = handleNativeTitleBarDragFrameChanged(for: entry)
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
        guard let controller, let axRef = entry.axRef else { return }
        var drag = drag
        drag.phase = .awaitingFrameWrite
        drag.receivedFrameChange = true
        state.nativeTitleBarDrag = drag
        controller.axManager.applyFramesParallel(
            [AXFrameApplicationTarget(pid: entry.pid, window: axRef, frame: pendingFrame)],
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

    func fastNativeWindowFrame(for entry: WindowState) -> CGRect? {
        guard let axRef = entry.axRef else { return controller?.shellAppWindowManager.frame(for: entry.token) }
        return nativeWindowFrameProvider(axRef)
    }

    func terminalNativeWindowFrame(for entry: WindowState) -> CGRect? {
        fastNativeWindowFrame(for: entry) ?? entry.axRef.flatMap(nativeWindowFrameFallbackProvider)
    }

    func handleNativeTitleBarDragFrameApplySucceeded(_ result: AXFrameApplyResult) {
        settleRetainedNativeResizeCorrectionAfterWrite(result)
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
        guard let axRef = entry.axRef, sameAXWindowIdentity(result.expectedWindow, axRef) else { return }
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
               !observedFrame.approximatelyEqual(to: confirmedFrame, tolerance: FrameTolerance.frameWrite)
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

    private func settleRetainedNativeResizeCorrectionAfterWrite(_ result: AXFrameApplyResult) {
        guard var correction = state.nativeResizeCorrectionsByWindowId[result.windowId],
              correction.token == WindowToken(pid: result.pid, windowId: result.windowId),
              let controller, controller.hasStartedServices,
              let entry = controller.workspaceManager.entry(for: correction.token),
              entry.mode == .tiling, entry.hiddenState == nil,
              let reference = entry.axRef, sameAXWindowIdentity(result.expectedWindow, reference)
        else { return }
        if result.confirmedFrame != nil {
            correction.issuedTerminalFailureCorrection = false
        } else {
            guard !correction.issuedTerminalFailureCorrection else { return }
            correction.issuedTerminalFailureCorrection = true
            correction.issuedUnreadableCorrection = false
            correction.needsFrameWriteRecheck = true
            controller.axManager.invalidateAppliedFrame(for: entry.windowId)
        }
        state.nativeResizeCorrectionsByWindowId[entry.windowId] = correction
        recheckRetainedNativeResizeCorrection(for: correction.token)
    }

    func recheckRetainedNativeResizeCorrection(for token: WindowToken) {
        guard let correction = state.nativeResizeCorrectionsByWindowId[token.windowId],
              correction.token == token, correction.needsFrameWriteRecheck,
              state.nativeTitleBarDrag?.token != correction.token,
              state.nativeTitleBarDragFallbackToken != correction.token,
              let entry = controller?.workspaceManager.entry(for: correction.token)
        else { return }
        _ = handleRetainedNativeResizeCorrection(for: entry)
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
        guard let axRef = entry.axRef, sameAXWindowIdentity(result.expectedWindow, axRef) else { return }
        if result.confirmedFrame != nil {
            handleNativeTitleBarDragFrameApplySucceeded(result)
            return
        }
        handleNativeTitleBarDragFrameApplyTerminated(result, allowsAwaitingFrameWrite: true)
    }

    func handleNativeTitleBarDragFrameApplyTerminated(_ result: AXFrameApplyResult) {
        settleRetainedNativeResizeCorrectionAfterWrite(result)
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
        guard let axRef = entry.axRef, sameAXWindowIdentity(result.expectedWindow, axRef) else { return }
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
