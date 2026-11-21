// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreFoundation
import Foundation

struct ShellNotificationPreferences {
    static let supportedVersion: UInt64 = 1
    static let hiddenFromNotificationCenter: UInt64 = 1
    static let notificationsAllowed: UInt64 = 1 << 25
    static let systemCenterPrefix = "_system_center_:"
    static let permissionPromptSource = "com.apple.notificationcenter.askpermissions"

    private var entries: Set<String> = []
    private var hidden: Set<String> = []

    static func url(forDatabase database: URL) -> URL {
        let container = database.deletingLastPathComponent().deletingLastPathComponent()
        return container.appendingPathComponent("Library/Preferences/\(container.lastPathComponent).plist")
    }

    init?(contentsOf url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let limit = ShellNotificationReadBudget.readByteLimit
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              Self.integer(root["version"]) == Self.supportedVersion,
              let apps = root["apps"] as? [[String: Any]]
        else { return nil }
        for app in apps {
            guard let identifier = app["bundle-id"] as? String, !identifier.isEmpty else { continue }
            let bundle = identifier.lowercased()
            guard entries.insert(bundle).inserted else {
                hidden.remove(bundle)
                continue
            }
            guard let flags = Self.integer(app["flags"]) else { continue }
            if flags & Self.hiddenFromNotificationCenter != 0 || flags & Self.notificationsAllowed == 0 {
                hidden.insert(bundle)
            }
        }
    }

    func lists(_ bundle: String, isInstalled: (String) -> Bool) -> Bool {
        let identifier = bundle.lowercased()
        if identifier.hasPrefix(Self.systemCenterPrefix) || hidden.contains(identifier) { return false }
        return entries.contains(identifier) || identifier == Self.permissionPromptSource || isInstalled(bundle)
    }

    private static func integer(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = UInt64(number.stringValue)
        else { return nil }
        return value
    }
}
