// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct SettingsTableEdit {
    struct Replacement {
        var text: String
        let value: SettingsLuauValue
    }

    struct Node {
        let source: [String]
        let model: [String]
        let raw: SettingsLuauValue
        var old: SettingsLuauValue
        let new: SettingsLuauValue
    }

    let document: LuauTableDocument
    let settings: SettingsExport?
    let origins: SettingsListOrigins
    let newline: String
    var questions: [String] = []
    var fixed: [[String]] = []
    var removals: [[String]] = []

    mutating func includeOtherChanges(_ changes: [SettingsValueChange]) {
        let reviewed = fixed + removals
        let others = changes.filter { change in
            !reviewed.contains(where: { change.path.starts(with: $0) || $0.starts(with: change.path) })
        }
        if !others.isEmpty { questions.append("Also save:\n" + others.map(\.summary).joined(separator: "\n")) }
    }

    func text(_ range: Range<Int>) -> String {
        String(decoding: document.source[range], as: UTF8.self)
    }

    func needsEdit(_ node: Node) -> Bool {
        node.old != node.new || origins.contains { path, indices in
            path.starts(with: node.model) && indices.enumerated().contains { $0.element != $0.offset }
        }
    }

    mutating func rewrite(_ node: Node, within bytes: Range<Int>) throws -> Replacement? {
        guard needsEdit(node) else { return nil }
        guard let field = document.fields[node.source] else {
            throw SettingsLuauError(message: "Settings cannot locate \(node.source.joined(separator: ".")).")
        }
        var replacement: Replacement
        if let table = document.tables[node.source], case let .record(new) = node.new,
           case let .record(old) = node.old, table.items.allSatisfy({ $0.key != nil })
        {
            replacement = try record(node, from: old, to: new, table: table)
        } else if let table = document.tables[node.source], case let .list(new) = node.new,
                  case let .list(old) = node.old, table.items.allSatisfy({ $0.key == nil }),
                  table.items.count == node.raw.listRows.count
        {
            replacement = try list(node, from: old, to: new, table: table)
        } else {
            replacement = try replaceValue(node, field: field)
        }
        replacement.text = text(bytes.lowerBound ..< field.bytes.lowerBound) + replacement
            .text + text(field.bytes.upperBound ..< bytes.upperBound)
        return replacement
    }

    private mutating func replaceValue(_ node: Node, field: SettingsLuauDocument.Field) throws -> Replacement {
        var value = node.new
        if node.source.isEmpty, let settings {
            value = try SettingsLuauValue.fields(of: settings)
            for change in SettingsValueChange
                .between(node.old, node.new) { value.set(change.value, at: change.path[...]) }
            value.set(nil, at: ["schemaVersion"])
        }
        let literal: String
        if !node.source.isEmpty, let parent = document.tables[Array(node.source.dropLast())] {
            literal = SettingsTableText(document: document, table: parent, newline: newline).literal(value)
        } else {
            literal = value.literal().replacingOccurrences(of: "\n", with: newline)
        }
        if hasCode(at: node.source) {
            let scope = node.model.isEmpty ? "all returned settings" : node.model.joined(separator: ".")
            let expression = text(field.bytes)
            switch node.new {
            case .record:
                let requested = SettingsValueChange.between(node.old, node.new).map {
                    (node.model + $0.path).joined(separator: ".") + " = " + ($0.value?.literal() ?? "nil")
                }.joined(separator: "\n")
                questions
                    .append(
                        "Line \(field.line) calculates \(scope) using:\n\(expression)\n\nYour edit:\n\(requested)\n\nReplace this entire group? All values below, including the other fields, will become fixed:\n\(literal)"
                    )
            case .list:
                questions
                    .append(
                        "Line \(field.line) calculates \(scope) using:\n\(expression)\n\nReplace this list? These are all the rows that will become fixed:\n\(literal)"
                    )
            default:
                questions.append("Line \(field.line) calculates \(scope). Replace \(expression) with \(literal)?")
            }
            fixed.append(node.model)
        }
        return Replacement(
            text: document.preservingComments(in: field.bytes, before: literal, newline: newline),
            value: value
        )
    }

    func hasCode(at path: [String]) -> Bool {
        let normalized = SettingsLuauDocument.sourcePath(path)
        return document.formulas.keys.contains { $0.starts(with: normalized) }
    }

    mutating func removing(_ value: SettingsLuauValue?, at source: [String], model: [String]) {
        guard hasCode(at: source), let field = document.fields[source] else { return }
        questions
            .append(
                "Remove \(model.joined(separator: "."))? Line \(field.line) contains code:\n\(text(field.bytes))\n\nRemoved value:\n\(value?.literal() ?? "nil")"
            )
        removals.append(model)
    }

    private mutating func record(
        _ node: Node,
        from old: [String: SettingsLuauValue],
        to new: [String: SettingsLuauValue],
        table: SettingsSourceTable
    ) throws -> Replacement {
        var values: [String: SettingsLuauValue]
        if case let .record(raw) = node.raw { values = raw } else { values = [:] }
        let layout = SettingsTableText(document: document, table: table, newline: newline)
        var rows: [SettingsTableText.Row] = []
        var present: Set<String> = []
        for (index, item) in table.items.enumerated() {
            guard let sourceKey = item.key else { continue }
            let source = node.source + [sourceKey]
            let key: String
            if old[sourceKey] != nil || new[sourceKey] != nil {
                key = sourceKey
            } else {
                let normalized = SettingsLuauDocument.sourcePath(source)
                key = old.keys.first { SettingsLuauDocument.sourcePath(node.source + [$0]) == normalized }
                    ?? new.keys.first { SettingsLuauDocument.sourcePath(node.source + [$0]) == normalized } ?? sourceKey
            }
            present.insert(key)
            let model = node.model + [key]
            if new[key] == nil, old[key] != nil {
                removing(node.raw[sourceKey], at: source, model: model)
                values.removeValue(forKey: sourceKey)
                continue
            }
            var replacement: String?
            if let after = new[key] {
                let raw = node.raw[sourceKey] ?? .record([:])
                let child = Node(source: source, model: model, raw: raw, old: old[key] ?? raw, new: after)
                if let value = try rewrite(child, within: item.value) {
                    replacement = text(item.bytes.lowerBound ..< item.value.lowerBound) + value.text
                    values[sourceKey] = value.value
                }
            }
            rows.append(.init(origin: index, text: replacement))
        }
        for key in new.keys.sorted() where !present.contains(key) && old[key] != new[key] {
            guard let value = new[key] else { continue }
            let addition = Self.insertedValue(from: old[key], to: value)
            rows.append(.init(text: SettingsLuauValue.keyLiteral(key) + " = " + layout.literal(addition)))
            values[key] = addition
        }
        return Replacement(text: layout.render(rows), value: .record(values))
    }

    private static func insertedValue(from old: SettingsLuauValue?, to new: SettingsLuauValue) -> SettingsLuauValue {
        guard case let .record(previous) = old, case let .record(next) = new else { return new }
        var fields: [String: SettingsLuauValue] = [:]
        for (key, value) in next where previous[key] != value {
            fields[key] = insertedValue(from: previous[key], to: value)
        }
        return .record(fields)
    }
}
