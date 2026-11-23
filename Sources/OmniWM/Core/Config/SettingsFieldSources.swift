// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation

struct SettingsCodeSite: Hashable, Identifiable {
    let line: Int
    let bytes: Range<Int>
    var id: Range<Int> {
        bytes
    }

    func selection(in source: Data) -> NSRange {
        let start = String(decoding: source[..<bytes.lowerBound], as: UTF8.self).utf16.count
        let length = String(decoding: source[bytes], as: UTF8.self).utf16.count
        return NSRange(location: start, length: length)
    }
}

enum SettingsFieldMember {
    case key(String)
    case row(String?)
    case index(Int?)
}

extension SettingsLuauDocument {
    static func indexFormulaRows(
        in tree: SettingsLuauValue,
        paths: Dictionary<[String], [SettingsCodeSite]>.Keys,
        export: SettingsExport
    ) -> [[String]: [String: Int]] {
        var result: [[String]: [String: Int]] = [:]
        for path in paths {
            var value = tree
            for (offset, component) in path.enumerated() {
                if case let .list(rows) = value, let index = Int(component), rows.indices.contains(index) {
                    value = rows[index]
                    let parent = Array(path.prefix(offset))
                    let id: String
                    if case let .string(string) = value["id"] ?? value {
                        id = string
                    } else if parent == ["appRules"], export.appRules.indices.contains(index) {
                        id = export.appRules[index].id.uuidString
                    } else if parent == ["launcher", "entries"], export.launcher.entries.indices.contains(index) {
                        id = export.launcher.entries[index].id.uuidString
                    } else if parent == ["appTheming", "custom"], export.appTheming.custom.indices.contains(index) {
                        id = export.appTheming.custom[index].id
                    } else {
                        continue
                    }
                    result[parent, default: [:]][rowKey(id, in: parent)] = index
                } else if let child = value[component] {
                    value = child
                } else {
                    break
                }
            }
        }
        return result
    }

    static func rowKey(_ id: String, in path: [String]) -> String {
        if path == ["workspaceBar", "excludedBundleIDs"] {
            return id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if path == ["hiddenBar", "hiddenBundleIDs"] || path.first == "statusMenu" {
            return id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if path.starts(with: ["shellPermissions", "widgets"]), path.last == "allowed" || path.last == "denied" {
            return ShellHTTPPolicy.canonicalHost(id)
        }
        return UUID(uuidString: id)?.uuidString ?? id
    }

    static func sourcePath(_ path: [String]) -> [String] {
        if path.count == 3, path.starts(with: ["scratchpads", "labels"]),
           let slot = Int(path[2].trimmingCharacters(in: .whitespacesAndNewlines))
        {
            return Array(path.prefix(2)) + [String(slot)]
        }
        guard path.count == 3, path.starts(with: ["workspaceBar", "iconOverrides"]) else { return path }
        return Array(path.prefix(2)) + [path[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }
}

@Observable @MainActor
final class SettingsFieldSources {
    var document: SettingsLuauDocument?

    func sites(
        for ids: [SettingsFieldID],
        member: SettingsFieldMember? = nil,
        leaves: [String] = [],
        element: String? = nil
    ) -> [SettingsCodeSite] {
        guard let document, document.hasFormulas else { return [] }
        let fields = ids.flatMap { id -> [[String]] in
            var path = id.rawValue.split(separator: ".").map(String.init)
            switch member {
            case let .key(key): path.append(key)
            case let .row(id):
                let index = id.flatMap { document.formulaRows[path]?[SettingsLuauDocument.rowKey($0, in: path)] }
                path.append(index.map(String.init) ?? "-")
            case let .index(index): path.append(index.map(String.init) ?? "-")
            case nil: break
            }
            if leaves.isEmpty { return [path] }
            return leaves.map {
                var child = path + $0.split(separator: ".").map(String.init)
                if let element {
                    let index = document.formulaRows[child]?[SettingsLuauDocument.rowKey(element, in: child)]
                    child.append(index.map(String.init) ?? "-")
                }
                return child
            }
        }
        return sites(for: fields)
    }

    func sites(for fields: [[String]]) -> [SettingsCodeSite] {
        guard let document, document.hasFormulas else { return [] }
        let fields = fields.map(SettingsLuauDocument.sourcePath)
        var sites: Set<SettingsCodeSite> = []
        for (path, locations) in document.formulas
            where fields.contains(where: { path.starts(with: $0) || $0.starts(with: path) })
        {
            sites.formUnion(locations)
        }
        return sites.sorted { $0.bytes.lowerBound < $1.bytes.lowerBound }
    }
}
