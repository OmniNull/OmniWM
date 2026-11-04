// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension ActionCatalog {
    static let openAppPrefix = "openApp."

    static func openAppBundleID(for id: String) -> String? {
        guard id.hasPrefix(openAppPrefix) else { return nil }
        let bundleID = String(id.dropFirst(openAppPrefix.count))
        guard !bundleID.isEmpty, !bundleID.contains(where: \.isWhitespace) else { return nil }
        return bundleID
    }

    static func openAppSpec(for id: String) -> ActionSpec? {
        guard let bundleID = openAppBundleID(for: id) else { return nil }
        return action(
            id: id,
            command: .openApp(bundleID),
            category: .focus,
            binding: .unassigned,
            keywords: ["open", "launch", "app", "application", bundleID]
        )
    }

    static func openAppSpec(bundleID: String) -> ActionSpec? {
        openAppSpec(for: openAppPrefix + bundleID)
    }

    static func appDisplayName(bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
    }
}
