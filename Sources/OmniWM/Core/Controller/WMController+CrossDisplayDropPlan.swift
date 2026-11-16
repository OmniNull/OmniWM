// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct CrossDisplayDragUnit: Equatable {
    let tokens: [WindowToken]
    let activeIndex: Int

    var activeToken: WindowToken {
        tokens[activeIndex]
    }

    var isGroup: Bool {
        tokens.count > 1
    }
}

struct CrossDisplayDropPlan {
    enum Operation: Equatable {
        case move(CrossDisplayDrop.Placement)
        case swap(partner: CrossDisplayDragUnit)
    }

    let drop: CrossDisplayDrop
    let sourceLayout: ActiveLayoutKind
    let targetLayout: ActiveLayoutKind
    let unit: CrossDisplayDragUnit
    let operation: Operation
    let constraints: [WindowToken: WindowSizeConstraints]

    var niriWorkspaceIds: [WorkspaceDescriptor.ID] {
        [(drop.sourceWorkspaceId, sourceLayout), (drop.workspaceId, targetLayout)]
            .filter { $0.1 == .niri }
            .map(\.0)
    }
}

extension WMController {
    func crossDisplayDropPlan(
        for drop: CrossDisplayDrop,
        unit override: CrossDisplayDragUnit? = nil
    ) -> CrossDisplayDropPlan? {
        let manager = workspaceManager
        guard drop.sourceWorkspaceId != drop.workspaceId,
              isCrossDisplayTransferable(drop.sourceToken, in: drop.sourceWorkspaceId),
              let sourceMonitor = manager.monitor(for: drop.sourceWorkspaceId)
        else {
            return nil
        }
        let unit = override ?? crossDisplayDragUnit(for: drop.sourceToken, in: drop.sourceWorkspaceId)
        if case .some = override {
            guard unit.tokens.indices.contains(unit.activeIndex), unit.activeToken == drop.sourceToken,
                  liveCrossDisplayUnitIsCurrent(unit, in: drop.sourceWorkspaceId)
            else { return nil }
        }
        var constraints = niriConstraints(for: unit, entering: drop.workspaceId, on: drop.monitor)

        let operation: CrossDisplayDropPlan.Operation
        if case let .swap(target) = drop.placement {
            guard isCrossDisplayTransferable(target, in: drop.workspaceId) else { return nil }
            let partner = crossDisplayDragUnit(for: target, in: drop.workspaceId)
            constraints.merge(niriConstraints(for: partner, entering: drop.sourceWorkspaceId, on: sourceMonitor)) {
                $1
            }
            guard slotAccepts(unit, replacing: partner, in: drop.workspaceId, on: drop.monitor, constraints),
                  slotAccepts(partner, replacing: unit, in: drop.sourceWorkspaceId, on: sourceMonitor, constraints)
            else {
                return nil
            }
            operation = .swap(partner: partner)
        } else {
            operation = .move(validatedCrossDisplayPlacement(drop, unit: unit, constraints: constraints))
        }
        return CrossDisplayDropPlan(
            drop: drop,
            sourceLayout: manager.activeLayoutKind(for: drop.sourceWorkspaceId),
            targetLayout: manager.activeLayoutKind(for: drop.workspaceId),
            unit: unit,
            operation: operation,
            constraints: constraints
        )
    }

    private func liveCrossDisplayUnitIsCurrent(
        _ unit: CrossDisplayDragUnit,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        for token in unit.tokens where workspaceManager.workspace(for: token) != workspaceId { return false }
        guard unit.isGroup else { return true }
        switch workspaceManager.activeLayoutKind(for: workspaceId) {
        case .niri:
            guard let engine = niriEngine,
                  let active = engine.findNode(for: unit.activeToken, in: workspaceId),
                  let column = engine.findColumn(containing: active, in: workspaceId),
                  column.windowNodes.count == unit.tokens.count
            else { return false }
            for token in unit.tokens where engine.findNode(for: token, in: workspaceId)?.parent !== column {
                return false
            }
        case .dwindle:
            guard let engine = dwindleEngine,
                  let tile = engine.tile(containing: unit.activeToken, in: workspaceId),
                  tile.members.count == unit.tokens.count
            else { return false }
            for token in unit.tokens where engine.tile(containing: token, in: workspaceId) !== tile { return false }
        }
        return true
    }

    func crossDisplayDragUnit(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> CrossDisplayDragUnit {
        guard settings.gestures.dwindleGroupDragAcrossDisplays == .group,
              workspaceManager.activeLayoutKind(for: workspaceId) == .dwindle,
              let tile = dwindleEngine?.tile(containing: token, in: workspaceId),
              tile.members.count > 1,
              let activeIndex = tile.memberIndex(for: token)
        else {
            return CrossDisplayDragUnit(tokens: [token], activeIndex: 0)
        }
        return CrossDisplayDragUnit(tokens: tile.members.map(\.token), activeIndex: activeIndex)
    }

    private func isCrossDisplayTransferable(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let entry = workspaceManager.entry(for: token),
              entry.workspaceId == workspaceId,
              entry.mode == .tiling,
              !workspaceManager.isWindowSuppressedByMacOS(token)
        else {
            return false
        }
        switch workspaceManager.activeLayoutKind(for: workspaceId) {
        case .niri:
            guard let engine = niriEngine, let node = engine.findNode(for: token, in: workspaceId) else { return false }
            return !node.isFullscreen && !engine.projectionExclusions(in: workspaceId).contains(token)
        case .dwindle:
            guard let engine = dwindleEngine,
                  engine.tile(containing: token, in: workspaceId) != nil else { return false }
            return !engine.isWindowFullscreen(token, in: workspaceId)
                && !engine.excludedTokens(in: workspaceId).contains(token)
        }
    }

    private func niriConstraints(
        for unit: CrossDisplayDragUnit,
        entering workspaceId: WorkspaceDescriptor.ID,
        on monitor: Monitor
    ) -> [WindowToken: WindowSizeConstraints] {
        guard workspaceManager.activeLayoutKind(for: workspaceId) == .niri else { return [:] }
        return Dictionary(uniqueKeysWithValues: unit.tokens.map { token in
            (token, layoutRefreshController.destinationConstraints(for: token, on: monitor))
        })
    }

    private func slotAccepts(
        _ incoming: CrossDisplayDragUnit,
        replacing partner: CrossDisplayDragUnit,
        in workspaceId: WorkspaceDescriptor.ID,
        on monitor: Monitor,
        _ constraints: [WindowToken: WindowSizeConstraints]
    ) -> Bool {
        switch workspaceManager.activeLayoutKind(for: workspaceId) {
        case .niri:
            guard let engine = niriEngine,
                  let partnerNode = engine.findNode(for: partner.activeToken, in: workspaceId),
                  let column = engine.findColumn(containing: partnerNode, in: workspaceId)
            else {
                return false
            }
            guard !incoming.isGroup else { return column.windowNodes.count == 1 }
            return engine.columnCanAcceptTransfer(
                column,
                adding: NiriWindow(token: incoming.activeToken),
                addingConstraints: constraints[incoming.activeToken],
                removing: partnerNode,
                in: workspaceId,
                geometry: niriSizingGeometry(for: monitor)
            )
        case .dwindle:
            guard incoming.isGroup else { return true }
            return dwindleEngine?.tile(containing: partner.activeToken, in: workspaceId)?.members.count
                == partner.tokens.count
        }
    }

    private func validatedCrossDisplayPlacement(
        _ drop: CrossDisplayDrop,
        unit: CrossDisplayDragUnit,
        constraints: [WindowToken: WindowSizeConstraints]
    ) -> CrossDisplayDrop.Placement {
        let workspaceId = drop.workspaceId
        switch drop.placement {
        case let .niriStack(target, _):
            guard !unit.isGroup,
                  let engine = niriEngine,
                  let targetNode = engine.findNode(for: target, in: workspaceId),
                  !targetNode.isFullscreen,
                  let column = engine.findColumn(containing: targetNode, in: workspaceId),
                  engine.columnCanAcceptTransfer(
                      column,
                      adding: NiriWindow(token: unit.activeToken),
                      addingConstraints: constraints[unit.activeToken],
                      in: workspaceId,
                      geometry: niriSizingGeometry(for: drop.monitor)
                  )
            else {
                return .workspace
            }
            return drop.placement
        case let .dwindleGroup(target, _):
            guard !unit.isGroup, isCrossDisplayTransferable(target, in: workspaceId) else { return .workspace }
            return drop.placement
        case let .dwindleBeside(target, _):
            guard let engine = dwindleEngine,
                  engine.tile(containing: target, in: workspaceId) != nil,
                  !engine.isWindowFullscreen(target, in: workspaceId)
            else {
                return .workspace
            }
            return drop.placement
        case .dwindleEdge:
            return dwindleEngine?.visibleTiles(in: workspaceId).any == true ? drop.placement : .workspace
        case let .dwindleSplitBoundary(splitId):
            return dwindleEngine?.canAttachTransfer(atSplitBoundary: splitId, in: workspaceId) == true
                ? drop.placement
                : .workspace
        case .niriNewColumn,
             .swap,
             .workspace:
            return drop.placement
        }
    }

    func niriSizingGeometry(for monitor: Monitor) -> NiriSizingGeometry {
        NiriSizingGeometry(
            workingFrame: niriWorkingFrame(for: monitor),
            gaps: innerGap(for: monitor),
            orientation: settings.monitors.effectiveOrientation(for: monitor)
        )
    }
}
