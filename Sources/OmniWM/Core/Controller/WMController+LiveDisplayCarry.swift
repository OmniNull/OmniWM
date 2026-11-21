// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WMController {
    func finishLiveDragAcrossDisplays(
        token: WindowToken,
        carrying tokens: [WindowToken],
        from source: WorkspaceDescriptor.ID,
        to target: WorkspaceDescriptor.ID
    ) {
        for carried in tokens {
            workspaceManager.recordLayoutOperation(
                .windowMovedToWorkspace(token: carried, to: target),
                in: source,
                source: .mouse
            )
            workspaceManager.recordLayoutOperation(.windowInserted(token: carried), in: target, source: .mouse)
        }
        recoverSourceFocusAfterMove(
            in: source,
            preferredNodeId: workspaceManager.niriViewportState(for: source).selectedNodeId
        )
        workspaceNavigationHandler.applySessionPatch(workspaceId: target, rememberedFocusToken: token)
        guard let handle = workspaceManager.handle(for: token) else { return }
        workspaceNavigationHandler.finishWorkspaceMove(
            StructuralMutation(
                sourceWorkspaceId: source,
                destinationWorkspaceId: target,
                selectedHandle: handle,
                scrollWorkspaceId: nil
            ),
            focusPolicy: .configured,
            focusOrigin: .pointerSelection
        )
    }
}
