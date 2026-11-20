// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct LayoutHistoryWindowMove {
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
                guard let prepared = engine.withLayoutTransferHistory(direction, in: workspaceId, { entry in
                    historyWindowMoves(entry.transfer!, in: workspaceId, engine: engine, controller: controller)
                }) ?? nil
                else { return nil }
                if prepared.mixed {
                    guard let result = controller.stepMixedLayoutHistory(
                        direction, in: workspaceId, preparedMoves: prepared.moves
                    ) else { return nil }
                    guard result.changed else { continue }
                    return DwindleLayoutHistoryStep(focused: result.followed ? nil : result.focused)
                }
                let moves = prepared.moves
                guard let current = engine.layoutSnapshot(in: workspaceId),
                      let entry = engine.takeLayoutTransferHistory(direction, in: workspaceId)
                else { return nil }
                let inverse = inverseTransferHistory(
                    snapshot: consume current, moves: moves, in: workspaceId, engine: engine
                )
                let arrivals = detachHistoryArrivals(moves, into: workspaceId, engine: engine)
                restoreTransferHistoryPeers(entry.transfer!.away, moves: moves, engine: engine)
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

    private func restoreTransferHistoryPeers(
        _ away: borrowing [DwindleLayoutAway],
        moves: borrowing [LayoutHistoryWindowMove],
        engine: DwindleLayoutEngine
    ) {
        for index in away.indices {
            let target = away[index].workspaceId
            let returning = detachHistoryArrivals(moves, into: target, engine: engine)
            if !returning.isEmpty { engine.restoreLayoutAway(away[index], arrivals: consume returning) }
        }
    }

    private func historyWindowMoves(
        _ transfer: borrowing DwindleLayoutTransfer,
        in workspaceId: WorkspaceDescriptor.ID,
        engine: DwindleLayoutEngine,
        controller: WMController
    ) -> (moves: [LayoutHistoryWindowMove], mixed: Bool)? {
        let manager = controller.workspaceManager
        var moves: [LayoutHistoryWindowMove] = []
        var mixed = transfer.hasNiriAway
        for index in transfer.departed.indices {
            let token = transfer.departed[index]
            guard let current = manager.entry(for: token), current.workspaceId != workspaceId else { continue }
            let move = LayoutHistoryWindowMove(token: token, source: current.workspaceId, target: workspaceId)
            guard let sourceLayout = historyTransferSourceLayout(
                move, targetLayout: .dwindle, engine: engine, controller: controller
            )
            else { return nil }
            mixed = mixed || sourceLayout == .niri
            moves.append(move)
        }
        for index in transfer.away.indices {
            let target = transfer.away[index].workspaceId
            for tokenIndex in transfer.away[index].tokens.indices {
                let token = transfer.away[index].tokens[tokenIndex]
                guard manager.workspace(for: token) == workspaceId else { continue }
                let move = LayoutHistoryWindowMove(token: token, source: workspaceId, target: target)
                guard let sourceLayout = historyTransferSourceLayout(
                    move, targetLayout: .dwindle, engine: engine, controller: controller
                )
                else { return nil }
                mixed = mixed || sourceLayout == .niri
                moves.append(move)
            }
        }
        if let away = transfer.niriAway {
            guard appendNiriHistoryMoves(away, in: workspaceId, moves: &moves, engine: engine, controller: controller)
            else { return nil }
        }
        return (moves, mixed)
    }

    private func appendNiriHistoryMoves(
        _ away: borrowing [NiriLayoutAway],
        in workspaceId: WorkspaceDescriptor.ID,
        moves: inout [LayoutHistoryWindowMove],
        engine: DwindleLayoutEngine,
        controller: WMController
    ) -> Bool {
        let manager = controller.workspaceManager
        for index in away.indices {
            let target = away[index].workspaceId
            for tokenIndex in away[index].tokens.indices {
                let token = away[index].tokens[tokenIndex]
                guard manager.workspace(for: token) == workspaceId else { continue }
                let move = LayoutHistoryWindowMove(token: token, source: workspaceId, target: target)
                guard historyTransferSourceLayout(
                    move, targetLayout: .niri, engine: engine, controller: controller
                ) != nil else { return false }
                moves.append(move)
            }
        }
        return true
    }

    private func historyTransferSourceLayout(
        _ move: LayoutHistoryWindowMove,
        targetLayout: ActiveLayoutKind,
        engine: DwindleLayoutEngine,
        controller: WMController
    ) -> ActiveLayoutKind? {
        let manager = controller.workspaceManager
        guard manager.descriptor(for: move.source) != nil, manager.descriptor(for: move.target) != nil,
              manager.monitor(for: move.source) != nil, manager.monitor(for: move.target) != nil
        else { return nil }
        let sourceLayout = manager.activeLayoutKind(for: move.source)
        guard manager.activeLayoutKind(for: move.target) == targetLayout,
              manager.entry(for: move.token)?.target.hostedMetadata?.role.parent == nil,
              groupMemberActivationIsAllowed(move.token, workspaceId: move.source)
        else { return nil }
        if sourceLayout == .dwindle {
            guard engine.findNode(for: move.token, in: move.source) != nil else { return nil }
        } else if !niriHistoryParticipantIsAllowed(move.source, token: move.token, controller: controller) {
            return nil
        }
        if targetLayout == .niri, !niriHistoryParticipantIsAllowed(move.target, controller: controller) { return nil }
        return sourceLayout
    }

    private func niriHistoryParticipantIsAllowed(
        _ workspaceId: WorkspaceDescriptor.ID,
        token: WindowToken? = nil,
        controller: WMController
    ) -> Bool {
        guard let engine = controller.niriEngine else { return false }
        if let token, engine.findNode(for: token, in: workspaceId) == nil { return false }
        return !engine.isLiveColumnMoveActive(in: workspaceId)
            && !engine.isLiveStackDropPending(in: workspaceId)
            && !controller.niriLayoutHandler.isMouseResizeUnderway(engine: engine)
    }

    private func inverseTransferHistory(
        snapshot: consuming DwindleLayoutSnapshot,
        moves: borrowing [LayoutHistoryWindowMove],
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
        _ moves: borrowing [LayoutHistoryWindowMove],
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
        _ moves: borrowing [LayoutHistoryWindowMove],
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
