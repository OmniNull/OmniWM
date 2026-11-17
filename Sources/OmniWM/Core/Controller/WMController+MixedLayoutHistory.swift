// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct MixedLayoutHistoryResult {
    let changed: Bool
    let focused: WindowToken?
    let followed: Bool
}

enum MixedLayoutHistoryEntry: ~Copyable {
    case niri(NiriLayoutSnapshot)
    case dwindle(DwindleLayoutHistoryEntry)
}

enum MixedLayoutHistoryArrivals: ~Copyable {
    case niri([NiriWindow])
    case dwindle([DwindleHistoryArrival])

    var lastToken: WindowToken? {
        switch self {
        case let .niri(windows): windows.last?.token
        case let .dwindle(tiles): tiles.last?.activeToken
        }
    }
}

extension WMController {
    func stepMixedLayoutHistory(
        _ direction: DwindleLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID,
        preparedMoves: [LayoutHistoryWindowMove]? = nil,
        keepingFocus: Bool = false
    ) -> MixedLayoutHistoryResult? {
        guard let moves = preparedMoves ?? niriMixedHistoryMoves(direction, in: workspaceId) else { return nil }
        var niriIds: [WorkspaceDescriptor.ID] = []
        if workspaceManager.activeLayoutKind(for: workspaceId) == .niri { niriIds.append(workspaceId) }
        for move in moves {
            if workspaceManager.activeLayoutKind(for: move.source) == .niri, !niriIds.contains(move.source) {
                niriIds.append(move.source)
            }
            if workspaceManager.activeLayoutKind(for: move.target) == .niri, !niriIds.contains(move.target) {
                niriIds.append(move.target)
            }
        }
        var broughtBack: WindowToken?
        var result: MixedLayoutHistoryResult?
        workspaceManager.withBatchedCrossWorkspaceDrop(into: workspaceId, niriWorkspaceIds: niriIds) { states in
            guard let inverse = mixedHistoryInverse(moves, in: workspaceId),
                  let entry = takeMixedHistory(direction, in: workspaceId)
            else { return [] }
            let arrivals = detachMixedHistoryArrivals(moves, into: workspaceId, states: &states)
            let focused = arrivals.lastToken
            broughtBack = focused
            restoreMixedHistoryPeers(entry, moves: moves, states: &states)
            let step = commitMixedHistory(
                direction, in: workspaceId, entry: consume entry, inverse: consume inverse,
                arrivals: consume arrivals
            )
            result = MixedLayoutHistoryResult(changed: step != nil, focused: focused ?? step?.focused, followed: false)
            return moves.map { CrossWorkspaceDropAssignment(token: $0.token, workspaceId: $0.target) }
        }
        guard let result, result.changed else { return result }
        let followed = finishMixedHistory(moves, in: workspaceId, broughtBack: broughtBack, keepingFocus: keepingFocus)
        return MixedLayoutHistoryResult(changed: true, focused: result.focused, followed: followed)
    }

    private func niriMixedHistoryMoves(
        _ direction: DwindleLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> [LayoutHistoryWindowMove]? {
        guard let engine = niriEngine else { return nil }
        return engine.withForeignLayoutHistory(direction == .undo ? .undo : .redo, in: workspaceId) { entry in
            guard let transfer = entry.foreignTransfer else { return nil }
            var moves: [LayoutHistoryWindowMove] = []
            for index in transfer.departed.indices {
                let token = transfer.departed[index]
                guard let source = workspaceManager.workspace(for: token), source != workspaceId else { continue }
                let move = LayoutHistoryWindowMove(token: token, source: source, target: workspaceId)
                guard mixedHistoryMoveIsAllowed(move, targetLayout: .niri) else { return nil }
                moves.append(move)
            }
            for index in entry.away.indices {
                guard appendMixedHistoryMoves(
                    entry.away[index].tokens, from: workspaceId, to: entry.away[index].workspaceId,
                    targetLayout: .niri, moves: &moves
                ) else { return nil }
            }
            for index in transfer.away.indices {
                guard appendMixedHistoryMoves(
                    transfer.away[index].tokens, from: workspaceId, to: transfer.away[index].workspaceId,
                    targetLayout: .dwindle, moves: &moves
                ) else { return nil }
            }
            return moves
        } ?? nil
    }

    private func appendMixedHistoryMoves(
        _ tokens: borrowing [WindowToken],
        from source: WorkspaceDescriptor.ID,
        to target: WorkspaceDescriptor.ID,
        targetLayout: ActiveLayoutKind,
        moves: inout [LayoutHistoryWindowMove]
    ) -> Bool {
        for index in tokens.indices where workspaceManager.workspace(for: tokens[index]) == source {
            let move = LayoutHistoryWindowMove(token: tokens[index], source: source, target: target)
            guard mixedHistoryMoveIsAllowed(move, targetLayout: targetLayout) else { return false }
            moves.append(move)
        }
        return true
    }

    private func mixedHistoryMoveIsAllowed(_ move: LayoutHistoryWindowMove, targetLayout: ActiveLayoutKind) -> Bool {
        guard workspaceManager.descriptor(for: move.source) != nil,
              workspaceManager.descriptor(for: move.target) != nil,
              workspaceManager.monitor(for: move.source) != nil, workspaceManager.monitor(for: move.target) != nil,
              workspaceManager.activeLayoutKind(for: move.target) == targetLayout,
              workspaceManager.entry(for: move.token)?.target.hostedMetadata?.role.parent == nil,
              dwindleLayoutHandler.groupMemberActivationIsAllowed(move.token, workspaceId: move.source),
              let niri = niriEngine, let dwindle = dwindleEngine,
              dwindle.interactiveMove == nil, dwindle.interactiveResize == nil,
              !niriLayoutHandler.isMouseResizeUnderway(engine: niri)
        else { return false }
        for id in [move.source, move.target] where workspaceManager.activeLayoutKind(for: id) == .niri {
            if niri.isLiveColumnMoveActive(in: id) || niri.isLiveStackDropPending(in: id) { return false }
        }
        return workspaceManager.activeLayoutKind(for: move.source) == .niri
            ? niri.findNode(for: move.token, in: move.source) != nil
            : dwindle.findNode(for: move.token, in: move.source) != nil
    }

    private func takeMixedHistory(
        _ direction: DwindleLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> MixedLayoutHistoryEntry? {
        if workspaceManager.activeLayoutKind(for: workspaceId) == .niri {
            guard let entry = niriEngine?.takeForeignLayoutHistory(direction == .undo ? .undo : .redo, in: workspaceId)
            else { return nil }
            return .niri(entry)
        }
        guard let entry = dwindleEngine?.takeLayoutTransferHistory(direction, in: workspaceId) else { return nil }
        return .dwindle(entry)
    }

    private func mixedHistoryInverse(
        _ moves: borrowing [LayoutHistoryWindowMove],
        in workspaceId: WorkspaceDescriptor.ID
    ) -> MixedLayoutHistoryEntry? {
        var departed: [WindowToken] = []
        var niriAway: [NiriLayoutAway] = []
        var dwindleAway: [DwindleLayoutAway] = []
        for index in moves.indices where moves[index].source == workspaceId { departed.append(moves[index].token) }
        for index in moves.indices where moves[index].source != workspaceId {
            let source = moves[index].source
            guard !niriAway.contains(where: { $0.workspaceId == source }),
                  !dwindleAway.contains(where: { $0.workspaceId == source }) else { continue }
            var tokens: [WindowToken] = []
            for tokenIndex in moves.indices
                where moves[tokenIndex].source == source { tokens.append(moves[tokenIndex].token) }
            if workspaceManager.activeLayoutKind(for: source) == .niri {
                guard let snapshot = niriEngine?.layoutSnapshot(in: source, focused: nil) else { return nil }
                niriAway.append(NiriLayoutAway(workspaceId: source, tokens: tokens, snapshot: snapshot))
            } else {
                guard let snapshot = dwindleEngine?.layoutSnapshot(in: source) else { return nil }
                dwindleAway.append(DwindleLayoutAway(workspaceId: source, tokens: tokens, snapshot: consume snapshot))
            }
        }
        if workspaceManager.activeLayoutKind(for: workspaceId) == .niri {
            guard var snapshot = niriEngine?.layoutSnapshot(in: workspaceId, focused: nil) else { return nil }
            snapshot.foreignTransfer = NiriForeignTransfer(departed: departed, away: dwindleAway)
            snapshot.away = niriAway
            return .niri(snapshot)
        }
        guard let snapshot = dwindleEngine?.layoutSnapshot(in: workspaceId) else { return nil }
        return .dwindle(DwindleLayoutHistoryEntry(
            snapshot: consume snapshot, departed: departed, away: dwindleAway,
            niriAway: niriAway.isEmpty ? nil : niriAway
        ))
    }

    private func finishMixedHistory(
        _ moves: borrowing [LayoutHistoryWindowMove],
        in workspaceId: WorkspaceDescriptor.ID,
        broughtBack: WindowToken?,
        keepingFocus: Bool
    ) -> Bool {
        var affected: Set<WorkspaceDescriptor.ID> = []
        for index in moves.indices {
            affected.insert(moves[index].source)
            affected.insert(moves[index].target)
        }
        affected.remove(workspaceId)
        if !affected.isEmpty { layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: affected) }
        guard broughtBack == nil,
              let followed = moves
                  .last(where: { $0.source == workspaceId && niriLayoutHandler.isShownOnADisplay($0.target) }),
              !keepingFocus || followed.token == focusedManagedTokenForCommand()
        else { return false }
        if workspaceManager.activeLayoutKind(for: followed.target) == .dwindle {
            _ = dwindleLayoutHandler.activateWindow(followed.token, in: followed.target, focusAfterLayout: true)
        } else if let window = niriEngine?.findNode(for: followed.token, in: followed.target) {
            workspaceManager.withNiriViewportState(for: followed.target) { $0.selectedNodeId = window.id }
            niriLayoutHandler.frontRestoredWindow(window, in: followed.target, controller: self)
        }
        return true
    }
}
