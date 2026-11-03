// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension ActionCatalog {
    static let openAppPrefix = "openApp."

    static func openAppSpec(for id: String) -> ActionSpec? {
        guard id.hasPrefix(openAppPrefix) else { return nil }
        return openAppSpec(bundleID: String(id.dropFirst(openAppPrefix.count)))
    }

    static func openAppSpec(bundleID: String) -> ActionSpec? {
        guard !bundleID.isEmpty, !bundleID.contains(where: \.isWhitespace) else { return nil }
        return action(
            id: openAppPrefix + bundleID,
            command: .openApp(bundleID),
            category: .focus,
            binding: .unassigned,
            keywords: ["open", "launch", "app", "application", bundleID]
        )
    }

    static func appDisplayName(bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
    }
}
