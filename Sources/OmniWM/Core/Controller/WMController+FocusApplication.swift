// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension WMController {
    func shouldRaiseManagedFocus(origin: ManagedFocusOrigin, entry: borrowing WindowState) -> Bool {
        guard origin == .focusFollowsMouse else { return true }
        guard settings.focus.raiseOnMouseFocus else { return false }
        guard entry.mode == .tiling, let windowId = UInt32(exactly: entry.windowId) else { return true }
        var candidates: Set<UInt32> = []
        for workspaceId in workspaceManager.visibleWorkspaceIds() {
            workspaceManager.windowQueries.forEachWindow(in: workspaceId, mode: .floating) { floatingEntry in
                if workspaceManager.isFloatingWindowDisplayable(floatingEntry),
                   let floatingId = UInt32(exactly: floatingEntry.windowId)
                {
                    candidates.insert(floatingId)
                }
            }
        }
        guard !candidates.isEmpty else { return true }
        return windowFocusOperations.hasOverlappingWindowsAbove(windowId, candidates) != true
    }

    @discardableResult
    func applyManagedFocusRequest(
        _ request: ManagedFocusRequest,
        entry: WindowState,
        validatesPointer: Bool,
        isRetry: Bool = false,
        preferredSameAppSourceToken: WindowToken? = nil,
        raisesWindow: Bool = true
    ) -> Bool {
        guard let liveRequest = intentLedger.activeManagedRequest(requestId: request.requestId),
              liveRequest.token == entry.token,
              liveRequest.workspaceId == entry.workspaceId,
              workspaceManager.pendingManagedFocusMatches(
                  token: liveRequest.token,
                  workspaceId: liveRequest.workspaceId,
                  requestId: liveRequest.requestId
              )
        else {
            return false
        }

        guard validateMouseFocusRequest(liveRequest, validatesPointer: validatesPointer) else { return false }

        let focusesWithoutRaise = !shouldRaiseManagedFocus(origin: liveRequest.origin, entry: entry)
        guard focusesWithoutRaise else {
            return frontManagedFocusRequest(liveRequest, entry: entry, raisesWindow: raisesWindow)
        }
        guard canFocusWindow(pid: entry.pid, windowId: entry.windowId) else {
            cancelManagedFocusRequestAndRestoreSource(liveRequest)
            return false
        }
        if case .awaitingSameAppActivation = liveRequest.phase {
            return false
        }
        if let sourceToken = preferredSameAppSourceToken ?? workspaceManager.renderableFocusToken,
           sourceToken != liveRequest.token,
           sourceToken.pid == liveRequest.token.pid,
           let sourceEntry = workspaceManager.entry(for: sourceToken),
           sourceEntry.pid == entry.pid,
           isManagedWindowDisplayable(sourceToken),
           let sourceWindowId = UInt32(exactly: sourceEntry.windowId)
        {
            guard let stagedRequest = intentLedger.beginSameAppActivationHandoff(
                requestId: liveRequest.requestId,
                sourceToken: sourceToken,
                isRetry: isRetry
            ) else {
                return false
            }
            guard windowFocusOperations.deactivateSameAppWindow(entry.pid, sourceWindowId) else {
                cancelManagedFocusRequest(stagedRequest)
                return false
            }
            return false
        }
        return performWindowFocusOnly(
            pid: entry.pid,
            windowId: entry.windowId,
            axRef: entry.axRef
        )
    }

    func completeSameAppFocusHandoff(_ request: ManagedFocusRequest) {
        guard let liveRequest = intentLedger.activeManagedRequest(requestId: request.requestId),
              liveRequest.token == request.token,
              case let .awaitingSameAppActivation(sourceToken, isRetry) = liveRequest.phase,
              let entry = workspaceManager.entry(for: liveRequest.token),
              entry.workspaceId == liveRequest.workspaceId,
              workspaceManager.pendingManagedFocusMatches(
                  token: liveRequest.token,
                  workspaceId: liveRequest.workspaceId,
                  requestId: liveRequest.requestId
              )
        else {
            return
        }
        guard focusFollowsMouseEnabled,
              !mouseEventHandler.hasLatestFocusFollowsMouseSample
              || mouseEventHandler.latestFocusFollowsMouseToken() == liveRequest.token,
              focusPolicyEngine.evaluate(.focusFollowsMouse).allowsFocusChange,
              canFocusWindow(pid: entry.pid, windowId: entry.windowId)
        else {
            cancelManagedFocusRequestAndRestoreSource(
                liveRequest,
                sourceToken: sourceToken
            )
            return
        }
        let raisesWindow = shouldRaiseManagedFocus(origin: liveRequest.origin, entry: entry)
        if raisesWindow {
            windowFocusOperations.activateApp(entry.pid)
        }
        guard windowFocusOperations.activateAndFocusSameAppWindow(
            entry.pid,
            UInt32(entry.windowId),
            entry.axRef.element
        ) else {
            cancelManagedFocusRequestAndRestoreSource(
                liveRequest,
                sourceToken: sourceToken
            )
            return
        }
        if raisesWindow {
            windowFocusOperations.raiseWindow(entry.axRef.element)
        }
        confirmSameAppFocusHandoff(liveRequest, sourceToken: sourceToken, isRetry: isRetry)
    }

    private func validateMouseFocusRequest(_ liveRequest: ManagedFocusRequest, validatesPointer: Bool) -> Bool {
        if liveRequest.origin == .focusFollowsMouse {
            guard focusFollowsMouseEnabled else {
                cancelManagedFocusRequestAndRestoreSource(liveRequest)
                return false
            }
            if validatesPointer,
               mouseEventHandler.hasLatestFocusFollowsMouseSample,
               mouseEventHandler.latestFocusFollowsMouseToken() != liveRequest.token
            {
                cancelManagedFocusRequestAndRestoreSource(liveRequest)
                return false
            }
            guard focusPolicyEngine.evaluate(.focusFollowsMouse).allowsFocusChange else {
                cancelManagedFocusRequestAndRestoreSource(liveRequest)
                return false
            }
        }

        return true
    }

    private func frontManagedFocusRequest(
        _ liveRequest: ManagedFocusRequest,
        entry: WindowState,
        raisesWindow: Bool
    ) -> Bool {
        let applied = raisesWindow
            ? performWindowFronting(pid: entry.pid, windowId: entry.windowId, axRef: entry.axRef)
            : submitWindowFocus(pid: entry.pid, windowId: entry.windowId, axRef: entry.axRef)
        if applied, case .awaitingSameAppActivation = liveRequest.phase {
            _ = intentLedger.completeSameAppActivationHandoff(
                requestId: liveRequest.requestId
            )
        } else if !applied,
                  case let .awaitingSameAppActivation(sourceToken, _) = liveRequest.phase
        {
            cancelManagedFocusRequestAndRestoreSource(
                liveRequest,
                sourceToken: sourceToken
            )
        } else if !applied, liveRequest.origin == .focusFollowsMouse {
            cancelManagedFocusRequest(liveRequest)
        }
        return applied
    }

    private func confirmSameAppFocusHandoff(
        _ liveRequest: ManagedFocusRequest,
        sourceToken: WindowToken,
        isRetry: Bool
    ) {
        guard let confirmationRequest = intentLedger.completeSameAppActivationHandoff(
            requestId: liveRequest.requestId
        ) else {
            cancelManagedFocusRequestAndRestoreSource(
                liveRequest,
                sourceToken: sourceToken
            )
            return
        }
        if isRetry {
            _ = axEventHandler.handleAppActivation(
                pid: confirmationRequest.token.pid,
                source: confirmationRequest.lastActivationSource ?? .focusedWindowChanged,
                origin: .retry
            )
        } else {
            axEventHandler.probeFocusedWindowAfterFronting(
                expectedToken: confirmationRequest.token,
                workspaceId: confirmationRequest.workspaceId
            )
        }
    }
}
