// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WMController {
    func detachMixedHistoryArrivals(
        _ moves: borrowing [LayoutHistoryWindowMove],
        into target: WorkspaceDescriptor.ID,
        states: inout [WorkspaceDescriptor.ID: ViewportState]
    ) -> MixedLayoutHistoryArrivals {
        if workspaceManager.activeLayoutKind(for: target) == .niri {
            var arrivals: [NiriWindow] = []
            for index in moves.indices where moves[index].target == target {
                if let window = detachMixedHistoryWindow(moves[index], states: &states) { arrivals.append(window) }
            }
            return .niri(arrivals)
        }
        var arrivals: [DwindleHistoryArrival] = []
        for index in moves.indices where moves[index].target == target {
            let move = moves[index]
            if workspaceManager.activeLayoutKind(for: move.source) == .niri {
                guard let window = detachMixedHistoryWindow(move, states: &states) else { continue }
                dwindleEngine?.updateWindowConstraints(for: move.token, constraints: window.constraints)
                arrivals.append(.member(DwindleTileMember(token: move.token, isFullscreen: false), excluded: false))
            } else if let engine = dwindleEngine, let tile = engine.tile(containing: move.token, in: move.source) {
                let whole = tile.members.allSatisfy { member in
                    moves.contains { $0.token == member.token && $0.source == move.source && $0.target == target }
                }
                if let arrival = engine.detachForHistoryTransfer(
                    token: move.token,
                    wholeTile: whole,
                    from: move.source
                ) {
                    arrivals.append(arrival)
                }
            }
        }
        return .dwindle(arrivals)
    }

    private func detachMixedHistoryWindow(
        _ move: LayoutHistoryWindowMove,
        states: inout [WorkspaceDescriptor.ID: ViewportState]
    ) -> NiriWindow? {
        if workspaceManager.activeLayoutKind(for: move.source) == .niri {
            guard let engine = niriEngine,
                  let window = engine.findNode(for: move.token, in: move.source) else { return nil }
            if workspaceManager.activeLayoutKind(for: move.target) == .dwindle {
                workspaceManager.captureDetachedNiriPlacement(for: move.token, in: move.source)
            }
            _ = engine.detachWindowForTransfer(window, from: move.source, sourceState: &states[move.source]!)
            return window
        }
        guard let engine = dwindleEngine, let monitor = workspaceManager.monitor(for: move.target) else { return nil }
        let constraints = layoutRefreshController.destinationConstraints(for: move.token, on: monitor)
        guard engine.detachForHistoryTransfer(token: move.token, wholeTile: false, from: move.source) != nil
        else { return nil }
        let window = NiriWindow(token: move.token)
        window.constraints = constraints
        engine.releaseConstraintsIfUntracked(move.token)
        return window
    }

    func restoreMixedHistoryPeers(
        _ entry: borrowing MixedLayoutHistoryEntry,
        moves: borrowing [LayoutHistoryWindowMove],
        states: inout [WorkspaceDescriptor.ID: ViewportState]
    ) {
        switch entry {
        case let .niri(snapshot):
            for index in snapshot.away.indices {
                restoreMixedNiriPeer(snapshot.away[index], moves: moves, states: &states)
            }
            if let transfer = snapshot.foreignTransfer {
                for index in transfer.away.indices {
                    restoreMixedDwindlePeer(transfer.away[index], moves: moves, states: &states)
                }
            }
        case let .dwindle(saved):
            if let transfer = saved.transfer {
                for index in transfer.away.indices {
                    restoreMixedDwindlePeer(transfer.away[index], moves: moves, states: &states)
                }
                if let niriAway = transfer.niriAway {
                    for index in niriAway.indices {
                        restoreMixedNiriPeer(niriAway[index], moves: moves, states: &states)
                    }
                }
            }
        }
    }

    private func restoreMixedNiriPeer(
        _ away: borrowing NiriLayoutAway,
        moves: borrowing [LayoutHistoryWindowMove],
        states: inout [WorkspaceDescriptor.ID: ViewportState]
    ) {
        guard case let .niri(arrivals) = detachMixedHistoryArrivals(moves, into: away.workspaceId, states: &states),
              !arrivals.isEmpty else { return }
        niriEngine?.restoreAwayColumns(away, in: away.workspaceId, arrivals: arrivals)
    }

    private func restoreMixedDwindlePeer(
        _ away: borrowing DwindleLayoutAway,
        moves: borrowing [LayoutHistoryWindowMove],
        states: inout [WorkspaceDescriptor.ID: ViewportState]
    ) {
        guard case let .dwindle(arrivals) = detachMixedHistoryArrivals(moves, into: away.workspaceId, states: &states),
              !arrivals.isEmpty else { return }
        dwindleEngine?.restoreLayoutAway(away, arrivals: consume arrivals)
    }

    func commitMixedHistory(
        _ direction: DwindleLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID,
        entry: consuming MixedLayoutHistoryEntry,
        inverse: consuming MixedLayoutHistoryEntry,
        arrivals: consuming MixedLayoutHistoryArrivals
    ) -> DwindleLayoutHistoryStep? {
        switch consume entry {
        case let .niri(entry):
            guard case let .niri(inverse) = consume inverse,
                  case let .niri(arrivals) = consume arrivals
            else { preconditionFailure() }
            return niriEngine?.commitForeignLayoutHistoryStep(
                direction == .undo ? .undo : .redo, in: workspaceId,
                entry: consume entry, inverse: consume inverse, arrivals: arrivals
            ).map { DwindleLayoutHistoryStep(focused: $0.focused) }
        case let .dwindle(entry):
            guard case let .dwindle(inverse) = consume inverse,
                  case let .dwindle(arrivals) = consume arrivals
            else { preconditionFailure() }
            return dwindleEngine?.commitTransferredLayoutHistoryStep(
                direction, in: workspaceId, entry: consume entry, inverse: consume inverse, arrivals: consume arrivals
            )
        }
    }
}
