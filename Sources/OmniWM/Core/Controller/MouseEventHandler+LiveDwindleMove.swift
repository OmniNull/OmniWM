// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func handleLiveDwindleDragFrameChange(
        _ drag: inout MouseInputState.NativeTitleBarDrag,
        entry: borrowing WindowState
    ) -> Bool {
        guard let controller, let engine = controller.dwindleEngine else { return false }
        if drag.dwindleLiveDrag {
            guard engine.liveMoveToken == drag.token, engine.interactiveMove?.token == drag.token else {
                cancelLiveDwindleDrag()
                drag.dwindleLiveDrag = false
                drag.canStartLiveDwindleDrag = false
                return false
            }
            state.nativeTitleBarDrag = drag
            return true
        }
        guard drag.dwindleResizeWorkspaceId == nil, !drag.liveDragDeclined,
              entry.hiddenState == nil, entry.mode == .tiling,
              controller.workspaceManager.activeLayoutKind(for: entry.workspaceId) == .dwindle,
              let monitor = controller.workspaceManager.monitor(for: entry.workspaceId),
              controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == entry.workspaceId,
              let start = drag.liveStartFrame,
              let observed = entry.axRef.flatMap(nativeWindowFrameProvider),
              Self.isNativeMove(from: start, to: observed),
              let press = state.leftPressLocation
        else { return false }
        let token = entry.token
        let workspaceId = entry.workspaceId
        let began = controller.workspaceManager.withEngineMutationScope(in: workspaceId, source: .mouse) {
            engine.liveMoveBegin(token: token, startLocation: press, in: workspaceId)
        }
        guard began else {
            drag.liveDragDeclined = true
            return false
        }
        drag.dwindleLiveDrag = true
        drag.adoptionStartFrame = start
        state.nativeTitleBarDrag = drag
        state.deferredClickScroll = nil
        if let location = livePointer.location {
            updateLiveDwindleDrag(at: location)
        }
        return true
    }

    func trackLiveDwindleDrag(at location: CGPoint, button: MouseButton) -> Bool {
        guard button == .left else { return false }
        livePointer.location = location
        guard state.nativeTitleBarDrag?.dwindleLiveDrag == true else { return false }
        updateLiveDwindleDrag(at: location)
        return true
    }

    private func updateLiveDwindleDrag(at location: CGPoint) {
        guard let controller, let engine = controller.dwindleEngine,
              let workspaceId = engine.liveMoveWorkspaceId,
              let token = engine.liveMoveToken,
              controller.workspaceManager.activeLayoutKind(for: workspaceId) == .dwindle,
              let monitor = controller.workspaceManager.monitor(for: workspaceId),
              controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == workspaceId
        else {
            cancelLiveDwindleDrag()
            return
        }
        if !monitor.frame.contains(location) {
            _ = carryLiveDragAcrossDisplays(at: location)
            return
        }
        if engine.liveMoveHoldsTarget(at: location) { return }
        let changed = controller.workspaceManager.withEngineMutationScope(in: workspaceId, source: .mouse) {
            engine.liveMoveUpdate(
                currentLocation: location, at: controller.animationClock.now(),
                workspaceFrame: controller.insetWorkingFrame(for: monitor)
            )
        }
        guard engine.interactiveMove?.token == token else {
            cancelLiveDwindleDrag()
            return
        }
        guard changed else { return }
        controller.workspaceManager.recordLayoutOperation(
            .interactiveMoveEnded(token: token),
            in: workspaceId,
            source: .mouse
        )
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .interactiveGesture, affectedWorkspaceIds: [workspaceId]
        )
    }

    func finishLiveDwindleDrag(token: WindowToken, at location: CGPoint?) -> Bool {
        guard let controller, let engine = controller.dwindleEngine,
              engine.liveMoveToken == token, let workspaceId = engine.liveMoveWorkspaceId
        else { return false }
        var crossesDisplay = false
        if let location {
            switch classifyMoveLocation(location, sourceToken: token, sourceWorkspaceId: workspaceId) {
            case .crossDisplay,
                 .cancel: crossesDisplay = true
            case .sourceDisplay: break
            }
        }
        return controller.workspaceManager.withEngineMutationScope(in: workspaceId, source: .mouse) {
            if crossesDisplay || engine.interactiveMove?.token != token {
                engine.liveMoveCancel(at: controller.animationClock.now()) != nil
            } else {
                engine.liveMoveEnd() != nil
            }
        }
    }

    func cancelLiveDwindleDrag(withinCrossDisplayMove: Bool = false) {
        guard state.nativeTitleBarDrag?.dwindleLiveDrag == true else { return }
        if !withinCrossDisplayMove, liveCrossDisplayMove != nil {
            cancelLiveCrossDisplayMove()
            return
        }
        state.nativeTitleBarDrag?.dwindleLiveDrag = false
        state.nativeTitleBarDrag?.canStartLiveDwindleDrag = false
        guard let controller, let engine = controller.dwindleEngine,
              let workspaceId = engine.liveMoveWorkspaceId
        else { return }
        let restored = controller.workspaceManager.withEngineMutationScope(in: workspaceId, source: .mouse) {
            engine.liveMoveCancel(at: controller.animationClock.now())
        }
        if restored != nil, !withinCrossDisplayMove, controller.hasStartedServices {
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .interactiveGesture, affectedWorkspaceIds: [workspaceId]
            )
        }
    }
}
