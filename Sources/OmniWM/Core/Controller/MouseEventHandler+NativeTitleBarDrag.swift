// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func nativeTitleBarDragCandidate(
        windowIdUnderPointer: Int?
    ) -> WindowToken? {
        guard let windowIdUnderPointer,
              let entry = controller?.workspaceManager.entry(forWindowId: windowIdUnderPointer),
              entry.mode == .tiling
        else { return nil }
        return entry.token
    }

    func geometricFocusIntentCandidate(
        at location: CGPoint,
        workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        guard let controller else { return nil }
        let layoutType = controller.workspaceManager.descriptor(for: workspaceId)
            .map { controller.settings.workspaces.layoutType(for: $0.name) }
        let token: WindowToken?
        if layoutType == .dwindle {
            token = controller.dwindleEngine?.hitTestFocusableWindow(
                point: location,
                in: workspaceId,
                at: controller.animationClock.now()
            )
        } else {
            token = controller.niriEngine?.hitTestFocusableWindow(
                point: location,
                in: workspaceId
            )?.token
        }
        guard let token,
              controller.workspaceManager.entry(for: token)?.mode == .tiling
        else { return nil }
        return token
    }

    func captureNativeCrossDisplayMove(for token: WindowToken?) {
        guard let controller,
              controller.settings.gestures.adoptNativeMoveAcrossDisplays,
              let token,
              let entry = controller.workspaceManager.entry(for: token),
              entry.mode == .tiling,
              !controller.axManager.isAwaitingFrameWrite(token.windowId),
              let frame = controller.axManager.lastAppliedFrame(for: token.windowId)
        else {
            state.nativeCrossDisplayMove = nil
            return
        }
        state.nativeCrossDisplayMove = .init(token: token, workspaceId: entry.workspaceId, startFrame: frame)
    }

    func beginNativeTitleBarDragIfNeeded(button: MouseButton) {
        if button == .left {
            state.nativeCrossDisplayMove?.wasDragged = true
        }
        guard button == .left,
              var drag = state.nativeTitleBarDrag,
              drag.phase == .armed,
              let controller,
              controller.workspaceManager.entry(for: drag.token)?.mode == .tiling
        else { return }
        drag.phase = .dragging
        drag.adoptionStartFrame = controller.axManager.isAwaitingFrameWrite(drag.token.windowId)
            ? nil
            : controller.axManager.lastAppliedFrame(for: drag.token.windowId)
        state.nativeTitleBarDrag = drag
        controller.axManager.beginNativeTitleBarDrag(for: drag.token)
    }

    func finishNativeTitleBarDragIfNeeded(button: MouseButton) {
        guard button == .left else { return }
        markNativeTitleBarDragFallbackReleased(button: button)
        if state.nativeTitleBarDrag == nil,
           state.nativeTitleBarDragFallbackReleased
        {
            return
        }
        state.awaitsNativeTitleBarDragTarget = false
        state.nativeTitleBarDragFallbackToken = nil
        state.nativeTitleBarDragFallbackReleased = false
        guard var drag = state.nativeTitleBarDrag else { return }
        switch drag.phase {
        case .armed,
             .dragging:
            break
        case .awaitingFrameChange,
             .awaitingFrameWrite,
             .awaitingCorrection:
            return
        }
        guard let controller else {
            discardNativeTitleBarDragState()
            return
        }
        let excludedFrameWrite = controller.axManager.endNativeTitleBarDrag(for: drag.token)
        guard drag.phase == .dragging,
              controller.hasStartedServices,
              let entry = controller.workspaceManager.entry(for: drag.token),
              entry.mode == .tiling
        else {
            discardNativeTitleBarDragState()
            return
        }

        drag.pendingExcludedCorrection = excludedFrameWrite
        state.nativeTitleBarDrag = drag
        let observedFrame = terminalNativeWindowFrame(for: entry)
        let lastAppliedFrame = controller.axManager.lastAppliedFrame(for: entry.windowId)
        let observedDisplacement = Self.nativeTitleBarWasDisplaced(
            observedFrame: observedFrame, lastAppliedFrame: lastAppliedFrame,
            receivedFrameChange: drag.receivedFrameChange
        )
        settleReleasedNativeTitleBarDrag(
            drag,
            entry: entry,
            observedFrame: observedFrame,
            needsCorrection: excludedFrameWrite || observedDisplacement
        )
    }

    private func settleReleasedNativeTitleBarDrag(
        _ drag: MouseInputState.NativeTitleBarDrag,
        entry: WindowState,
        observedFrame: CGRect?,
        needsCorrection: Bool
    ) {
        var drag = drag
        if settleNativeCrossDisplayMoveIfNeeded(entry, observedFrame: observedFrame) { return }
        guard needsCorrection || drag.dwindleResizeWorkspaceId != nil else {
            if drag.receivedFrameChange {
                state.nativeTitleBarDrag = nil
            } else {
                drag.phase = .awaitingFrameChange
                state.nativeTitleBarDrag = drag
            }
            return
        }

        if adoptNativeResizeIfEligible(&drag, entry: entry, observedFrame: observedFrame) {
            state.nativeTitleBarDrag = drag
            return
        }
        drag.phase = .awaitingCorrection
        state.nativeTitleBarDrag = drag
        requestNativeTitleBarDragCorrection(for: entry)
    }

    func settleNativeCrossDisplayMoveIfNeeded(_ entry: WindowState, observedFrame: CGRect?) -> Bool {
        guard let controller,
              controller.hasStartedServices,
              controller.settings.gestures.adoptNativeMoveAcrossDisplays,
              let move = state.nativeCrossDisplayMove,
              move.wasDragged,
              let point = move.releaseLocation,
              move.token == entry.token,
              move.workspaceId == entry.workspaceId,
              entry.mode == .tiling,
              state.nativeTitleBarDrag?.dwindleResizeWorkspaceId == nil,
              case let .crossDisplay(drop) = classifyMoveLocation(
                  point, sourceToken: move.token, sourceWorkspaceId: move.workspaceId
              )
        else {
            state.nativeCrossDisplayMove = nil
            return false
        }
        if observedFrame == nil || observedFrame?.approximatelyEqual(
            to: move.startFrame, tolerance: FrameTolerance.screenMatch
        ) == true {
            var drag = state.nativeTitleBarDrag ?? .init(token: entry.token)
            drag.phase = .awaitingFrameChange
            state.nativeTitleBarDrag = drag
            return true
        }
        guard let observedFrame,
              abs(observedFrame.width - move.startFrame.width) <= FrameTolerance.screenMatch,
              abs(observedFrame.height - move.startFrame.height) <= FrameTolerance.screenMatch,
              !nativeWindowFrameMatchesManagedTarget(observedFrame, entry: entry),
              let plan = controller.crossDisplayDropPlan(for: drop)
        else {
            state.nativeCrossDisplayMove = nil
            return false
        }
        discardNativeTitleBarDragState()
        controller.axManager.cancelPendingFrameJobs(
            [(pid: entry.pid, windowId: entry.windowId)], reason: "native-cross-display-drop"
        )
        controller.performCrossDisplayDrop(plan)
        return true
    }

    private static func nativeTitleBarWasDisplaced(
        observedFrame: CGRect?, lastAppliedFrame: CGRect?, receivedFrameChange: Bool
    ) -> Bool {
        if let observedFrame, let lastAppliedFrame {
            return !observedFrame.approximatelyEqual(
                to: lastAppliedFrame,
                tolerance: FrameTolerance.frameWrite
            )
        } else if observedFrame != nil {
            return true
        } else {
            return receivedFrameChange
        }
    }

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
           let observedFrame = nativeWindowFrameProvider(entry.axRef),
           observedFrame.approximatelyEqual(
               to: lastAppliedFrame,
               tolerance: FrameTolerance.frameWrite
           )
        {
            discardNativeTitleBarDragState()
            return
        }
        let priorTerminalFailureRequestId = drag.terminalFailureRetryRequestId
        var correctionScheduledDuringCancellation = false
        if controller.axManager.pendingFrameWrite(for: entry.windowId) != nil {
            controller.axManager.cancelPendingFrameJobs(
                [(pid: entry.pid, windowId: entry.windowId)],
                reason: "native-drag-end"
            )
            if let currentDrag = state.nativeTitleBarDrag,
               currentDrag.token == drag.token,
               currentDrag.terminalFailureRetryRequestId != nil,
               currentDrag.terminalFailureRetryRequestId != priorTerminalFailureRequestId
            {
                correctionScheduledDuringCancellation = true
            }
        }
        discardNativeTitleBarDragState()
        if !correctionScheduledDuringCancellation {
            controller.axManager.invalidateAppliedFrame(for: entry.windowId)
            requestNativeTitleBarDragCorrection(for: entry)
        }
    }

    func discardNativeTitleBarDragState() {
        state.nativeCrossDisplayMove = nil
        state.awaitsNativeTitleBarDragTarget = false
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
    }

    func discardNativeTitleBarDrag(for token: WindowToken) {
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
              state.moveTap == nil
        else { return }
        state.nativeTitleBarDragFallbackReleased = true
    }
}
