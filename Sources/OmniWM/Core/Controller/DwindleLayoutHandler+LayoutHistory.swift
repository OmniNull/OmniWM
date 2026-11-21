// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension DwindleLayoutHandler {
    @discardableResult
    func stepLayoutHistory(
        _ direction: DwindleLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller,
              let engine = controller.dwindleEngine,
              controller.workspaceManager.activeLayoutKind(for: workspaceId) == .dwindle,
              let monitor = controller.workspaceManager.monitor(for: workspaceId),
              engine.interactiveResize == nil, engine.interactiveMove == nil
        else { return false }
        return controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            applyResolvedSettings(controller.resolvedDwindleSettings(for: monitor), to: engine)
            let focusedBefore = engine.projectedActiveToken(in: workspaceId)
            guard let step = engine.stepLayoutHistory(direction, in: workspaceId)
                ?? stepLayoutHistoryAcrossWorkspaces(direction, in: workspaceId, engine: engine, controller: controller)
            else { return false }
            recordLayoutOperation(.windowsSwapped, in: workspaceId)
            if let token = step.focused, token != focusedBefore,
               groupMemberActivationIsAllowed(token, workspaceId: workspaceId)
            {
                commitGroupSelection(token, workspaceId: workspaceId, focusAfterLayout: true)
            } else {
                controller.layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: [workspaceId])
            }
            return true
        }
    }
}
