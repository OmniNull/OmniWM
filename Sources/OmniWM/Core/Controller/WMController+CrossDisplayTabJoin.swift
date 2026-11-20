// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WMController {
    func applyCrossDisplayTabJoin(
        _ plan: borrowing CrossDisplayDropPlan,
        target: WindowToken,
        index: Int,
        states: inout [WorkspaceDescriptor.ID: ViewportState]
    ) {
        guard !plan.unit.isGroup, plan.targetLayout == .dwindle, let engine = dwindleEngine,
              let tile = engine.tile(containing: target, in: plan.drop.workspaceId),
              !engine.isWindowFullscreen(target, in: plan.drop.workspaceId),
              !engine.excludedTokens(in: plan.drop.workspaceId).contains(target)
        else { return }
        let insertion = min(max(index, 0), tile.members.count)
        let token = plan.unit.activeToken
        let source = plan.drop.sourceWorkspaceId
        let arrival: DwindleHistoryArrival
        switch plan.sourceLayout {
        case .dwindle:
            guard let detached = engine.detachForHistoryTransfer(token: token, wholeTile: false, from: source)
            else { return }
            arrival = detached
        case .niri:
            guard let niriEngine, let window = niriEngine.findNode(for: token, in: source) else { return }
            workspaceManager.captureDetachedNiriPlacement(for: token, in: source)
            engine.updateWindowConstraints(for: token, constraints: window.constraints)
            _ = niriEngine.detachWindowForTransfer(
                window, from: source,
                sourceState: &states[source, default: workspaceManager.niriViewportState(for: source)]
            )
            arrival = .member(DwindleTileMember(token: token, isFullscreen: false), excluded: false)
        }
        _ = engine.attachTransferredMember(consume arrival, to: target, at: insertion, in: plan.drop.workspaceId)
    }
}
