// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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
        guard let axRef = entry.axRef else {
            return focusHostedWindow(entry, request: liveRequest, raisesWindow: !focusesWithoutRaise)
        }
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
        return performWindowFocusOnly(pid: entry.pid, windowId: entry.windowId, axRef: axRef)
    }

    private func focusHostedWindow(
        _ entry: WindowState,
        request: ManagedFocusRequest,
        raisesWindow: Bool
    ) -> Bool {
        guard canFocusWindow(pid: entry.pid, windowId: entry.windowId) else {
            cancelManagedFocusRequestAndRestoreSource(request)
            return false
        }
        return shellAppWindowManager.focus(entry.token, raisesWindow: raisesWindow)
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
              focusFollowsMouseAllowsFocus(on: liveRequest.token, validatesPointer: true),
              canFocusWindow(pid: entry.pid, windowId: entry.windowId)
        else {
            cancelManagedFocusRequestAndRestoreSource(
                liveRequest,
                sourceToken: sourceToken
            )
            return
        }
        let raisesWindow = shouldRaiseManagedFocus(origin: liveRequest.origin, entry: entry)
        guard let axRef = entry.axRef else {
            _ = shellAppWindowManager.focus(entry.token, raisesWindow: raisesWindow)
            return
        }
        if raisesWindow {
            windowFocusOperations.activateApp(entry.pid)
        }
        guard windowFocusOperations.activateAndFocusSameAppWindow(
            entry.pid,
            UInt32(entry.windowId),
            axRef.element
        ) else {
            cancelManagedFocusRequestAndRestoreSource(
                liveRequest,
                sourceToken: sourceToken
            )
            return
        }
        if raisesWindow {
            windowFocusOperations.raiseWindow(axRef.element)
        }
        confirmSameAppFocusHandoff(liveRequest, sourceToken: sourceToken, isRetry: isRetry)
    }

    private func validateMouseFocusRequest(_ liveRequest: ManagedFocusRequest, validatesPointer: Bool) -> Bool {
        guard liveRequest.origin == .focusFollowsMouse else { return true }
        guard focusFollowsMouseEnabled,
              focusFollowsMouseAllowsFocus(on: liveRequest.token, validatesPointer: validatesPointer)
        else {
            cancelManagedFocusRequestAndRestoreSource(liveRequest)
            return false
        }
        return true
    }

    private func focusFollowsMouseAllowsFocus(on token: WindowToken, validatesPointer: Bool) -> Bool {
        guard validatesPointer, mouseEventHandler.hasLatestFocusFollowsMouseSample else {
            return focusPolicyEngine.evaluate(.focusFollowsMouse).allowsFocusChange
        }
        return mouseEventHandler.latestFocusFollowsMouseToken() == token
    }

    private func frontManagedFocusRequest(
        _ liveRequest: ManagedFocusRequest,
        entry: WindowState,
        raisesWindow: Bool
    ) -> Bool {
        guard let axRef = entry.axRef else { return shellAppWindowManager.focus(entry.token) }
        let applied = raisesWindow
            ? performWindowFronting(pid: entry.pid, windowId: entry.windowId, axRef: axRef)
            : submitWindowFocus(pid: entry.pid, windowId: entry.windowId, axRef: axRef)
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
