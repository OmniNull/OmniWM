// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension LayoutRefreshController {
    func currentPendingPostLayoutActions() -> [RefreshPostLayoutAction] {
        guard let controller else { return [] }
        return layoutState.pendingRefresh?.postLayoutActions.filter {
            $0.isCurrent(using: controller.workspaceManager)
        } ?? []
    }

    func forwardPendingPostLayoutActions(
        _ currentAtEntry: [RefreshPostLayoutAction],
        by acceptedSeqs: [WorkspaceDescriptor.ID: AcceptedSeq]
    ) {
        guard !currentAtEntry.isEmpty, !acceptedSeqs.isEmpty, let pending = layoutState.pendingRefresh else { return }
        layoutState.pendingRefresh?.postLayoutActions = pending.postLayoutActions.map { action in
            guard currentAtEntry.contains(where: {
                $0.workspaceSeqs == action.workspaceSeqs && $0.domains == action.domains
            }) else { return action }
            return action.forwarded(by: acceptedSeqs, currentAtEntry: Set(action.workspaceSeqs.keys))
        }
    }
}
