// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct SettingsLuauEdit {
    let source: Data
    let question: String?
    let expected: SettingsLuauValue?
    var fixedPaths: [[String]] = []

    func preview(
        _ candidate: SettingsLuauDocument,
        applying desired: SettingsExport
    ) throws -> (String, SettingsExport)? {
        guard let question, let expected else { return nil }
        let actual = try SettingsLuauValue.fields(of: candidate.export)
        guard actual != expected else { return (question, desired) }
        let derived = SettingsValueChange.between(expected, actual, rows: .positions)
        var values = try SettingsLuauValue.fields(of: desired)
        var details: [String] = []
        for change in derived {
            guard !fixedPaths.contains(where: { $0.starts(with: change.path) || change.path.starts(with: $0) }) else {
                throw SettingsLuauError(
                    message: "The replacement does not produce the requested value for \(change.path.joined(separator: ".")). Edit it in settings.luau."
                )
            }
            details
                .append(
                    "\(change.path.joined(separator: ".")): \(change.old?.literal() ?? "nil") → \(change.value?.literal() ?? "nil")"
                )
            values.set(change.value, at: change.path[...])
        }
        let message = question + "\n\nOther settings calculated by this code will also change:\n" + details
            .joined(separator: "\n")
        return try (message, SettingsLuauDocument.decode(values, fields: candidate.fields))
    }
}

struct SettingsValueChange {
    let path: [String]
    let old: SettingsLuauValue?
    let value: SettingsLuauValue?
    var summary: String {
        "\(path.joined(separator: ".")) = \(value?.literal() ?? "nil")"
    }

    enum Rows {
        case whole, positions
        case retained(SettingsListOrigins)

        func previous(_ old: [SettingsLuauValue], _ new: [SettingsLuauValue], at path: [String]) -> [Int?]? {
            switch self {
            case .whole: nil
            case .positions: old.count == new.count ? old.indices.map(Optional.some) : nil
            case let .retained(origins): origins[path] ?? SettingsListIdentity.match(path: path, old: old, new: new)
            }
        }
    }

    static func between(_ old: SettingsLuauValue, _ new: SettingsLuauValue, rows: Rows = .whole) -> [Self] {
        var result: [Self] = []
        func collect(_ old: SettingsLuauValue?, _ new: SettingsLuauValue?, at path: [String]) {
            guard old != new else { return }
            if case let .record(left) = old, case let .record(right) = new {
                for key in Set(left.keys).union(right.keys)
                    .sorted() { collect(left[key], right[key], at: path + [key]) }
            } else if case let .list(left) = old, case let .list(right) = new,
                      let previous = rows.previous(left, right, at: path), previous.count == right.count
            {
                for index in right.indices {
                    let before = previous[index].flatMap { left.indices.contains($0) ? left[$0] : nil }
                    collect(before, right[index], at: path + [String(index)])
                }
            } else {
                result.append(Self(path: path, old: old, value: new))
            }
        }
        collect(old, new, at: [])
        return result
    }
}

extension SettingsLuauDocument {
    func edit(
        from previous: SettingsExport,
        to desired: SettingsExport,
        origins: SettingsListOrigins = [:]
    ) throws -> SettingsLuauEdit {
        let (old, new) = try editableFields(from: previous, to: desired)
        let changes = SettingsValueChange.between(old, new)
        let newline = source.range(of: Data("\r\n".utf8)) == nil ? "\n" : "\r\n"
        var plan = SettingsTableEdit(document: self, origins: origins, newline: newline)
        let output: Data
        var planned = sourceValue
        if let field = fields[[]] {
            let root = SettingsTableEdit.Node(source: [], model: [], raw: sourceValue, old: old, new: new)
            var updated = source
            if let replacement = try plan.rewrite(root, within: field.bytes) {
                updated.replaceSubrange(field.bytes, with: replacement.text.utf8)
                planned = replacement.value
            }
            output = updated
        } else if let first = returnSites.first, !changes.isEmpty {
            var tree = try SettingsLuauValue.fields(of: export)
            for change in changes { tree.set(change.value, at: change.path[...]) }
            tree.set(nil, at: ["schemaVersion"])
            output = replaceReturns(
                with: tree,
                changes: changes,
                insertion: first.insertion,
                plan: &plan
            )
            planned = tree
            plan.fixed.append([])
        } else if changes.isEmpty {
            output = source
        } else {
            throw SettingsLuauError(
                message: "Settings cannot locate a writable return value. Edit settings.luau directly."
            )
        }
        guard !plan.questions.isEmpty else { return SettingsLuauEdit(source: output, question: nil, expected: nil) }
        let expected = try SettingsLuauValue.fields(of: Self.decode(planned, fields: fields))
        plan.includeOtherChanges(changes)
        return SettingsLuauEdit(
            source: output,
            question: plan.questions.joined(separator: "\n\n"),
            expected: expected,
            fixedPaths: plan.fixed + SettingsValueChange.between(
                old,
                new,
                rows: .retained(origins)
            ).map(\.path)
        )
    }

    private func editableFields(
        from previous: SettingsExport,
        to desired: SettingsExport
    ) throws -> (SettingsLuauValue, SettingsLuauValue) {
        guard previous.hotkeyBindings != desired.hotkeyBindings else {
            return try (.fields(of: previous), .fields(of: desired))
        }
        let saved = Set(export.hotkeyBindings.map(\.id))
        func fields(of model: SettingsExport) throws -> SettingsLuauValue {
            var persisted = model
            persisted.hotkeyBindings.removeAll { binding in
                binding.binding.isUnassigned && binding.modeKey == nil && !saved.contains(binding.id) &&
                    ActionCatalog.dynamicSpec(for: binding.id) != nil
            }
            return try .fields(of: persisted)
        }
        return try (fields(of: previous), fields(of: desired))
    }

    private func replaceReturns(
        with tree: SettingsLuauValue,
        changes: [SettingsValueChange],
        insertion: Int,
        plan: inout SettingsTableEdit
    ) -> Data {
        let literal = tree.literal().replacingOccurrences(of: "\n", with: plan.newline)
        let requested = changes.map(\.summary).joined(separator: "\n")
        var name = "omniSettings"
        while source
            .range(of: Data(name.utf8)) != nil
        { name = "omniSettings_" + UUID().uuidString.replacingOccurrences(
            of: "-",
            with: ""
        ) }
        let locations = returnSites.map { site in
            "Line \(site.line): " + String(decoding: source[site.bytes], as: UTF8.self)
        }
        plan.questions
            .append(
                "Make all returned settings editable? Your edit:\n\(requested)\n\nEvery return below will use one new local table, \(name).\n\(locations.joined(separator: "\n"))\n\nThese values will be fixed:\n\(literal)"
            )
        var output = source
        for site in returnSites.sorted(by: { $0.bytes.lowerBound > $1.bytes.lowerBound }) {
            output.replaceSubrange(
                site.bytes,
                with: preservingComments(in: site.bytes, before: name, newline: plan.newline).utf8
            )
        }
        output.insert(contentsOf: "local \(name) = \(literal)\(plan.newline)".utf8, at: insertion)
        return output
    }

    func preservingComments(in range: Range<Int>, before literal: String, newline: String) -> String {
        let retained = comments.filter { range.lowerBound <= $0.lowerBound && $0.upperBound <= range.upperBound }
        guard !retained.isEmpty else { return literal }
        let start = source[..<range.lowerBound].lastIndex(of: 10).map { $0 + 1 } ?? 0
        let indent = String(decoding: source[start ..< range.lowerBound].prefix { $0 == 32 || $0 == 9 }, as: UTF8.self)
        return retained.map { String(decoding: source[$0], as: UTF8.self) + newline + indent }.joined() + literal
    }
}

extension SettingsLuauValue {
    mutating func set(_ value: Self?, at path: ArraySlice<String>) {
        guard let key = path.first else { return }
        if case var .list(rows) = self, let index = Int(key), rows.indices.contains(index) {
            if path.count > 1 { rows[index].set(value, at: path.dropFirst()) }
            else if let value { rows[index] = value }
            self = .list(rows)
            return
        }
        guard case var .record(fields) = self else { return }
        if path.count == 1 {
            fields[key] = value
        } else {
            var child = fields[key] ?? .record([:])
            child.set(value, at: path.dropFirst())
            fields[key] = child
        }
        self = .record(fields)
    }
}
