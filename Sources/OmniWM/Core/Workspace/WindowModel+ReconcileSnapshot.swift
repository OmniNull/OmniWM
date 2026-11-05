// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WindowModel {
    private struct ReconcileWindowOrder {
        let index: Dictionary<WindowToken, WindowState>.Values.Index
        let workspaceId: WorkspaceDescriptor.ID
        let token: WindowToken
    }

    func reconcileWindowSnapshots() -> [ReconcileWindowSnapshot] {
        let values = entries.values
        var order: [ReconcileWindowOrder] = []
        order.reserveCapacity(values.count)
        for index in values.indices {
            order.append(ReconcileWindowOrder(
                index: index, workspaceId: values[index].workspaceId, token: values[index].token
            ))
        }
        order.sort(by: Self.reconcileWindowPrecedes)

        var snapshots: [ReconcileWindowSnapshot] = []
        snapshots.reserveCapacity(order.count)
        for item in order {
            snapshots.append(ReconcileWindowSnapshot(
                token: item.token,
                workspaceId: item.workspaceId,
                mode: values[item.index].mode,
                lifecyclePhase: values[item.index].lifecyclePhase,
                observedState: values[item.index].observedState,
                desiredState: values[item.index].desiredState,
                restoreWorkspaceId: values[item.index].restoreIntent?.workspaceId,
                lifetimeAuthority: values[item.index].lifetimeAuthority
            ))
        }
        return snapshots
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
