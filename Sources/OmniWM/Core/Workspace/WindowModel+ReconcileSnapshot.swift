// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WindowModel {
    private struct ReconcileWindowOrder {
        let index: EntryIndex
        let workspaceId: WorkspaceDescriptor.ID
        let token: WindowToken
    }

    func reconcileWindowSnapshots() -> [ReconcileWindowSnapshot] {
        var order: [ReconcileWindowOrder] = []
        do {
            let values = entries.values
            order.reserveCapacity(values.count)
            for index in values.indices {
                order.append(ReconcileWindowOrder(
                    index: index, workspaceId: values[index].workspaceId, token: values[index].token
                ))
            }
        }
        order.sort(by: Self.reconcileWindowPrecedes)

        var snapshots: [ReconcileWindowSnapshot] = []
        snapshots.reserveCapacity(order.count)
        for item in order {
            snapshots.append(withEntry(at: item.index) { Self.reconcileWindowSnapshot(of: $0, order: item) })
        }
        return snapshots
    }

    private static func reconcileWindowSnapshot(
        of entry: borrowing WindowState,
        order: ReconcileWindowOrder
    ) -> ReconcileWindowSnapshot {
        ReconcileWindowSnapshot(
            token: order.token,
            workspaceId: order.workspaceId,
            mode: entry.mode,
            lifecyclePhase: entry.lifecyclePhase,
            observedState: entry.observedState,
            desiredState: entry.desiredState,
            restoreWorkspaceId: entry.restoreIntent?.workspaceId,
            lifetimeAuthority: entry.lifetimeAuthority
        )
    }

    private nonisolated static func reconcileWindowPrecedes(
        _ lhs: ReconcileWindowOrder,
        _ rhs: ReconcileWindowOrder
    ) -> Bool {
        lhs.workspaceId == rhs.workspaceId
            ? (lhs.token.pid == rhs.token.pid
                ? lhs.token.windowId < rhs.token.windowId
                : lhs.token.pid < rhs.token.pid)
            : lhs.workspaceId < rhs.workspaceId
    }
}
