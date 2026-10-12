// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension WMController {
    @discardableResult
    func focusWindow(
        _ token: WindowToken,
        origin: ManagedFocusOrigin = .keyboardOrProgrammatic,
        raisesWindow: Bool = true,
        defersRetryRaise: Bool = false,
        requiresWorkerRaise: Bool = false
    ) -> ManagedFocusRequest? {
        guard let entry = focusableEntry(for: token, origin: origin) else { return nil }
        let handoff = prepareFocusHandoff(for: token)
        let requiresWorkerRaise = requiresWorkerRaise && !raisesWindow
        let request = publishManagedFocusRequest(
            entry, origin: origin, defersRetryRaise: defersRetryRaise,
            requiresWorkerRaise: requiresWorkerRaise
        )

        let applied = applyManagedFocusRequest(
            request,
            entry: entry,
            validatesPointer: false,
            preferredSameAppSourceToken: handoff.preferredSourceToken,
            raisesWindow: raisesWindow
        )
        settleFocusHandoff(handoff, request: request, applied: applied)
        if applied,
           requiresWorkerRaise || (defersRetryRaise
               && (handoff.preferredSourceToken ?? workspaceManager.renderableFocusToken)?.pid == token.pid)
        {
            dispatchRetryRaise(for: request, refronting: false)
        }
        windowFocusOperations.afterSubmittedFocus { [weak self] in
            guard let self,
                  intentLedger.activeManagedRequest(requestId: request.requestId)?.phase == .awaitingConfirmation
            else { return }
            axEventHandler.probeFocusedWindowAfterFronting(
                expectedToken: request.token,
                workspaceId: request.workspaceId
            )
        }
        return request
    }

    private func deferInactiveDwindleGroupFocus(
        _ entry: WindowState,
        origin: ManagedFocusOrigin
    ) -> Bool {
        let workspaceId = entry.workspaceId
        guard entry.mode == .tiling,
              entry.layoutReason == .standard,
              workspaceManager.activeLayoutKind(for: workspaceId) == .dwindle,
              let monitorId = workspaceManager.monitorId(for: workspaceId),
              workspaceManager.activeWorkspace(on: monitorId)?.id == workspaceId,
              let snapshot = dwindleEngine?.tileSnapshot(for: entry.token, in: workspaceId),
              snapshot.members.count > 1,
              snapshot.activeToken != entry.token
        else {
            return false
        }

        if let activeRequest = intentLedger.activeManagedRequest {
            _ = cancelManagedFocusRequest(activeRequest)
        }
        return dwindleLayoutHandler.activateWindow(
            entry.token,
            in: workspaceId,
            origin: origin
        ) == .activated
    }

    func focusWindow(_ handle: WindowHandle) {
        focusWindow(handle.id)
    }

    private func focusableEntry(for token: WindowToken, origin: ManagedFocusOrigin) -> WindowState? {
        guard origin != .focusFollowsMouse || focusFollowsMouseEnabled else { return nil }
        if origin == .focusFollowsMouse,
           mouseEventHandler.hasLatestFocusFollowsMouseSample,
           mouseEventHandler.latestFocusFollowsMouseToken() != token
        {
            return nil
        }
        guard let entry = workspaceManager.entry(for: token) else { return nil }
        guard !isLockScreenActive else { return nil }
        if hasStartedServices {
            guard !isFrontmostAppLockScreen() else { return nil }
        }
        if isManagedWindowSuppressedByMacOS(token) {
            return nil
        }
        if isManagedWindowSuspendedForNativeFullscreen(token) {
            if workspaceManager.showsNativeFullscreenPlaceholder(for: token) {
                selectNativeFullscreenPlaceholder(entry)
            }
            return nil
        }
        if deferInactiveDwindleGroupFocus(entry, origin: origin) {
            return nil
        }

        return entry
    }

    private func prepareFocusHandoff(for token: WindowToken) -> FocusHandoffSelection {
        var promotedHandoffSourceToken: WindowToken?
        var supersededHandoff: (request: ManagedFocusRequest, sourceToken: WindowToken)?
        var preferredSameAppSourceToken: WindowToken?
        if let activeRequest = intentLedger.activeManagedRequest {
            switch activeRequest.phase {
            case let .awaitingSameAppActivation(sourceToken, _):
                if activeRequest.token == token {
                    promotedHandoffSourceToken = sourceToken
                } else if let canceledRequest = cancelManagedFocusRequest(activeRequest) {
                    supersededHandoff = (canceledRequest, sourceToken)
                }
            case .awaitingConfirmation:
                if activeRequest.token != token, activeRequest.token.pid == token.pid {
                    preferredSameAppSourceToken = activeRequest.token
                }
            }
        }
        return FocusHandoffSelection(
            promotedSourceToken: promotedHandoffSourceToken,
            superseded: supersededHandoff,
            preferredSourceToken: preferredSameAppSourceToken
        )
    }

    private func publishManagedFocusRequest(
        _ entry: WindowState,
        origin: ManagedFocusOrigin,
        defersRetryRaise: Bool,
        requiresWorkerRaise: Bool
    ) -> ManagedFocusRequest {
        let previousRequestId = intentLedger.activeManagedRequest?.requestId
        let request = intentLedger.beginManagedRequest(
            token: entry.token,
            workspaceId: entry.workspaceId,
            origin: origin
        )
        if defersRetryRaise || requiresWorkerRaise {
            intentLedger.enableDeferredRetryRaise(for: request, required: requiresWorkerRaise)
        }
        if let previousRequestId {
            scratchpadStacking.abortScratchpadStacking(matching: previousRequestId)
        }
        _ = workspaceManager.beginManagedFocusRequest(
            request.token,
            in: request.workspaceId,
            onMonitor: workspaceManager.monitorId(for: request.workspaceId),
            requestId: request.requestId
        )
        recordNiriCreateFocusTrace(
            .pendingFocusStarted(
                requestId: request.requestId,
                token: request.token,
                workspaceId: request.workspaceId
            )
        )

        return request
    }

    private func settleFocusHandoff(_ handoff: FocusHandoffSelection, request: ManagedFocusRequest, applied: Bool) {
        if let promotedHandoffSourceToken = handoff.promotedSourceToken,
           request.origin != .focusFollowsMouse,
           !applied
        {
            cancelManagedFocusRequestAndRestoreSource(
                request,
                sourceToken: promotedHandoffSourceToken
            )
        }
        let replacementIsStaged: Bool
        if case .some(.awaitingSameAppActivation) = intentLedger.activeManagedRequest(
            requestId: request.requestId
        )?.phase {
            replacementIsStaged = true
        } else {
            replacementIsStaged = false
        }
        if let supersededHandoff = handoff.superseded, !applied, !replacementIsStaged {
            cancelManagedFocusRequest(request)
            restoreSameAppFocusSource(
                supersededHandoff.sourceToken,
                canceledRequest: supersededHandoff.request
            )
        }
    }

    private struct FocusHandoffSelection {
        let promotedSourceToken: WindowToken?
        let superseded: (request: ManagedFocusRequest, sourceToken: WindowToken)?
        let preferredSourceToken: WindowToken?
    }
}
