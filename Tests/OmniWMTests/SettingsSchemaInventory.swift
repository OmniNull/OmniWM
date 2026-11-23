// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM

struct SettingsSchemaField: Equatable {
    let shape: SettingsSchemaShape
    let optional: Bool
    let hasDefault: Bool
}

indirect enum SettingsSchemaShape: Equatable {
    case scalar(String)
    case names([String])
    case numbers([Int64])
    case record([String: SettingsSchemaField])
    case list(Self)
    case map(Self)
    case alternatives([Self])

    var definition: String {
        "export type OmniWMSettings = " + render(depth: 0)
    }

    var fieldIDSource: String {
        let allPaths = paths(includeGroups: true).sorted()
        let roots = allPaths.filter { !$0.contains(".") }
        var cases = ["    case " + roots.prefix(1).joined()]
        for name in roots.dropFirst() {
            let index = cases.index(before: cases.endIndex)
            if cases[index].count + name.count + 2 <= 120 { cases[index] += ", " + name }
            else { cases.append("    case " + name) }
        }
        cases += allPaths.filter { $0.contains(".") }.map { path in
            let words = path.split(separator: ".")
            let name = words.prefix(1).joined() + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined()
            return "    case " + name + " = " + path.debugDescription
        }
        return """
        // SPDX-License-Identifier: GPL-2.0-only
        // Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

        enum SettingsFieldID: String, CaseIterable {
        \(cases.joined(separator: "\n"))
        }

        """
    }

    func render(depth: Int) -> String {
        switch self {
        case let .scalar(type): return type
        case let .names(names): return names.map(\.debugDescription).joined(separator: " | ")
        case .numbers: return "number"
        case let .record(fields):
            let indent = String(repeating: "    ", count: depth)
            let lines = fields.keys.sorted().compactMap { key -> String? in
                guard let field = fields[key] else { return nil }
                var type = field.shape.render(depth: depth + 1)
                if field.optional || field.hasDefault {
                    switch field.shape {
                    case .alternatives,
                         .names: type = "(" + type + ")"
                    default: break
                    }
                    type += "?"
                }
                return indent + "    " + SettingsLuauValue.keyLiteral(key) + ": " + type + ","
            }
            return "{\n" + lines.joined(separator: "\n") + "\n" + indent + "}"
        case let .list(element): return "{ " + element.render(depth: depth) + " }"
        case let .map(element): return "{ [string]: " + element.render(depth: depth) + " }"
        case let .alternatives(forms):
            return forms.map { $0.render(depth: depth) }.joined(separator: " | ")
        }
    }

    func paths(prefix: String = "", includeGroups: Bool = false) -> Set<String> {
        guard case let .record(fields) = self else { return [prefix] }
        var paths: Set<String> = []
        for (name, field) in fields {
            let path = prefix.isEmpty ? name : prefix + "." + name
            if includeGroups { paths.insert(path) }
            paths.formUnion(field.shape.paths(prefix: path, includeGroups: includeGroups))
        }
        return paths
    }

    func recordLists(prefix: String = "") -> [String: Set<String>] {
        switch self {
        case let .record(fields):
            var result: [String: Set<String>] = [:]
            for (name, field) in fields {
                let path = prefix.isEmpty ? name : prefix + "." + name
                result.merge(field.shape.recordLists(prefix: path)) { $0.union($1) }
            }
            return result
        case let .list(.record(fields)): return [prefix: Set(fields.keys)]
        default: return [:]
        }
    }
}
