// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreFoundation
import Foundation

enum ShellNotificationPreferences {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
            "Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist"
        )

    static func excludedBundles(at url: URL = defaultURL) -> Set<String>? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let limit = 4 << 20
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              integer(root["version"]) == 1,
              let apps = root["apps"] as? [[String: Any]]
        else { return nil }
        var seen: Set<String> = []
        var excluded: Set<String> = []
        for app in apps {
            guard let identifier = app["bundle-id"] as? String, !identifier.isEmpty else { continue }
            let bundle = identifier.lowercased()
            guard seen.insert(bundle).inserted else {
                excluded.remove(bundle)
                continue
            }
            guard let flags = integer(app["flags"]) else { continue }
            let notificationCenterDisabled = flags & 1 != 0
            let notificationsAllowed = flags & (1 << 25) != 0
            if notificationCenterDisabled || !notificationsAllowed { excluded.insert(bundle) }
        }
        return excluded
    }

    private static func integer(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = UInt64(number.stringValue)
        else { return nil }
        return value
    }
}
