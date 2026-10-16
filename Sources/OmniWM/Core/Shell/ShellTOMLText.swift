// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import TOML

enum ShellTOMLText {
    enum Failure: Error, LocalizedError {
        case unreadable
        case invalidValue(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: "The existing shell configuration could not be parsed. No settings were changed."
            case let .invalidValue(key): "The shell setting at \(key) could not be edited. No settings were changed."
            }
        }
    }

    static func contains(_ key: [String], in text: String) throws -> Bool {
        var node = TOMLNode.table(try tree(in: text))
        for part in key {
            guard case let .table(table) = node, let child = table[part] else { return false }
            node = child
        }
        return true
    }

    static func setting(_ entries: [(key: [String], value: String?)], in original: String) throws -> String {
        let nodes = try entries.map { key, value -> (key: [String], value: TOMLNode?) in
            guard let value else { return (key, nil) }
            guard let node = try? tree(in: "value = \(value)\n")["value"] else {
                throw Failure.invalidValue(key.joined(separator: "."))
            }
            return (key, node)
        }
        return try settingNodes(nodes, in: original)
    }

    static func settingNodes(_ entries: [(key: [String], value: TOMLNode?)], in original: String) throws -> String {
        let current = try tree(in: original)
        var updated = current
        for (key, value) in entries {
            try put(value, at: key[...], in: &updated)
        }
        guard updated != current else { return original }
        let encoder = TOMLEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return String(decoding: try encoder.encode(updated), as: UTF8.self)
    }

    static func node(_ value: some Encodable) throws -> TOMLNode {
        let data = try TOMLEncoder().encode(["value": value])
        guard let node = try TOMLDecoder().decode([String: TOMLNode].self, from: data)["value"] else {
            throw Failure.invalidValue("value")
        }
        return node
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from node: TOMLNode) throws -> Value {
        let data = try TOMLEncoder().encode(["value": node])
        guard let value = try TOMLDecoder().decode([String: Value].self, from: data)["value"] else {
            throw Failure.invalidValue("value")
        }
        return value
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    private static func tree(in text: String) throws -> [String: TOMLNode] {
        guard let tree = try? TOMLDecoder().decode([String: TOMLNode].self, from: Data(text.utf8)) else {
            throw Failure.unreadable
        }
        return tree
    }

    private static func put(_ node: TOMLNode?, at key: ArraySlice<String>, in table: inout [String: TOMLNode]) throws {
        guard let first = key.first else { throw Failure.invalidValue("") }
        guard key.count > 1 else {
            table[first] = node
            return
        }
        var child: [String: TOMLNode]
        switch table[first] {
        case let .table(existing)?: child = existing
        case nil: child = [:]
        default: throw Failure.invalidValue(key.joined(separator: "."))
        }
        try put(node, at: key.dropFirst(), in: &child)
        table[first] = child.isEmpty && node == nil ? nil : .table(child)
    }
}
