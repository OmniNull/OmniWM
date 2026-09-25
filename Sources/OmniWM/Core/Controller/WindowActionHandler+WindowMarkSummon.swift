// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum WindowSummonRightOutcome: Equatable {
    case summoned
    case movedToWorkspace
    case moveFailed
    case noAnchor
    case selfSummon
    case hiddenTarget
    case staleTarget
    case unsupportedLayout
    case actionFailed
}

extension WindowActionHandler {
    func summonWindowRightOutcome(handle: WindowHandle) -> WindowSummonRightOutcome {
        guard let controller,
              let workspace = controller.activeWorkspace(),
              let anchorToken = controller.workspaceManager.selectedManagedToken,
              let anchorEntry = controller.workspaceManager.entry(for: anchorToken),
              anchorEntry.workspaceId == workspace.id,
              controller.workspaceManager.handle(for: anchorToken) != nil,
              !controller.workspaceManager.isAppHidden(pid: anchorEntry.pid)
        else {
            return .noAnchor
        }
        return summonWindowRightOutcome(
            handle: handle,
            anchorToken: anchorToken,
            anchorWorkspaceId: workspace.id
        )
    }

    func summonWindowRightOutcome(
        handle: WindowHandle,
        anchorToken: WindowToken,
        anchorWorkspaceId: WorkspaceDescriptor.ID
    ) -> WindowSummonRightOutcome {
        guard let controller,
              let anchorEntry = controller.workspaceManager.entry(for: anchorToken),
              anchorEntry.workspaceId == anchorWorkspaceId,
              controller.workspaceManager.handle(for: anchorToken) != nil
        else {
            return .noAnchor
        }
        guard !controller.workspaceManager.isAppHidden(pid: anchorEntry.pid) else { return .noAnchor }

        guard let targetEntry = controller.workspaceManager.entry(for: handle.id),
              let liveHandle = controller.workspaceManager.handle(for: handle.id),
              liveHandle === handle
        else {
            return .staleTarget
        }
        guard !controller.workspaceManager.isAppHidden(pid: targetEntry.pid) else { return .hiddenTarget }
        guard handle.id != anchorToken else { return .selfSummon }

        let supportsSummon: (WorkspaceDescriptor.ID) -> Bool = { workspaceId in
            guard let workspaceName = controller.workspaceManager.descriptor(for: workspaceId)?.name else {
                return false
            }
            switch controller.settings.workspaces.layoutType(for: workspaceName) {
            case .dwindle:
                return controller.dwindleEngine != nil
            case .niri,
                 .defaultLayout:
                return controller.niriEngine != nil
            }
        }
        guard supportsSummon(targetEntry.workspaceId), supportsSummon(anchorWorkspaceId) else {
            return .unsupportedLayout
        }

        return summonWindowRight(
            handle: liveHandle,
            anchorToken: anchorToken,
            anchorWorkspaceId: anchorWorkspaceId
        ) ? .summoned : .actionFailed
    }
}
