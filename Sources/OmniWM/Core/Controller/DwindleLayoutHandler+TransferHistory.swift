// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

private struct DwindleHistoryWindowMove {
    let token: WindowToken
    let source: WorkspaceDescriptor.ID
    let target: WorkspaceDescriptor.ID
}

extension DwindleLayoutHandler {
    func stepLayoutHistoryAcrossWorkspaces(
        _ direction: DwindleLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID,
        engine: DwindleLayoutEngine,
        controller: WMController
    ) -> DwindleLayoutHistoryStep? {
        repeat {
            while engine.hasLayoutTransferHistory(direction, in: workspaceId) {
                guard let moves = engine.withLayoutTransferHistory(direction, in: workspaceId, { entry in
                          historyWindowMoves(entry.transfer!, in: workspaceId, engine: engine, controller: controller)
                      }) ?? nil,
                      let current = engine.layoutSnapshot(in: workspaceId),
                      let entry = engine.takeLayoutTransferHistory(direction, in: workspaceId)
                else { return nil }
                let inverse = inverseTransferHistory(
                    snapshot: consume current, moves: moves, in: workspaceId, engine: engine
                )
                let arrivals = detachHistoryArrivals(moves, into: workspaceId, engine: engine)
                for index in entry.transfer!.away.indices {
                    let target = entry.transfer!.away[index].workspaceId
                    let returning = detachHistoryArrivals(moves, into: target, engine: engine)
                    if !returning.isEmpty { engine.restoreLayoutAway(
                        entry.transfer!.away[index],
                        arrivals: consume returning
                    ) }
                }
                for move in moves {
                    controller.workspaceManager.setWorkspace(for: move.token, to: move.target)
                }
                let broughtBack = arrivals.last?.activeToken
                guard let step = engine.commitTransferredLayoutHistoryStep(
                    direction, in: workspaceId, entry: consume entry, inverse: consume inverse,
                    arrivals: consume arrivals
                ) else { continue }
                let followed = finishTransferHistory(
                    moves,
                    in: workspaceId,
                    broughtBack: broughtBack,
                    controller: controller
                )
                return DwindleLayoutHistoryStep(focused: followed ? nil : broughtBack ?? step.focused)
            }
            if let step = engine.stepLayoutHistory(direction, in: workspaceId) { return step }
        } while engine.hasLayoutTransferHistory(direction, in: workspaceId)
        return nil
    }

    private func historyWindowMoves(
        _ transfer: borrowing DwindleLayoutTransfer,
        in workspaceId: WorkspaceDescriptor.ID,
        engine: DwindleLayoutEngine,
        controller: WMController
    ) -> [DwindleHistoryWindowMove]? {
        let manager = controller.workspaceManager
        var moves: [DwindleHistoryWindowMove] = []
        for index in transfer.departed.indices {
            let token = transfer.departed[index]
            guard let current = manager.entry(for: token), current.workspaceId != workspaceId else { continue }
            guard historyTransferIsAllowed(
                token,
                from: current.workspaceId,
                to: workspaceId,
                engine: engine,
                controller: controller
            )
            else { return nil }
            moves.append(DwindleHistoryWindowMove(token: token, source: current.workspaceId, target: workspaceId))
        }
        for index in transfer.away.indices {
            let target = transfer.away[index].workspaceId
            for tokenIndex in transfer.away[index].tokens.indices {
                let token = transfer.away[index].tokens[tokenIndex]
                guard manager.workspace(for: token) == workspaceId else { continue }
                guard historyTransferIsAllowed(
                    token,
                    from: workspaceId,
                    to: target,
                    engine: engine,
                    controller: controller
                )
                else { return nil }
                moves.append(DwindleHistoryWindowMove(token: token, source: workspaceId, target: target))
            }
        }
        return moves
    }

    private func historyTransferIsAllowed(
        _ token: WindowToken,
        from source: WorkspaceDescriptor.ID,
        to target: WorkspaceDescriptor.ID,
        engine: DwindleLayoutEngine,
        controller: WMController
    ) -> Bool {
        let manager = controller.workspaceManager
        return manager.descriptor(for: source) != nil && manager.descriptor(for: target) != nil
            && manager.monitor(for: source) != nil && manager.monitor(for: target) != nil
            && manager.activeLayoutKind(for: source) == .dwindle
            && manager.activeLayoutKind(for: target) == .dwindle
            && manager.entry(for: token)?.target.hostedMetadata?.role.parent == nil
            && groupMemberActivationIsAllowed(token, workspaceId: source)
            && engine.findNode(for: token, in: source) != nil
    }

    private func inverseTransferHistory(
        snapshot: consuming DwindleLayoutSnapshot,
        moves: borrowing [DwindleHistoryWindowMove],
        in workspaceId: WorkspaceDescriptor.ID,
        engine: DwindleLayoutEngine
    ) -> DwindleLayoutHistoryEntry {
        var departed: [WindowToken] = []
        var away: [DwindleLayoutAway] = []
        for index in moves.indices where moves[index].source == workspaceId { departed.append(moves[index].token) }
        for index in moves.indices where moves[index].source != workspaceId {
            let move = moves[index]
            guard !away.contains(where: { $0.workspaceId == move.source }),
                  let peer = engine.layoutSnapshot(in: move.source)
            else { continue }
            var tokens: [WindowToken] = []
            for tokenIndex in moves.indices where moves[tokenIndex].source == move.source {
                tokens.append(moves[tokenIndex].token)
            }
            away.append(DwindleLayoutAway(workspaceId: move.source, tokens: tokens, snapshot: consume peer))
        }
        return DwindleLayoutHistoryEntry(snapshot: consume snapshot, departed: departed, away: away)
    }

    private func detachHistoryArrivals(
        _ moves: borrowing [DwindleHistoryWindowMove],
        into target: WorkspaceDescriptor.ID,
        engine: DwindleLayoutEngine
    ) -> [DwindleHistoryArrival] {
        var arrivals: [DwindleHistoryArrival] = []
        for index in moves.indices where moves[index].target == target {
            let move = moves[index]
            guard let tile = engine.tile(containing: move.token, in: move.source) else { continue }
            let wholeTile = tile.members.allSatisfy { member in
                moves.contains { $0.token == member.token && $0.source == move.source && $0.target == target }
            }
            if let transferred = engine.detachForHistoryTransfer(
                token: move.token,
                wholeTile: wholeTile,
                from: move.source
            ) {
                arrivals.append(transferred)
            }
        }
        return arrivals
    }

    private func finishTransferHistory(
        _ moves: borrowing [DwindleHistoryWindowMove],
        in workspaceId: WorkspaceDescriptor.ID,
        broughtBack: WindowToken?,
        controller: WMController
    ) -> Bool {
        var affected: Set<WorkspaceDescriptor.ID> = []
        for index in moves.indices {
            let move = moves[index]
            affected.insert(move.source)
            affected.insert(move.target)
        }
        affected.remove(workspaceId)
        if !affected.isEmpty {
            controller.layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: affected)
        }
        guard broughtBack == nil,
              let followed = moves
                  .last(where: { $0.source == workspaceId && controller.niriLayoutHandler.isShownOnADisplay($0.target)
                  })
        else { return false }
        _ = activateWindow(followed.token, in: followed.target, focusAfterLayout: true)
        return true
    }
}
