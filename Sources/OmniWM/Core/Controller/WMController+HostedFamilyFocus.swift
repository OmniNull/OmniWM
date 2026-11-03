// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WMController {
    func retargetHostedChildFocus(afterMoving parent: WindowToken, to workspace: WorkspaceDescriptor.ID) {
        guard let request = intentLedger.activeManagedRequest, request.token != parent,
              request.workspaceId != workspace,
              workspaceManager.hostedFamilyRoot(for: request.token) == parent,
              workspaceManager.workspace(for: parent) == workspace,
              workspaceManager.workspace(for: request.token) == workspace,
              workspaceManager.pendingFocusedToken == nil || workspaceManager.pendingFocusedToken == request.token,
              let retargeted = intentLedger.retargetManagedRequest(
                  requestId: request.requestId, token: request.token, to: workspace
              ) else { return }
        _ = workspaceManager.beginManagedFocusRequest(
            retargeted.token, in: workspace, onMonitor: workspaceManager.monitorId(for: workspace),
            requestId: retargeted.requestId
        )
    }
}
