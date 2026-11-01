// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation

extension ShellNotificationAccessibility.Session {
    func individual() throws -> AXUIElement {
        var current = try snapshot()
        var expanded = Set<UUID>()
        while true {
            guard current.history else { throw ShellNotificationAccessibility.ActionFailure(outcome: .historyClosed) }
            if let matches = current.items[request.id] {
                guard matches.count == 1
                else { throw ShellNotificationAccessibility.ActionFailure(outcome: .ambiguous) }
                let target = matches[0]
                let individual = try string(target, kAXSubroleAttribute) == "AXNotificationCenterBanner"
                trace("native.target", fields: "matches=\(matches.count) individual=\(individual)")
                if individual { return target }
            }
            let (id, stack) = try unexpandedStack(in: current, excluding: expanded)
            expanded.insert(id)
            try check()
            let result = AXUIElementPerformAction(stack, kAXPressAction as CFString)
            trace("native.stack.expand", fields: "stack=\(id.uuidString.lowercased()) ax=\(result.rawValue)")
            guard result == .success else {
                throw ShellNotificationAccessibility.ActionFailure(outcome: .failed)
            }
            current = try wait { value in
                guard value.history else { throw ShellNotificationAccessibility.ActionFailure(outcome: .historyClosed) }
                guard let matches = value.items[id], matches.count == 1 else { return false }
                return try self.string(matches[0], kAXSubroleAttribute) == "AXNotificationCenterBanner"
            }
        }
    }

    private func unexpandedStack(
        in snapshot: ShellNotificationAccessibility.Snapshot,
        excluding expanded: Set<UUID>
    ) throws -> (UUID, AXUIElement) {
        for (id, matches) in snapshot.items where !expanded.contains(id) {
            guard matches.count == 1 else { throw ShellNotificationAccessibility.ActionFailure(outcome: .ambiguous) }
            if try string(matches[0], kAXSubroleAttribute) == "AXNotificationCenterBannerStack" {
                return (id, matches[0])
            }
        }
        throw ShellNotificationAccessibility.ActionFailure(outcome: .notFound)
    }
}
