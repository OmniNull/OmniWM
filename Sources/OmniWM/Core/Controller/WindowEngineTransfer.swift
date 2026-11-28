// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor
struct WindowEngineTransfer {
    let token: WindowToken
    let sourceWorkspaceId: WorkspaceDescriptor.ID?
    let targetWorkspaceId: WorkspaceDescriptor.ID
    let placement: NiriColumnPlacement?
    let sourceIsDwindle: Bool
    let targetIsDwindle: Bool

    init(
        token: WindowToken,
        sourceWorkspaceId sourceWsId: WorkspaceDescriptor.ID?,
        targetWorkspaceId targetWsId: WorkspaceDescriptor.ID,
        placement: NiriColumnPlacement? = nil,
        controller: WMController
    ) {
        self.token = token
        sourceWorkspaceId = sourceWsId
        targetWorkspaceId = targetWsId
        self.placement = placement
        let sourceLayout: LayoutType = sourceWsId
            .flatMap { controller.workspaceManager.descriptor(for: $0)?.name }
            .map { controller.settings.workspaces.layoutType(for: $0) } ?? .defaultLayout
        let targetLayout: LayoutType = controller.workspaceManager.descriptor(for: targetWsId)
            .map { controller.settings.workspaces.layoutType(for: $0.name) } ?? .defaultLayout
        self.sourceIsDwindle = sourceLayout == .dwindle
        self.targetIsDwindle = targetLayout == .dwindle
    }
}

struct WindowEngineTransferProgress {
    var newSourceFocusToken: WindowToken?
    var movedWithNiri = false
}
