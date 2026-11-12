// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension IntentLedger {
    func lastIntentIndex(where predicate: (Intent) -> Bool) -> Int? {
        let entries = entries
        var index = entries.endIndex
        while index > entries.startIndex {
            index -= 1
            if predicate(entries[index]) { return index }
        }
        return nil
    }

    func openIndex(where predicate: (Intent) -> Bool) -> Int? {
        lastIntentIndex { $0.phase == .pending && predicate($0) }
    }

    func lastIntent(where predicate: (Intent) -> Bool) -> Intent? {
        guard let index = lastIntentIndex(where: predicate) else { return nil }
        return entries[index]
    }

    func intents(where predicate: (Intent) -> Bool) -> [Intent] {
        let entries = entries
        var matches: [Intent] = []
        for index in entries.indices where predicate(entries[index]) {
            matches.append(entries[index])
        }
        return matches
    }

    private static let lateEchoWindow: Duration = .seconds(1)
    func classifyFocusObservation(token: WindowToken) -> EchoClassification {
        if let intent = openFocusIntent(token: token) {
            return .echoOf(intent)
        }
        let now = clock()
        let lateEcho = lastIntent { entry in
            guard entry.phase.isRetired,
                  entry.kind.focusTargetToken == token,
                  let retiredAt = entry.retiredAt
            else {
                return false
            }
            return retiredAt.duration(to: now) <= Self.lateEchoWindow
        }
        if let lateEcho {
            return .lateEcho(lateEcho)
        }
        return .external
    }

    func activeManagedRequest(for pid: pid_t) -> ManagedFocusRequest? {
        guard let request = activeManagedRequest, request.token.pid == pid else { return nil }
        return request
    }

    func activeManagedRequest(for token: WindowToken) -> ManagedFocusRequest? {
        guard let request = activeManagedRequest, request.token == token else { return nil }
        return request
    }

    func activeManagedRequest(requestId: UInt64) -> ManagedFocusRequest? {
        guard let request = activeManagedRequest, request.requestId == requestId else { return nil }
        return request
    }

    func openAppRevealFocusIntent(pid: pid_t) -> (intent: Intent, payload: AppRevealFocusPayload)? {
        guard let intent = lastIntent(where: { entry in
                  guard entry.phase == .pending,
                        case let .appRevealFocus(payload) = entry.kind
                  else {
                      return false
                  }
                  return payload.pendingAppPIDs.contains(pid)
              }),
              case let .appRevealFocus(payload) = intent.kind
        else {
            return nil
        }
        return (intent, payload)
    }

    func openReplacementFocusIntent(pid: pid_t, workspaceId: WorkspaceDescriptor.ID) -> Intent? {
        lastIntent { entry in
            guard entry.phase == .pending,
                  case let .replacementFocus(payload) = entry.kind
            else {
                return false
            }
            return payload.pid == pid && payload.workspaceId == workspaceId
        }
    }

    func openReplacementFocusIntents(pid: pid_t) -> [Intent] {
        intents { entry in
            guard entry.phase == .pending,
                  case let .replacementFocus(payload) = entry.kind
            else {
                return false
            }
            return payload.pid == pid
        }
    }

    func openReplacementFocusIntents() -> [Intent] {
        intents { entry in
            guard entry.phase == .pending, case .replacementFocus = entry.kind else { return false }
            return true
        }
    }

    func openSameAppCloseProbe() -> (intent: Intent, payload: SameAppCloseProbePayload)? {
        let open = lastIntent { entry in
            guard entry.phase == .pending, case .sameAppCloseProbe = entry.kind else { return false }
            return true
        }
        guard let open, case let .sameAppCloseProbe(payload) = open.kind else { return nil }
        return (open, payload)
    }

    func openAppTerminationFocusRecovery() -> (
        intent: Intent,
        payload: AppTerminationFocusRecoveryPayload
    )? {
        let open = lastIntent { entry in
            guard entry.phase == .pending,
                  case .appTerminationFocusRecovery = entry.kind
            else {
                return false
            }
            return true
        }
        guard let open,
              case let .appTerminationFocusRecovery(payload) = open.kind
        else {
            return nil
        }
        return (open, payload)
    }

    func intent(id: IntentID) -> Intent? {
        lastIntent { $0.id == id }
    }

    func openIntent(id: IntentID) -> Intent? {
        lastIntent { $0.id == id && $0.phase == .pending }
    }

    func openFocusIntent(token: WindowToken) -> Intent? {
        lastIntent { $0.phase == .pending && $0.kind.focusTargetToken == token }
    }

    func newestFocusIntentIssuedAtSeq() -> UInt64? {
        lastIntent { $0.kind.isFocusWindow }?.issuedAtSeq
    }

    func newestFocusIntentId() -> IntentID? {
        lastIntent { $0.kind.isFocusWindow }?.id
    }

    func allowsMouseToFocusedWarp(for token: WindowToken) -> Bool {
        if let request = activeManagedRequest, request.token == token {
            return request.origin.allowsMouseToFocusedWarp
        }
        if let lastConfirmedManagedFocus, lastConfirmedManagedFocus.token == token {
            return lastConfirmedManagedFocus.origin.allowsMouseToFocusedWarp
        }
        return true
    }
}
