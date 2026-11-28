// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WorkspaceNavigationHandler {
    private struct WorkspaceTransitionFocusHandoff {
        let focusToken: WindowToken?
        let shouldClearManagedFocus: Bool
    }

    private func resolveWorkspaceTransitionFocusHandoff(
        for workspaceId: WorkspaceDescriptor.ID
    ) -> WorkspaceTransitionFocusHandoff {
        guard let controller else {
            return WorkspaceTransitionFocusHandoff(
                focusToken: nil,
                shouldClearManagedFocus: false
            )
        }
        let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: workspaceId)
        let shouldClearManagedFocus = focusToken == nil && controller.workspaceManager.entries(in: workspaceId).isEmpty
        return WorkspaceTransitionFocusHandoff(
            focusToken: focusToken,
            shouldClearManagedFocus: shouldClearManagedFocus
        )
    }

    func clearManagedFocusAfterEmptyWorkspaceSwitch() {
        guard let controller else { return }
        let canceledRequest = controller.intentLedger.cancelManagedRequest()
        if let canceledRequest {
            _ = controller.workspaceManager.cancelManagedFocusRequest(
                matching: canceledRequest.token,
                workspaceId: canceledRequest.workspaceId,
                requestId: canceledRequest.requestId
            )
            controller.scratchpadStacking.abortScratchpadStacking(matching: canceledRequest.requestId)
            controller.intentLedger.discardPendingFocus(canceledRequest.token)
        }
        _ = controller.workspaceManager.clearNativeFocusOwner()
        controller.windowFocusOperations.activateApp(getpid())
    }

    func commitWorkspaceTransitionFocusHandoff(
        targetWorkspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor?,
        startScrollAnimation: Bool,
        affectedWorkspaces: Set<WorkspaceDescriptor.ID> = [],
        placementSubmitted: LayoutRefreshController.PostLayoutAction? = nil,
        placementInvalidated: LayoutRefreshController.PostLayoutAction? = nil
    ) {
        guard let controller else { return }
        let handoff = resolveWorkspaceTransitionFocusHandoff(for: targetWorkspaceId)
        if let monitor {
            controller.layoutRefreshController.stopScrollAnimation(for: monitor.displayId)
        }
        let newestFocusIntentId = controller.intentLedger.newestFocusIntentId()
        let focusEpochSeq = controller.workspaceManager.worldSeq
        let handoffAction: LayoutRefreshController.PostLayoutAction = { [weak self, weak controller] in
            guard let controller else { return }
            if let focusToken = handoff.focusToken {
                if controller.settings.workspaces.focusNativeFullscreenOnSwitch,
                   let record = controller.workspaceManager.nativeFullscreenRecord(for: focusToken),
                   record.transition == .suspended
                {
                    controller.activateNativeFullscreenPlaceholder(record.originalToken)
                } else {
                    controller.focusWindow(focusToken)
                }
            } else if handoff.shouldClearManagedFocus {
                self?.clearManagedFocusAfterEmptyWorkspaceSwitch()
            }
            if startScrollAnimation {
                controller.layoutRefreshController.startScrollAnimation(for: targetWorkspaceId)
            }
        }
        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: affectedWorkspaces,
            reason: .workspaceTransition,
            postLayout: {
                handoffAction()
                placementSubmitted?()
            },
            postLayoutInvalidated: { [weak controller] in
                placementInvalidated?()
                guard let controller,
                      controller.intentLedger.newestFocusIntentId() == newestFocusIntentId,
                      controller.workspaceManager.isSeqEpochCurrent(focusEpochSeq, domains: .focus)
                else { return }
                handoffAction()
            }
        )
    }
}
