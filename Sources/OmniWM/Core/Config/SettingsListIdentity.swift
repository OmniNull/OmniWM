// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CryptoKit
import Foundation

typealias SettingsListOrigins = [[String]: [Int?]]

enum SettingsListIdentity {
    static func composing(
        _ previous: SettingsListOrigins,
        with next: SettingsListOrigins
    ) -> SettingsListOrigins {
        var result = previous
        for (path, indices) in next {
            if let earlier = previous[path] {
                result[path] = indices
                    .map { index in index.flatMap { earlier.indices.contains($0) ? earlier[$0] : nil } }
            } else {
                result[path] = indices
            }
        }
        return result
    }

    static func sourceRows(path: [String], rows: [SettingsLuauValue]) -> [SettingsLuauValue] {
        let namespace: UInt8
        switch path {
        case ["appRules"]: namespace = 1
        case ["launcher", "entries"]: namespace = 2
        case ["appTheming", "custom"]: namespace = 3
        default: return rows
        }
        guard rows.contains(where: { $0["id"] == nil }) else { return rows }
        var occupied = Set(rows.compactMap { row -> UUID? in
            guard case let .string(text) = row["id"] else { return nil }
            return UUID(uuidString: text)
        })
        var occurrences: [SettingsLuauValue: Int] = [:]
        return rows.map { row in
            guard case var .record(fields) = row, fields["id"] == nil else { return row }
            var occurrence = occurrences[row, default: 0]
            var id: UUID
            repeat {
                id = implicitID(namespace: namespace, row: row, occurrence: occurrence)
                occurrence += 1
            } while !occupied.insert(id).inserted
            occurrences[row] = occurrence
            fields["id"] = .string(id.uuidString)
            return .record(fields)
        }
    }

    private static func implicitID(namespace: UInt8, row: SettingsLuauValue, occurrence: Int) -> UUID {
        let digest = SHA256.hash(data: Data("\(occurrence):\(row.literal())".utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            namespace, bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
            bytes[6] & 0x0F | 0x80, bytes[7], bytes[8] & 0x3F | 0x80, bytes[9], bytes[10],
            bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func match(path: [String], old: [SettingsLuauValue], new: [SettingsLuauValue]) -> [Int?] {
        let positional = old.count == new.count && usesEditablePositions(path)
        var positions: [SettingsLuauValue: [Int]] = [:]
        var matches = [Int?](repeating: nil, count: new.count)
        for index in old.indices.reversed() {
            if positional, old[index] == new[index] {
                matches[index] = index
                continue
            }
            positions[key(for: old[index], in: path), default: []].append(index)
        }
        for index in new.indices where matches[index] == nil {
            matches[index] = positions[key(for: new[index], in: path)]?.popLast()
        }
        if positional, matches.contains(nil) {
            let used = Set(matches.compactMap { $0 })
            var remaining = old.indices.filter { !used.contains($0) }.makeIterator()
            for index in matches.indices where matches[index] == nil {
                matches[index] = remaining.next()
            }
        }
        return matches
    }

    private static func usesEditablePositions(_ path: [String]) -> Bool {
        path == ["niri", "containerPrimarySpanPresets"] ||
            path == ["launcher", "appFolders"] || path == ["launcher", "cliFolders"] ||
            (path.starts(with: ["launcher", "entries"]) && path.last == "arguments")
    }

    static func key(for row: SettingsLuauValue, in path: [String]) -> SettingsLuauValue {
        if case let .string(id) = row["id"] {
            if path == ["appTheming", "custom"] || path == ["hotkeys"] { return .string(id) }
            return .string(UUID(uuidString: id)?.uuidString ?? id)
        }
        if path == ["monitorOrientationOverrides"] || (path.first == "routing" && path.last == "monitors") {
            return displayUUID(row["monitorDisplayUUID"]) ?? row["monitorDisplayId"] ?? row["monitorName"] ?? row
        }
        switch path {
        case ["monitors", "ranking"]:
            if let uuid = displayUUID(row["displayUUID"]) { return uuid }
            return .list([row["displayId"], row["name"]].compactMap { $0 })
        case ["shellPermissions", "widgets"]:
            return .list([row["role"], row["name"], row["source"]].compactMap { $0 })
        case ["shellPermissions", "programs"]:
            return .list([row["name"], row["source"], row["command"]].compactMap { $0 })
        default:
            guard case let .string(text) = row else { return row }
            if path.first == "statusMenu" || path == ["workspaceBar", "excludedBundleIDs"] ||
                path == ["hiddenBar", "hiddenBundleIDs"] || path.starts(with: ["shellPermissions", "widgets"])
            { return .string(SettingsLuauDocument.rowKey(text, in: path)) }
            return row
        }
    }

    private static func displayUUID(_ value: SettingsLuauValue?) -> SettingsLuauValue? {
        guard case let .string(text) = value, let uuid = DisplayUUID.canonical(text) else { return nil }
        return .string(uuid)
    }
}
