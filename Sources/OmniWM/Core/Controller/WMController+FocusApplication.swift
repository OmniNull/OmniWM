// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension WMController {
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

        let focusesWithoutRaise = liveRequest.origin == .focusFollowsMouse
            && !raisesOnMouseFocus(entry)
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
        let raisesWindow = settings.focus.raiseOnMouseFocus
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

    func accordionFocusRaiseOrder(for entry: WindowState) -> [WindowToken] {
        guard workspaceManager.activeLayoutKind(for: entry.workspaceId) == .niri else { return [] }
        return niriEngine?.accordionRaiseOrder(for: entry.token, in: entry.workspaceId) ?? []
    }

    func raisesOnMouseFocus(_ entry: WindowState) -> Bool {
        settings.focus.raiseOnMouseFocus || !accordionFocusRaiseOrder(for: entry).isEmpty
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
        let accordionOrder = accordionFocusRaiseOrder(for: entry)
        for token in accordionOrder.dropLast() {
            guard let sibling = workspaceManager.entry(for: token),
                  canFocusWindow(pid: sibling.pid, windowId: sibling.windowId)
            else { continue }
            windowFocusOperations.raiseWindow(sibling.axRef.element)
        }
        let applied = raisesWindow || !accordionOrder.isEmpty
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
