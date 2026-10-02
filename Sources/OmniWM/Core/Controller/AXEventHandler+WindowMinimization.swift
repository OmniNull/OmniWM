// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation

extension AXEventHandler {
    func handleWindowMinimized(pid: pid_t, axRef: AXWindowRef, minimized: Bool) {
        guard let controller else { return }
        let token = canonicalObservedWindowToken(pid: pid, axRef: axRef)
        guard let entry = controller.workspaceManager.entry(for: token) else {
            if minimized {
                controller.workspaceManager.clearExternalFocusIdentity(matching: token)
            }
            if controller.layoutRefreshController.layoutState.activeFullEnumerationCount > 0 {
                controller.workspaceManager.noteInvalidation(workspaceId: nil, domains: .layout)
                requestTargetedFullRescan(for: [pid])
            }
            return
        }
        guard CFEqual(entry.axRef.element, axRef.element) else { return }
        updateWindowMinimizedState(minimized, token: token)
        if !minimized, frontmostApplicationPIDProvider() == pid {
            handleAppActivation(pid: pid, source: .focusedWindowChanged)
        }
    }

    @discardableResult
    func updateWindowMinimizedState(
        _ minimized: Bool,
        token: WindowToken,
        source: WMEventSource = .ax,
        requestRefresh: Bool = true
    ) -> Bool {
        guard let controller,
              controller.workspaceManager.setWindowMinimized(minimized, token: token, source: source)
        else { return false }
        refreshWindowNativeSuppression(
            token: token,
            reason: minimized ? .windowMinimized : .windowDeminiaturized,
            requestRefresh: requestRefresh
        )
        return true
    }

    @discardableResult
    func updateWindowNativeWithdrawalState(
        _ withdrawn: Bool,
        token: WindowToken,
        source: WMEventSource = .ax,
        requestRefresh: Bool = true
    ) -> Bool {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: token),
              !withdrawn || (!controller.workspaceManager.isAppHidden(token)
                  && !entry.observedState.isMinimized && !entry.observedState.isNativeFullscreen),
              controller.workspaceManager.setWindowNativeWithdrawn(withdrawn, token: token, source: source)
        else { return false }
        refreshWindowNativeSuppression(
            token: token,
            reason: withdrawn ? .windowWithdrawn : .windowReopened,
            requestRefresh: requestRefresh
        )
        return true
    }

    private func refreshWindowNativeSuppression(
        token: WindowToken,
        reason: RefreshReason,
        requestRefresh: Bool
    ) {
        guard let controller, let entry = controller.workspaceManager.entry(for: token) else { return }
        let suppressed = entry.observedState.isNativeSuppressed
        if suppressed {
            controller.layoutRefreshController.cancelPendingScratchpadReveal(for: token)
            controller.dwindleLayoutHandler.groupReveals.cancelPendingGroupReveal(for: token)
            if let request = controller.intentLedger.activeManagedRequest, request.token == token {
                _ = controller.cancelManagedFocusRequest(request)
            }
            controller.intentLedger.discardPendingFocus(token)
            controller.layoutRefreshController.cancelActiveAnimations(for: entry.workspaceId)
        }
        controller.axManager.setWindowNativeSuppressed(suppressed, token: token)
        controller.mouseEventHandler.handleAppVisibilityChanged()
        controller.windowActionHandler.refreshOverviewProjection(affectedWorkspaceIds: [entry.workspaceId])
        if requestRefresh {
            controller.layoutRefreshController.requestVisibilityRefresh(
                reason: reason,
                affectedWorkspaceIds: [entry.workspaceId]
            )
        }
        controller.surfaceReconciler.noteWorldChanged()
        controller.windowSwitcherControllerStorage?.refreshWindows()
    }
}
