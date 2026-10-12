// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension IntentLedger {
    @discardableResult
    func confirm(id: IntentID, source: ActivationEventSource? = nil) -> Intent? {
        retire(id: id, phase: .confirmed, source: source)
    }

    @discardableResult
    func cancel(id: IntentID) -> Intent? {
        retire(id: id, phase: .cancelled, source: nil)
    }

    @discardableResult
    func supersede(id: IntentID) -> Intent? {
        retire(id: id, phase: .superseded, source: nil)
    }

    @discardableResult
    func markExpired(id: IntentID) -> Intent? {
        retire(id: id, phase: .expired, source: nil)
    }

    @discardableResult
    func cancelManagedRequest(
        matching token: WindowToken? = nil,
        workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> ManagedFocusRequest? {
        guard let request = activeManagedRequest else { return nil }

        let matchesToken = token.map { request.token == $0 } ?? true
        let matchesWorkspace = workspaceId.map { request.workspaceId == $0 } ?? true
        guard matchesToken, matchesWorkspace else { return nil }

        _ = cancel(id: request.requestId)
        deadlineWheel?.cancel(intentId: request.requestId)
        return request
    }

    @discardableResult
    func cancelManagedRequest(requestId: UInt64) -> ManagedFocusRequest? {
        guard let request = activeManagedRequest, request.requestId == requestId else {
            return nil
        }
        _ = cancel(id: requestId)
        deadlineWheel?.cancel(intentId: requestId)
        return request
    }

    @discardableResult
    func confirmAppRevealFocus(intentId: IntentID) -> AppRevealFocusPayload? {
        guard let open = openIntent(id: intentId),
              case let .appRevealFocus(payload) = open.kind,
              payload.pendingAppPIDs.isEmpty,
              let intent = confirm(id: intentId),
              case let .appRevealFocus(confirmedPayload) = intent.kind
        else {
            return nil
        }
        deadlineWheel?.cancel(intentId: intentId)
        return confirmedPayload
    }

    func cancelAppRevealFocus(intentId: IntentID) {
        guard cancel(id: intentId) != nil else { return }
        deadlineWheel?.cancel(intentId: intentId)
    }

    func cancelAppRevealFocus(pid: pid_t) {
        guard let open = openAppRevealFocusIntent(pid: pid) else { return }
        cancelAppRevealFocus(intentId: open.intent.id)
    }
}
