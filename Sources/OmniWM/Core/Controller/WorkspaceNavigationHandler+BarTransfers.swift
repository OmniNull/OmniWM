// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension WorkspaceNavigationHandler {
    @discardableResult
    func moveWindowsFromBar(
        _ tokens: [WindowToken],
        toWorkspaceId targetWorkspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller else { return false }
        let selectedToken = controller.workspaceManager.selectedManagedToken
        var mutations: [StructuralMutation] = []
        for token in tokens {
            guard let handle = controller.workspaceManager.handle(for: token),
                  let mutation = moveWindow(handle: handle, toWorkspaceId: targetWorkspaceId).mutation
            else {
                continue
            }
            mutations.append(mutation)
        }
        guard let first = mutations.first else { return false }
        let movedSelection = mutations.first { $0.selectedHandle.id == selectedToken }
        let selected = movedSelection ?? first
        let followsMove = movedSelection != nil || controller.settings.focus.followsWindowToMonitor
        finishWorkspaceMove(
            StructuralMutation(
                sourceWorkspaceId: first.sourceWorkspaceId,
                destinationWorkspaceId: targetWorkspaceId,
                selectedHandle: selected.selectedHandle,
                movedTokens: mutations.flatMap(\.movedTokens),
                scrollWorkspaceId: mutations.lazy.compactMap(\.scrollWorkspaceId).first
            ),
            focusPolicy: followsMove ? .configured : .retainCurrent,
            focusOrigin: .pointerSelection
        )
        return true
    }

    @discardableResult
    func moveFocusedWindowFromBar(toWorkspaceId targetWorkspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let token = controller?.workspaceManager.selectedManagedToken else { return false }
        return moveWindowsFromBar([token], toWorkspaceId: targetWorkspaceId)
    }
}
