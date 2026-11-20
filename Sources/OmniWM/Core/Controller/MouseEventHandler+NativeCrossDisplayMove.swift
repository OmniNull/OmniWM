// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func captureNativeCrossDisplayMove(for token: WindowToken?) {
        guard let controller,
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

    func settleNativeCrossDisplayMoveIfNeeded(_ entry: WindowState, observedFrame: CGRect?) -> Bool {
        guard let controller,
              controller.hasStartedServices,
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
}
