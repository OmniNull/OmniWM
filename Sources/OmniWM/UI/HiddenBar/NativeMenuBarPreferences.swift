// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct NativeMenuBarPreferences {
    var read: () throws -> Data
    var write: (Data) throws -> Void

    static var live: Self {
        let domain = (NSHomeDirectory()
            +
            "/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter") as CFString
        let key = "trackedApplications" as CFString
        return Self(read: {
            guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
                  let data = CFPreferencesCopyValue(
                      key,
                      domain,
                      kCFPreferencesCurrentUser,
                      kCFPreferencesAnyHost
                  ) as? Data
            else { throw NativeMenuBarPreferencesError.unavailable }
            return data
        }, write: { data in
            CFPreferencesSetValue(key, data as CFData, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
                throw NativeMenuBarPreferencesError.writeFailed
            }
        })
    }
}

enum NativeMenuBarPreferencesError: Error {
    case unavailable
    case unsupportedFormat
    case writeFailed
}

struct NativeMenuBarApplications {
    private var entries: [[String: Any]]
    private var indices: [String: Int] = [:]

    init(data: Data) throws {
        guard let entries = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]],
              entries.count.isMultiple(of: 2)
        else { throw NativeMenuBarPreferencesError.unsupportedFormat }
        self.entries = entries
        for index in stride(from: 0, to: entries.count, by: 2) {
            guard let bundle = entries[index]["bundle"] as? [String: String], let bundleID = bundle["_0"] else {
                continue
            }
            guard indices[bundleID] == nil,
                  let allowed = entries[index + 1]["isAllowed"] as? NSNumber,
                  CFGetTypeID(allowed) == CFBooleanGetTypeID()
            else { throw NativeMenuBarPreferencesError.unsupportedFormat }
            indices[bundleID] = index + 1
        }
    }

    var bundleIDs: [String] {
        Array(indices.keys)
    }

    func isAllowed(_ bundleID: String) -> Bool? {
        guard let index = indices[bundleID] else { return nil }
        return entries[index]["isAllowed"] as? Bool
    }

    mutating func setAllowed(_ allowed: Bool, for bundleID: String) {
        guard let index = indices[bundleID] else { return }
        entries[index]["isAllowed"] = allowed
    }

    func hasMenuItemLocation(_ bundleID: String) -> Bool {
        guard let index = indices[bundleID],
              let locations = entries[index]["menuItemLocations"] as? [[String: Any]]
        else { return false }
        return locations.contains { ($0["bundle"] as? [String: String])?["_0"] == bundleID }
    }

    mutating func registerMenuItemLocations(_ bundleIDs: Set<String>) throws -> Bool {
        var changed = false
        for bundleID in bundleIDs {
            guard let index = indices[bundleID], !hasMenuItemLocation(bundleID) else { continue }
            let locations = entries[index]["menuItemLocations"] ?? [[String: Any]]()
            guard var locations = locations as? [[String: Any]] else {
                throw NativeMenuBarPreferencesError.unsupportedFormat
            }
            locations.append(["bundle": ["_0": bundleID]])
            entries[index]["menuItemLocations"] = locations
            changed = true
        }
        return changed
    }

    func encoded() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
    }
}
