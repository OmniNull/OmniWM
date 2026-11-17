// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension DwindleLayoutEngine {
    func recordLayoutTransfer(
        from sourceId: WorkspaceDescriptor.ID,
        to targetId: WorkspaceDescriptor.ID,
        sourceBefore: consuming DwindleLayoutSnapshot?,
        targetBefore: consuming DwindleLayoutSnapshot?
    ) {
        assertSanctionedMutation()
        guard sourceId != targetId,
              let sourceBefore = consume sourceBefore, let targetBefore = consume targetBefore,
              let source = existingState(for: sourceId), let target = existingState(for: targetId)
        else { return }
        let departed = transferredHistoryTokens(sourceBefore, from: source, to: target)
        let arrived = transferredHistoryTokens(targetBefore, from: target, to: source)
        guard !departed.isEmpty || !arrived.isEmpty else { return }
        let sourceAway = arrived.isEmpty ? [] : [DwindleLayoutAway(
            workspaceId: targetId, tokens: arrived, snapshot: targetBefore
        )]
        let targetAway = departed.isEmpty ? [] : [DwindleLayoutAway(
            workspaceId: sourceId, tokens: departed, snapshot: sourceBefore
        )]
        source.layoutHistory.record(DwindleLayoutHistoryEntry(
            snapshot: consume sourceBefore, departed: departed, away: sourceAway
        ))
        target.layoutHistory.record(DwindleLayoutHistoryEntry(
            snapshot: consume targetBefore, departed: arrived, away: targetAway
        ))
    }

    private func transferredHistoryTokens(
        _ snapshot: borrowing DwindleLayoutSnapshot,
        from source: DwindleWorkspaceState,
        to target: DwindleWorkspaceState
    ) -> [WindowToken] {
        var result: [WindowToken] = []
        for index in snapshot.members.indices {
            let token = snapshot.members[index].token
            if source.leafByToken[token] == nil, target.leafByToken[token] != nil {
                result.append(token)
            }
        }
        return result
    }

    func hasLayoutTransferHistory(
        _ direction: DwindleLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        existingState(for: workspaceId)?.layoutHistory.hasTransfers(direction) == true
    }

    func takeLayoutTransferHistory(
        _ direction: DwindleLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> DwindleLayoutHistoryEntry? {
        assertSanctionedMutation()
        guard interactiveResize == nil, interactiveMove == nil,
              let state = existingState(for: workspaceId), state.layoutHistory.hasTransfers(direction)
        else { return nil }
        return state.layoutHistory.pop(direction)
    }

    func withLayoutTransferHistory<Result>(
        _ direction: DwindleLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID,
        _ body: (borrowing DwindleLayoutHistoryEntry) -> Result
    ) -> Result? {
        guard let state = existingState(for: workspaceId) else { return nil }
        return state.layoutHistory.withTransferEntry(direction, body)
    }

    func commitTransferredLayoutHistoryStep(
        _ direction: DwindleLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID,
        entry: consuming DwindleLayoutHistoryEntry,
        inverse: consuming DwindleLayoutHistoryEntry,
        arrivals: consuming [DwindleHistoryArrival] = [],
        at time: TimeInterval? = nil
    ) -> DwindleLayoutHistoryStep? {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId) else { return nil }
        restoreLayoutSnapshot(entry.snapshot, in: workspaceId, arrivals: arrivals, at: time)
        guard inverse.hasTransfers || state.preselection != inverse.snapshot.preselection
            || !inverse.snapshot.matches(state.root)
        else { return nil }
        state.layoutHistory.pushOpposite(of: direction, inverse)
        let focused = entry.snapshot.focused.flatMap { state.leafByToken[$0] == nil ? nil : $0 }
        return DwindleLayoutHistoryStep(focused: focused)
    }
}
