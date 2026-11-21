// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation

extension ShellNotificationAccessibility.Session {
    private static let stackSubrole = "AXNotificationCenterBannerStack"
    private static let clearAllAction = "Name:Clear All"

    // One stack's Clear All removes every notification it groups, which beats closing banners one by one.
    func clearBatchItem() -> ShellNotificationActionOutcome {
        do {
            try check()
            enter("batch")
            let request = try notificationRequest()
            while true {
                let current = try retryAX { try snapshot() }
                guard current.history else {
                    throw ShellNotificationAccessibility.ActionFailure(outcome: .historyClosed)
                }
                if let (id, stack) = try clearableStack(in: current, preferring: request.id) {
                    if try clearStack(id, stack) { clearedBundles.insert(request.bundle) }
                    continue
                }
                if current.items[request.id] == nil, clearedBundles.contains(request.bundle),
                   try !hasStack(in: current)
                {
                    trace("native.stack.cleared")
                    return .dispatched
                }
                return execute()
            }
        } catch let error as ShellNotificationAccessibility.ActionFailure {
            return error.outcome
        } catch is ShellNotificationAccessibility.ExpiredElement {
            return .notFound
        } catch {
            return .failed
        }
    }

    private func clearableStack(
        in snapshot: ShellNotificationAccessibility.Snapshot,
        preferring target: UUID
    ) throws -> (UUID, AXUIElement)? {
        let ordered = snapshot.items.sorted { lhs, _ in lhs.key == target }
        for (id, matches) in ordered where !unclearableStacks.contains(id) && matches.count == 1 {
            if try isStack(matches[0]) { return (id, matches[0]) }
        }
        return nil
    }

    // A stack left uncleared may still hide the target, so only expansion can prove it is gone.
    private func hasStack(in snapshot: ShellNotificationAccessibility.Snapshot) throws -> Bool {
        for element in snapshot.items.values.joined() where try isStack(element) {
            return true
        }
        return false
    }

    // A peer that vanished since the snapshot is no stack and must not abort the target's own path.
    private func isStack(_ element: AXUIElement) throws -> Bool {
        do {
            return try string(element, kAXSubroleAttribute) == Self.stackSubrole
        } catch is ShellNotificationAccessibility.ExpiredElement {
            return false
        }
    }

    private func clearStack(_ id: UUID, _ stack: AXUIElement) throws -> Bool {
        enter("clearStack")
        let names = try actions(stack).filter {
            $0.split(separator: "\n", maxSplits: 1).first == Substring(Self.clearAllAction)
        }
        guard names.count == 1 else {
            trace("native.stack.clear.unsupported", fields: "matches=\(names.count)")
            unclearableStacks.insert(id)
            return false
        }
        try check()
        let result = AXUIElementPerformAction(stack, names[0] as CFString)
        trace("native.stack.clear", fields: "stack=\(id.uuidString.lowercased()) ax=\(result.rawValue)")
        guard result == .success else { throw ShellNotificationAccessibility.ActionFailure(outcome: .failed) }
        _ = try wait { value in
            guard value.history else {
                throw ShellNotificationAccessibility.ActionFailure(outcome: .historyClosed)
            }
            return value.items[id] == nil
        }
        return true
    }
}
