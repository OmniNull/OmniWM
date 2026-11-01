// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension WMController {
    @discardableResult
    func cancelManagedFocusRequest(_ request: ManagedFocusRequest) -> ManagedFocusRequest? {
        cancelManagedFocusRequest(request, restoringSameAppSource: nil)
    }

    @discardableResult
    func cancelManagedFocusRequestAndRestoreSource(
        _ request: ManagedFocusRequest,
        sourceToken: WindowToken? = nil
    ) -> ManagedFocusRequest? {
        let resolvedSourceToken: WindowToken? = if let sourceToken {
            sourceToken
        } else if case let .awaitingSameAppActivation(sourceToken, _) = request.phase {
            sourceToken
        } else {
            nil
        }
        return cancelManagedFocusRequest(
            request,
            restoringSameAppSource: resolvedSourceToken
        )
    }

    @discardableResult
    private func cancelManagedFocusRequest(
        _ request: ManagedFocusRequest,
        restoringSameAppSource sourceToken: WindowToken?
    ) -> ManagedFocusRequest? {
        guard let liveRequest = intentLedger.activeManagedRequest(requestId: request.requestId),
              liveRequest.token == request.token,
              liveRequest.workspaceId == request.workspaceId,
              let canceledRequest = intentLedger.cancelManagedRequest(requestId: request.requestId)
        else {
            return nil
        }
        _ = workspaceManager.cancelManagedFocusRequest(
            matching: canceledRequest.token,
            workspaceId: canceledRequest.workspaceId,
            requestId: canceledRequest.requestId
        )
        scratchpadStacking.abortScratchpadStacking(matching: canceledRequest.requestId)
        if let sourceToken {
            restoreSameAppFocusSource(sourceToken, canceledRequest: canceledRequest)
        }
        return canceledRequest
    }

    func restoreSameAppFocusSource(
        _ sourceToken: WindowToken,
        canceledRequest: ManagedFocusRequest
    ) {
        guard sourceToken.pid == canceledRequest.token.pid,
              sourceToken != canceledRequest.token,
              workspaceManager.renderableFocusToken == sourceToken,
              !hasFrontmostOwnedWindow,
              let sourceEntry = workspaceManager.entry(for: sourceToken),
              isManagedWindowDisplayable(sourceToken),
              focusPolicyEngine.evaluate(.focusFollowsMouse).allowsFocusChange,
              canFocusWindow(pid: sourceEntry.pid, windowId: sourceEntry.windowId)
        else {
            return
        }
        if hasStartedServices,
           axEventHandler.frontmostApplicationPIDProvider() != sourceEntry.pid
        {
            return
        }
        guard let axRef = sourceEntry.axRef else {
            _ = shellAppWindowManager.focus(sourceToken)
            return
        }
        axEventHandler.noteMouseFocusIntent(token: sourceToken)
        _ = windowFocusOperations.activateAndFocusSameAppWindow(
            sourceEntry.pid,
            UInt32(sourceEntry.windowId),
            axRef.element
        )
    }
}
