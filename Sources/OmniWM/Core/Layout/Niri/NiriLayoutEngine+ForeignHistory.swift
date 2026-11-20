// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension NiriLayoutEngine {
    func hasForeignLayoutHistory(
        _ direction: NiriLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        states[workspaceId]?.layoutHistory.hasForeignEntry(direction) == true
    }

    func withForeignLayoutHistory<Result>(
        _ direction: NiriLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID,
        _ body: (borrowing NiriLayoutSnapshot) -> Result
    ) -> Result? {
        guard let workspace = states[workspaceId] else { return nil }
        return workspace.layoutHistory.withForeignEntry(direction, body)
    }

    func takeForeignLayoutHistory(
        _ direction: NiriLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriLayoutSnapshot? {
        assertSanctionedMutation()
        guard interactiveResize == nil, liveColumnMove == nil, !isLiveStackDropPending(in: workspaceId),
              let workspace = states[workspaceId], workspace.layoutHistory.hasForeignEntry(direction)
        else { return nil }
        return workspace.layoutHistory.pop(direction)
    }

    func recordForeignLayoutHistory(entry: consuming NiriLayoutSnapshot, in workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        ensureState(for: workspaceId).layoutHistory.recordForeign(entry)
    }

    func commitForeignLayoutHistoryStep(
        _ direction: NiriLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID,
        entry: consuming NiriLayoutSnapshot,
        inverse: consuming NiriLayoutSnapshot,
        arrivals: borrowing [NiriWindow] = []
    ) -> NiriLayoutHistoryStep? {
        assertSanctionedMutation()
        let workspace = ensureState(for: workspaceId)
        let transferred = hasForeignHistoryTransfers(inverse)
        restoreLayoutSnapshot(entry, in: workspaceId, arrivals: arrivals)
        if !transferred {
            guard let restored = layoutSnapshot(in: workspaceId, focused: nil),
                  !restored.hasSameLayout(as: inverse)
            else { return nil }
        }
        workspace.layoutHistory.pushForeign(inverse, onto: direction == .undo ? .redo : .undo)
        let focused = entry.focused.flatMap { workspace.nodesByToken[$0] == nil ? nil : $0 }
        return NiriLayoutHistoryStep(focused: focused)
    }

    private func hasForeignHistoryTransfers(_ snapshot: borrowing NiriLayoutSnapshot) -> Bool {
        if !snapshot.away.isEmpty { return true }
        guard let transfer = snapshot.foreignTransfer else { return false }
        return !transfer.departed.isEmpty || !transfer.away.isEmpty
    }
}
