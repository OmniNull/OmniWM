// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func beginLiveDwindleTabPull(_ drag: TabRailDrag) {
        guard let controller, let engine = controller.dwindleEngine,
              !isInputSuppressed, !isInteractiveGestureActive,
              canHandleManagedMouseInteraction(controller: controller),
              case let .dwindleTile(tileId) = drag.info.owner,
              let token = drag.token,
              controller.workspaceManager.activeLayoutKind(for: drag.info.workspaceId) == .dwindle,
              controller.workspaceManager.isSeqCurrent(
                  drag.info.plannedSeq, for: drag.info.workspaceId, domains: .layoutCommit
              ),
              let tile = engine.tile(containing: token, in: drag.info.workspaceId),
              tile.id == tileId, tile.members.count > 1,
              tile.member(for: token)?.isFullscreen == false,
              controller.dwindleLayoutHandler.groupMemberActivationIsAllowed(token, workspaceId: drag.info.workspaceId),
              let monitor = controller.workspaceManager.monitor(for: drag.info.workspaceId),
              controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == drag.info.workspaceId,
              let frame = engine.presentedFrame(
                  for: token, in: drag.info.workspaceId, at: controller.animationClock.now()
              )
        else { return }
        finishPendingLiveStackDrop()
        let began = controller.workspaceManager.withEngineMutationScope(in: drag.info.workspaceId, source: .mouse) {
            guard engine.liveTabMoveBegin(token: token, startLocation: drag.pressLocation, in: drag.info.workspaceId)
            else { return false }
            engine.liveMoveSetFloatingFrame(frame)
            return true
        }
        guard began else { return }
        liveDragSession = .init(carriedWindow: .init(
            token: token, anchorLocation: drag.location, startFrame: frame, layout: .dwindle
        ))
        state.deferredClickScroll = nil
        controller.syncLiveDragPointerHold(active: true)
        moveLiveDwindleTabPull(to: drag.location, starting: true)
    }

    func moveLiveDwindleTabPull(to location: CGPoint, starting: Bool = false) {
        guard let pull = liveDragSession?.carriedWindow, pull.layout == .dwindle,
              let controller, let engine = controller.dwindleEngine,
              engine.liveTabMoveToken == pull.token,
              let workspaceId = engine.liveMoveWorkspaceId,
              controller.workspaceManager.workspace(for: pull.token) == workspaceId,
              controller.workspaceManager.activeLayoutKind(for: workspaceId) == .dwindle,
              let monitor = controller.workspaceManager.monitor(for: workspaceId),
              controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == workspaceId
        else {
            cancelLiveDwindleTabPull()
            return
        }
        livePointer.location = location
        if !monitor.frame.contains(location) {
            _ = carryLiveDragAcrossDisplays(at: location)
            return
        }
        let frame = pull.startFrame.offsetBy(
            dx: location.x - pull.anchorLocation.x, dy: location.y - pull.anchorLocation.y
        )
        guard starting || engine.liveTabMoveFloatingFrame != frame else { return }
        let hit = controller.tabRailManager.dragTarget(at: location)
        let target: DwindleTabMoveTarget?
        if let hit, hit.workspaceId == workspaceId, case .dwindleTile = hit.owner {
            target = DwindleTabMoveTarget(token: hit.token, index: hit.visualIndex)
        } else { target = nil }
        controller.workspaceManager.withEngineMutationScope(in: workspaceId, source: .mouse) {
            engine.liveMoveSetFloatingFrame(frame)
            _ = engine.liveTabMoveUpdate(
                currentLocation: location, at: controller.animationClock.now(),
                workspaceFrame: controller.insetWorkingFrame(for: monitor), railTarget: target
            )
        }
        guard engine.liveTabMoveToken == pull.token, engine.interactiveMove?.token == pull.token else {
            cancelLiveDwindleTabPull()
            return
        }
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .interactiveGesture, affectedWorkspaceIds: [workspaceId]
        )
    }

    func finishLiveDwindleTabPull() {
        guard liveDragSession?.carriedWindow?.layout == .dwindle,
              let controller, let engine = controller.dwindleEngine,
              let workspaceId = engine.liveMoveWorkspaceId
        else { return }
        controller.workspaceManager.withEngineMutationScope(in: workspaceId, source: .mouse) {
            _ = engine.liveMoveEnd()
        }
        endLiveDragSession()
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .interactiveGesture, affectedWorkspaceIds: [workspaceId]
        )
    }

    func cancelLiveDwindleTabPull(withinCrossDisplayMove: Bool = false) {
        guard liveDragSession?.carriedWindow?.layout == .dwindle else { return }
        if !withinCrossDisplayMove, liveCrossDisplayMove != nil {
            cancelLiveCrossDisplayMove()
            return
        }
        if let controller, let engine = controller.dwindleEngine,
           let workspaceId = engine.liveMoveWorkspaceId
        {
            controller.workspaceManager.withEngineMutationScope(in: workspaceId, source: .mouse) {
                _ = engine.liveMoveCancel(at: controller.animationClock.now())
            }
            if !withinCrossDisplayMove, controller.hasStartedServices {
                controller.layoutRefreshController.requestImmediateRelayout(
                    reason: .interactiveGesture, affectedWorkspaceIds: [workspaceId]
                )
            }
        }
        endLiveDragSession()
    }
}
