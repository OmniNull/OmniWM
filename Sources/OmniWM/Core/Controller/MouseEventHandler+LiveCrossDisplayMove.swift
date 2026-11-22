// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct LiveCrossDisplayMove: ~Copyable {
    let unit: CrossDisplayDragUnit
    let originWorkspaceId: WorkspaceDescriptor.ID
    var workspaceId: WorkspaceDescriptor.ID
    var snapshots: [WorkspaceDescriptor.ID: LiveCrossDisplaySnapshot]?
    var released = false
}

extension MouseEventHandler {
    func carryLiveDragAcrossDisplays(
        at location: CGPoint,
        crossingTo targetWorkspaceId: WorkspaceDescriptor.ID? = nil
    ) -> Bool {
        guard let controller, let token = liveCrossDisplayToken,
              let entry = controller.workspaceManager.entry(for: token)
        else { return false }
        guard let target = targetWorkspaceId ?? liveCrossDisplayDestination(at: location, controller: controller)
        else { return liveCrossDisplayMove != nil }
        guard target != entry.workspaceId,
              targetWorkspaceId != nil || liveCrossDisplayMove != nil
              || controller.workspaceManager.activeLayoutKind(for: entry.workspaceId) == .dwindle
              || controller.workspaceManager.activeLayoutKind(for: target) == .dwindle
        else { return false }
        let carriedWindow = liveDragSession?.carriedWindow
        let unit = liveCrossDisplayMove?.unit
            ?? liveCrossDisplayUnit(for: token, in: entry.workspaceId, controller: controller)
        guard let unit,
              let preflight = liveCrossDisplayDrop(
                  at: location, source: entry.workspaceId, unit: unit,
                  pullsTab: carriedWindow != nil, controller: controller
              ),
              let prepared = controller.crossDisplayDropPlan(for: preflight, unit: unit)
        else { return true }

        cancelLocalCrossDisplayDriver()
        guard let source = controller.workspaceManager.workspace(for: token) else {
            cancelLiveCrossDisplayMove()
            return true
        }
        let resolved: CrossDisplayDropPlan? = if source == preflight.sourceWorkspaceId {
            prepared
        } else if let drop = liveCrossDisplayDrop(
            at: location, source: source, unit: unit,
            pullsTab: carriedWindow != nil, controller: controller
        ) {
            controller.crossDisplayDropPlan(for: drop, unit: unit)
        } else { nil }
        guard let plan = resolved else {
            cancelLiveCrossDisplayMove()
            return true
        }
        applyLiveCrossDisplayDrop(plan, at: location, carriedWindow: carriedWindow, controller: controller)
        return true
    }

    private var liveCrossDisplayToken: WindowToken? {
        if let pull = liveDragSession?.carriedWindow { return pull.token }
        guard let drag = state.nativeTitleBarDrag, drag.liveDrag || drag.dwindleLiveDrag else { return nil }
        return drag.token
    }

    private func liveCrossDisplayDestination(
        at location: CGPoint,
        controller: borrowing WMController
    ) -> WorkspaceDescriptor.ID? {
        for monitor in controller.workspaceManager.monitors where monitor.frame.contains(location) {
            return controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        }
        return nil
    }

    private func applyLiveCrossDisplayDrop(
        _ plan: borrowing CrossDisplayDropPlan,
        at location: CGPoint,
        carriedWindow: MouseInputState.CarriedWindow?,
        controller: borrowing WMController
    ) {
        let drop = plan.drop
        let source = drop.sourceWorkspaceId
        if liveCrossDisplayMove == nil {
            liveCrossDisplayMove = LiveCrossDisplayMove(
                unit: plan.unit, originWorkspaceId: source, workspaceId: source, snapshots: [:]
            )
        }
        guard captureLiveCrossDisplayWorkspace(source), captureLiveCrossDisplayWorkspace(drop.workspaceId),
              controller.performLiveCrossDisplayDrop(plan)
        else {
            cancelLiveCrossDisplayMove()
            return
        }
        liveCrossDisplayMove?.workspaceId = drop.workspaceId
        state.nativeCrossDisplayMove = nil
        let region: CGRect? = switch plan.operation {
        case .move(.dwindleBeside),
             .move(.dwindleGroup),
             .move(.dwindleEdge),
             .swap: drop.previewFrame
        default: nil
        }
        guard startCrossDisplayDriver(
            for: plan.unit.activeToken, in: drop.workspaceId, at: location, holding: region,
            carriedWindow: carriedWindow
        )
        else {
            cancelLiveCrossDisplayMove()
            return
        }
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .interactiveGesture, affectedWorkspaceIds: [source, drop.workspaceId]
        )
    }

    private func liveCrossDisplayDrop(
        at location: CGPoint,
        source: WorkspaceDescriptor.ID,
        unit: borrowing CrossDisplayDragUnit,
        pullsTab: Bool,
        controller: borrowing WMController
    ) -> CrossDisplayDrop? {
        let token = unit.activeToken
        guard case let .crossDisplay(drop) = classifyMoveLocation(
            location, sourceToken: token, sourceWorkspaceId: source
        )
        else { return nil }
        if pullsTab { return tabPullCrossDisplayDrop(drop, at: location) }
        guard unit.isGroup, controller.workspaceManager.activeLayoutKind(for: source) == .niri else { return drop }
        let target: WindowToken
        switch drop.placement {
        case let .swap(token),
             let .niriStack(token, _): target = token
        default: return drop
        }
        let placement: CrossDisplayDrop.Placement
        var preview = drop.previewFrame
        if controller.workspaceManager.activeLayoutKind(for: drop.workspaceId) == .dwindle {
            let direction: Direction = location.x < drop.previewFrame.midX ? .left : .right
            placement = .dwindleBeside(target: target, direction: direction)
            preview = WindowMoveGeometry.targetFrame(in: preview, direction: direction)
        } else {
            guard let engine = controller.niriEngine,
                  let window = engine.findNode(for: target, in: drop.workspaceId),
                  let column = engine.findColumn(containing: window, in: drop.workspaceId),
                  let index = engine.columnIndex(of: column, in: drop.workspaceId),
                  let context = liveColumnContext(for: drop.workspaceId)
            else { return nil }
            let trailing = context.primaryCoordinate(of: location)
                >= context.primaryStart(of: drop.previewFrame) + context.primarySpan(of: drop.previewFrame) / 2
            placement = .niriNewColumn(durableIndex: index + (trailing ? 1 : 0))
        }
        return CrossDisplayDrop(
            sourceToken: token, sourceWorkspaceId: source, workspaceId: drop.workspaceId,
            monitor: drop.monitor, placement: placement, previewFrame: preview
        )
    }

    private func liveCrossDisplayUnit(
        for token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        controller: borrowing WMController
    ) -> CrossDisplayDragUnit? {
        if liveDragSession?.carriedWindow?.token == token {
            return CrossDisplayDragUnit(tokens: [token], activeIndex: 0)
        }
        if let engine = controller.niriEngine, let move = engine.liveColumnMove,
           move.windowToken == token, move.isWholeColumn,
           let column = engine.liveDraggedColumn(for: move)
        {
            let windows = column.windowNodes
            guard let active = windows.firstIndex(where: { $0.token == token }) else { return nil }
            return CrossDisplayDragUnit(
                tokens: windows.reversed().map(\.token),
                activeIndex: windows.count - 1 - active
            )
        }
        return controller.crossDisplayDragUnit(for: token, in: workspaceId)
    }

    private func captureLiveCrossDisplayWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard liveCrossDisplayMove?.snapshots?[workspaceId] == nil else { return true }
        guard let controller else { return false }
        let snapshot = controller.workspaceManager.withEngineMutationScope(in: workspaceId, source: .mouse) {
            controller.captureLiveCrossDisplayLayout(in: workspaceId)
        }
        guard let snapshot else { return false }
        liveCrossDisplayMove?.snapshots?[workspaceId] = snapshot
        return true
    }

    private func cancelLocalCrossDisplayDriver() {
        finishPendingLiveStackDrop()
        cancelLiveDwindleTabPull(withinCrossDisplayMove: true)
        cancelLiveDwindleDrag(withinCrossDisplayMove: true)
        cancelLiveColumnDrag()
        state.liveDragLayoutStart = nil
    }

    private func startCrossDisplayDriver(
        for token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        at location: CGPoint,
        holding region: CGRect?,
        carriedWindow: MouseInputState.CarriedWindow?
    ) -> Bool {
        if var carriedWindow {
            return startCrossDisplayTabPull(&carriedWindow, in: workspaceId, at: location, holding: region)
        }
        guard let controller, var drag = state.nativeTitleBarDrag else { return false }
        drag.liveDragDeclined = false
        drag.liveDragHandedOver = false
        let dwindle = controller.workspaceManager.activeLayoutKind(for: workspaceId) == .dwindle
        drag.canStartLiveDwindleDrag = dwindle
        drag.canStartLiveNiriDrag = !dwindle
        state.nativeTitleBarDrag = drag
        if dwindle {
            guard let engine = controller.dwindleEngine else { return false }
            let began = controller.workspaceManager.withEngineMutationScope(in: workspaceId, source: .mouse) {
                engine.liveMoveBegin(token: token, startLocation: location, holding: region, in: workspaceId)
            }
            state.nativeTitleBarDrag?.dwindleLiveDrag = began
            return began
        }
        guard let entry = controller.workspaceManager.entry(for: token),
              beginLiveColumnDragIfEligible(&drag, entry: entry)
        else { return false }
        state.nativeTitleBarDrag = drag
        return true
    }

    func finishLiveCrossDisplayMove(token: WindowToken, releaseFrame: CGRect? = nil) -> Bool {
        guard liveCrossDisplayMove?.unit.activeToken == token, let controller else { return false }
        liveCrossDisplayMove?.released = true
        let finished: Bool
        if let engine = controller.dwindleEngine, let workspaceId = engine.liveMoveWorkspaceId {
            finished = controller.workspaceManager.withEngineMutationScope(in: workspaceId, source: .mouse) {
                engine.liveMoveEnd(recordingHistory: false) != nil
            }
            recordLiveCrossDisplayMove()
        } else {
            finished = finishLiveColumnDrag(
                token: token, releaseFrame: releaseFrame, startSize: state.nativeTitleBarDrag?.adoptionStartFrame?.size
            )
            if !finished {
                liveCrossDisplayMove?.released = false
                cancelLiveCrossDisplayMove()
            }
        }
        return finished
    }

    func recordLiveCrossDisplayMove() {
        guard liveCrossDisplayMove?.released == true, let controller,
              var move = liveCrossDisplayMove.take(), let snapshots = move.snapshots.take()
        else { return }
        let source = move.originWorkspaceId
        let target = move.workspaceId
        controller.recordLiveCrossDisplayLayouts(consume snapshots)
        if source != target {
            controller.finishLiveDragAcrossDisplays(
                token: move.unit.activeToken, carrying: move.unit.tokens, from: source, to: target
            )
        }
    }

    func cancelLiveCrossDisplayMove() {
        guard liveCrossDisplayMove != nil else { return }
        if liveCrossDisplayMove?.released == true {
            finishPendingLiveStackDrop()
            recordLiveCrossDisplayMove()
            return
        }
        guard var move = liveCrossDisplayMove.take(), let snapshots = move.snapshots.take() else { return }
        cancelLocalCrossDisplayDriver()
        controller?.restoreLiveCrossDisplayLayouts(snapshots, into: move.originWorkspaceId)
    }
}
