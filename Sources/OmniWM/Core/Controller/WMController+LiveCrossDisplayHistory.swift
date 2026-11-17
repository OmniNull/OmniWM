// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum LiveCrossDisplaySnapshot {
    case niri(NiriLayoutSnapshot, ViewportState)
    case dwindle(DwindleLayoutSnapshot)

    var layout: ActiveLayoutKind {
        switch self {
        case .niri: .niri
        case .dwindle: .dwindle
        }
    }

    func forEachToken(_ body: (WindowToken) -> Void) {
        switch self {
        case let .niri(snapshot, _):
            for column in snapshot.columns.indices {
                for index in snapshot.columns[column].windows.indices {
                    body(snapshot.columns[column].windows[index])
                }
            }
        case let .dwindle(snapshot):
            for index in snapshot.members.indices { body(snapshot.members[index].token) }
        }
    }
}

extension WMController {
    func captureLiveCrossDisplayLayout(in workspaceId: WorkspaceDescriptor.ID) -> LiveCrossDisplaySnapshot? {
        guard workspaceManager.descriptor(for: workspaceId) != nil else { return nil }
        switch workspaceManager.activeLayoutKind(for: workspaceId) {
        case .niri:
            guard let engine = niriEngine else { return nil }
            engine.assertSanctionedMutation()
            let state = workspaceManager.niriViewportState(for: workspaceId)
            let focused = state.selectedNodeId.flatMap { engine.findNode(by: $0, in: workspaceId) as? NiriWindow }?
                .token
            if engine.root(for: workspaceId) == nil { return .niri(.empty, state) }
            guard let snapshot = engine.layoutSnapshot(in: workspaceId, focused: focused) else { return nil }
            return .niri(snapshot, state)
        case .dwindle:
            guard let snapshot = dwindleEngine?.layoutSnapshot(in: workspaceId) else { return nil }
            return .dwindle(snapshot)
        }
    }

    func recordLiveCrossDisplayLayouts(
        _ snapshots: consuming [WorkspaceDescriptor.ID: LiveCrossDisplaySnapshot]
    ) {
        let captured = consume snapshots
        let participants = liveCrossDisplayParticipants(captured)
        guard let first = participants.first else { return }
        let moves = liveCrossDisplayHistoryMoves(captured, participants: participants)
        workspaceManager.withBatchedCrossWorkspaceDrop(into: first, niriWorkspaceIds: []) { _ in
            for workspaceId in participants {
                guard let snapshot = captured[workspaceId] else { continue }
                recordLiveCrossDisplayLayout(consume snapshot, in: workspaceId, moves: moves, snapshots: captured)
            }
            return []
        }
    }

    private func recordLiveCrossDisplayLayout(
        _ saved: consuming LiveCrossDisplaySnapshot,
        in workspaceId: WorkspaceDescriptor.ID,
        moves: borrowing [LayoutHistoryWindowMove],
        snapshots: borrowing [WorkspaceDescriptor.ID: LiveCrossDisplaySnapshot]
    ) {
        var departed: [WindowToken] = []
        for index in moves.indices where moves[index].source == workspaceId { departed.append(moves[index].token) }
        var niriAway: [NiriLayoutAway] = []
        var dwindleAway: [DwindleLayoutAway] = []
        for index in snapshots.indices {
            let peerId = snapshots[index].key
            var tokens: [WindowToken] = []
            for move in moves.indices where moves[move].source == peerId && moves[move].target == workspaceId {
                tokens.append(moves[move].token)
            }
            guard !tokens.isEmpty else { continue }
            switch snapshots[index].value {
            case let .niri(snapshot, _):
                niriAway.append(NiriLayoutAway(workspaceId: peerId, tokens: tokens, snapshot: snapshot))
            case let .dwindle(snapshot):
                dwindleAway.append(DwindleLayoutAway(workspaceId: peerId, tokens: tokens, snapshot: snapshot))
            }
        }
        let transferred = !departed.isEmpty || !niriAway.isEmpty || !dwindleAway.isEmpty
        switch consume saved {
        case let .niri(snapshot, _):
            guard transferred else {
                niriEngine?.recordLayoutChange(in: workspaceId, since: consume snapshot)
                return
            }
            let entry = NiriLayoutSnapshot(
                columns: snapshot.columns, manualWidthColumnCount: snapshot.manualWidthColumnCount,
                manualHeightColumnCount: snapshot.manualHeightColumnCount, focused: snapshot.focused,
                away: niriAway, foreignTransfer: NiriForeignTransfer(departed: departed, away: dwindleAway)
            )
            niriEngine?.recordForeignLayoutHistory(entry: consume entry, in: workspaceId)
        case let .dwindle(snapshot):
            guard transferred else {
                dwindleEngine?.recordLayoutChange(in: workspaceId, since: consume snapshot)
                return
            }
            dwindleEngine?.recordForeignLayoutHistory(
                entry: DwindleLayoutHistoryEntry(
                    snapshot: consume snapshot, departed: departed, away: dwindleAway,
                    niriAway: niriAway.isEmpty ? nil : niriAway
                ), in: workspaceId
            )
        }
    }

    func restoreLiveCrossDisplayLayouts(
        _ snapshots: borrowing [WorkspaceDescriptor.ID: LiveCrossDisplaySnapshot],
        into origin: WorkspaceDescriptor.ID
    ) {
        let participants = liveCrossDisplayParticipants(snapshots)
        guard let first = participants.first else { return }
        let forwards = liveCrossDisplayHistoryMoves(snapshots, participants: participants)
        let moves = forwards.map { LayoutHistoryWindowMove(token: $0.token, source: $0.target, target: $0.source) }
        let niriIds = participants.filter { workspaceManager.activeLayoutKind(for: $0) == .niri }
        let target = participants.contains(origin) ? origin : first
        workspaceManager.withBatchedCrossWorkspaceDrop(into: target, niriWorkspaceIds: niriIds) { states in
            var niriArrivals: [WorkspaceDescriptor.ID: [NiriWindow]] = [:]
            var dwindleArrivals: [WorkspaceDescriptor.ID: [DwindleHistoryArrival]] = [:]
            for workspaceId in participants {
                switch detachMixedHistoryArrivals(moves, into: workspaceId, states: &states) {
                case let .niri(arrivals): niriArrivals[workspaceId] = arrivals
                case let .dwindle(arrivals): dwindleArrivals[workspaceId] = arrivals
                }
            }
            for workspaceId in participants {
                guard let saved = snapshots[workspaceId] else { continue }
                switch saved {
                case let .niri(snapshot, viewport):
                    niriEngine?.restoreLayoutSnapshot(
                        snapshot,
                        in: workspaceId,
                        arrivals: niriArrivals[workspaceId] ?? []
                    )
                    restoreLiveCrossDisplayViewport(
                        viewport,
                        focused: snapshot.focused,
                        in: workspaceId,
                        states: &states
                    )
                case let .dwindle(snapshot):
                    dwindleEngine?.restoreLayoutSnapshot(
                        snapshot, in: workspaceId, arrivals: dwindleArrivals[workspaceId] ?? [],
                        at: animationClock.now()
                    )
                }
            }
            return moves.map { CrossWorkspaceDropAssignment(token: $0.token, workspaceId: $0.target) }
        }
        if hasStartedServices {
            layoutRefreshController.requestImmediateRelayout(
                reason: .interactiveGesture, affectedWorkspaceIds: Set(participants)
            )
        }
    }

    private func restoreLiveCrossDisplayViewport(
        _ saved: ViewportState,
        focused: WindowToken?,
        in workspaceId: WorkspaceDescriptor.ID,
        states: inout [WorkspaceDescriptor.ID: ViewportState]
    ) {
        guard let engine = niriEngine, var state = states[workspaceId] else { return }
        state.jumpOffset(to: saved.viewOffset)
        state.activeColumnIndex = min(saved.activeColumnIndex, max(0, engine.columns(in: workspaceId).count - 1))
        state.selectedNodeId = focused.flatMap { engine.findNode(for: $0, in: workspaceId)?.id }
        states[workspaceId] = state
    }

    private func liveCrossDisplayParticipants(
        _ snapshots: borrowing [WorkspaceDescriptor.ID: LiveCrossDisplaySnapshot]
    ) -> [WorkspaceDescriptor.ID] {
        var result: [WorkspaceDescriptor.ID] = []
        for index in snapshots.indices {
            let id = snapshots[index].key
            if workspaceManager.descriptor(for: id) != nil,
               workspaceManager.activeLayoutKind(for: id) == snapshots[index].value.layout
            {
                result.append(id)
            }
        }
        return result
    }

    private func liveCrossDisplayHistoryMoves(
        _ snapshots: borrowing [WorkspaceDescriptor.ID: LiveCrossDisplaySnapshot],
        participants: [WorkspaceDescriptor.ID]
    ) -> [LayoutHistoryWindowMove] {
        var moves: [LayoutHistoryWindowMove] = []
        for workspaceId in participants {
            snapshots[workspaceId]?.forEachToken { token in
                guard let current = workspaceManager.workspace(for: token), current != workspaceId,
                      participants.contains(current), workspaceManager.entry(for: token)?.mode == .tiling
                else { return }
                let present = workspaceManager.activeLayoutKind(for: current) == .niri
                    ? niriEngine?.findNode(for: token, in: current) != nil
                    : dwindleEngine?.findNode(for: token, in: current) != nil
                if present { moves.append(LayoutHistoryWindowMove(token: token, source: workspaceId, target: current)) }
            }
        }
        return moves
    }
}
