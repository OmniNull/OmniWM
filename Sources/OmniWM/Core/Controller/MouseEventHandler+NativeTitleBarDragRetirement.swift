// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func retireNativeTitleBarDragAtInputBoundary() {
        guard let drag = state.nativeTitleBarDrag else {
            discardNativeTitleBarDragState()
            return
        }
        guard drag.phase != .armed,
              let controller,
              let entry = controller.workspaceManager.entry(for: drag.token),
              entry.mode == .tiling
        else {
            discardNativeTitleBarDragState()
            return
        }
        if drag.phase == .awaitingFrameChange,
           !drag.pendingExcludedCorrection,
           controller.axManager.pendingFrameWrite(for: entry.windowId) == nil,
           let lastAppliedFrame = controller.axManager.lastAppliedFrame(for: entry.windowId),
           let axRef = entry.axRef,
           let observedFrame = nativeWindowFrameProvider(axRef),
           observedFrame.approximatelyEqual(
               to: lastAppliedFrame,
               tolerance: FrameTolerance.frameWrite
           )
        {
            discardNativeTitleBarDragState()
            return
        }
        let correctionScheduledDuringCancellation = cancelPendingWriteAtRetirement(
            of: drag,
            entry: entry,
            controller: controller
        )
        discardNativeTitleBarDragState()
        if !correctionScheduledDuringCancellation {
            controller.axManager.invalidateAppliedFrame(for: entry.windowId)
            requestNativeTitleBarDragCorrection(for: entry)
        }
    }

    @inline(__always)
    private func cancelPendingWriteAtRetirement(
        of drag: MouseInputState.NativeTitleBarDrag,
        entry: WindowState,
        controller: WMController
    ) -> Bool {
        guard controller.axManager.pendingFrameWrite(for: entry.windowId) != nil else { return false }
        let priorTerminalFailureRequestId = drag.terminalFailureRetryRequestId
        controller.axManager.cancelPendingFrameJobs(
            [(pid: entry.pid, windowId: entry.windowId)],
            reason: "native-drag-end"
        )
        guard let currentDrag = state.nativeTitleBarDrag,
              currentDrag.token == drag.token,
              currentDrag.terminalFailureRetryRequestId != nil
        else { return false }
        return currentDrag.terminalFailureRetryRequestId != priorTerminalFailureRequestId
    }

    func discardNativeTitleBarDragState() {
        cancelLiveCrossDisplayMove()
        cancelLiveDwindleTabPull()
        correctDeferredNativeResizeFrameIfNeeded()
        state.nativeResizeStart = nil
        clearNativeResizeStartRejections()
        state.nativeCrossDisplayMove = nil
        cancelLiveDwindleDrag()
        cancelLiveColumnDrag()
        livePointer.location = nil
        livePointer.samples = []
        state.awaitsNativeTitleBarDragTarget = false
        state.nativeTitleBarDragPressTimestamp = nil
        state.nativeTitleBarDragFallbackToken = nil
        state.nativeTitleBarDragFallbackReleased = false
        if var drag = state.nativeTitleBarDrag {
            finishNativeDwindleResize(&drag)
            _ = controller?.axManager.endNativeTitleBarDrag(for: drag.token)
        }
        state.nativeTitleBarDrag = nil
    }

    func clearNativeTitleBarDrag() {
        guard let drag = state.nativeTitleBarDrag else {
            discardNativeTitleBarDragState()
            return
        }
        discardNativeTitleBarDragState()
        if drag.phase != .armed || drag.receivedFrameChange,
           let controller,
           controller.workspaceManager.entry(for: drag.token)?.mode == .tiling
        {
            controller.axManager.invalidateAppliedFrame(for: drag.token.windowId)
            controller.axManager.forceApplyNextFrame(for: drag.token.windowId)
        }
    }

    func tracksNativeTitleBarDrag(windowId: Int) -> Bool {
        state.nativeTitleBarDrag?.token.windowId == windowId
            || state.nativeTitleBarDragFallbackToken?.windowId == windowId
            || state.nativeResizeCorrectionsByWindowId[windowId] != nil
    }

    func discardNativeTitleBarDrag(for token: WindowToken) {
        if state.moveLayout == .dwindle, controller?.dwindleEngine?.liveMoveToken == token {
            cancelActiveMouseInteraction()
        }
        if isCarryingWindowByGesture, liveDragSession?.carriedWindow?.token == token {
            cancelLiveColumnDrag()
        }
        if state.nativeResizeCorrectionsByWindowId[token.windowId]?.token == token {
            state.nativeResizeCorrectionsByWindowId[token.windowId] = nil
        }
        guard state.nativeTitleBarDrag?.token == token
            || state.nativeTitleBarDragFallbackToken == token
            || state.nativeCrossDisplayMove?.token == token
        else { return }
        discardNativeTitleBarDragState()
    }

    func requestNativeTitleBarDragCorrection(for entry: WindowState) {
        guard let controller else { return }
        controller.axManager.forceApplyNextFrame(for: entry.windowId)
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .interactiveGesture,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    func markNativeTitleBarDragFallbackReleased(button: MouseButton, at location: CGPoint? = nil) {
        if button == .left, let location {
            state.nativeCrossDisplayMove?.releaseLocation = location
        }
        guard button == .left,
              state.nativeTitleBarDrag == nil,
              state.awaitsNativeTitleBarDragTarget,
              state.nativeTitleBarDragFallbackToken != nil,
              state.moveTap == nil || state.nativeResizeStart?.wasDragged == true
        else { return }
        state.nativeTitleBarDragFallbackReleased = true
    }
}
