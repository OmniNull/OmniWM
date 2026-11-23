// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

extension SettingsTableEdit {
    private enum ListRow {
        case kept(source: Int, previous: Int, next: Int)
        case inserted(Int)
        case untouched(Int)

        var source: Int? {
            switch self {
            case let .kept(source, _, _),
                 let .untouched(source): source
            case .inserted: nil
            }
        }

        func value(raw: [SettingsLuauValue], old: [SettingsLuauValue], new: [SettingsLuauValue]) -> SettingsLuauValue {
            switch self {
            case let .untouched(source): raw[source]
            case let .inserted(next): new[next]
            case let .kept(source, previous, next): old[previous] == new[next] ? raw[source] : new[next]
            }
        }
    }

    mutating func list(
        _ node: Node,
        from old: [SettingsLuauValue],
        to new: [SettingsLuauValue],
        table: SettingsSourceTable
    ) throws -> Replacement {
        let raw = node.raw.listRows
        let native = SettingsListIdentity.sourceRows(path: node.model, rows: raw)
        let toSource = SettingsListIdentity.match(path: node.model, old: native, new: old)
        let previous = try previousIndices(node, old: old, new: new)
        var rows: [ListRow]
        if raw.isEmpty, node.model != ["hotkeys"] {
            rows = new.indices.map(ListRow.inserted)
        } else {
            rows = orderedRows(node, raw: native, mapping: toSource, previous: previous)
        }
        var fileOrder: [Int]?
        if node.model == ["workspaces"], !raw.isEmpty {
            (rows, fileOrder) = workspaceRows(rows, raw: raw, new: new, table: table)
        }
        var projected = rows.map { $0.value(raw: raw, old: old, new: new) }
        let identified = SettingsListIdentity.sourceRows(path: node.model, rows: projected)
        let layout = SettingsTableText(document: document, table: table, newline: newline)
        let listText = SettingsListText(layout)
        let retained = Set(rows.compactMap(\.source))
        for index in raw.indices where !retained.contains(index) {
            removing(raw[index], at: node.source + [String(index)], model: node.model + [String(index)])
        }
        var edited: [SettingsTableText.Row] = []
        for (index, row) in rows.enumerated() {
            switch row {
            case let .untouched(source):
                edited.append(.init(origin: source))
            case let .inserted(next):
                edited.append(.init(text: layout.literal(new[next])))
            case let .kept(source, previous, next):
                var child = Node(
                    source: node.source + [String(source)],
                    model: node.model + [String(next)],
                    raw: raw[source],
                    old: old[previous],
                    new: new[next]
                )
                child.retainIDIfNeeded(native: native[source], projected: identified[index])
                let replaced = try rewrite(child, within: listText.item(at: source).value)
                edited.append(.init(origin: source, text: replaced?.text))
                projected[index] = replaced?.value ?? raw[source]
            }
        }
        return Replacement(text: listText.render(edited, fileOrder: fileOrder), value: .list(projected))
    }

    private func workspaceRows(
        _ matched: [ListRow], raw: [SettingsLuauValue], new: [SettingsLuauValue], table: SettingsSourceTable
    ) -> ([ListRow], [Int]?) {
        func name(_ value: SettingsLuauValue) -> String {
            guard case let .string(name) = value["name"] else { return "" }
            return name
        }
        let logical = matched.sorted { ($0.source ?? .max) < ($1.source ?? .max) }
        let kept = Dictionary(uniqueKeysWithValues: logical.indices.compactMap { index in
            logical[index].source.map { ($0, index) }
        })
        let source = table.items.enumerated().map { $0.element.listIndex ?? $0.offset }
        var order = source.compactMap { kept[$0] }
        if kept.count < logical.count {
            let sorted = zip(source, source.dropFirst()).allSatisfy { !WorkspaceIDPolicy.sortsBefore(
                name(raw[$1]),
                name(raw[$0])
            ) }
            for index in logical.indices.dropFirst(kept.count) {
                if sorted {
                    WorkspaceSettings.insert(index, into: &order) { index in
                        switch logical[index] {
                        case let .untouched(source): name(raw[source])
                        case let .kept(_, _, next),
                             let .inserted(next): name(new[next])
                        }
                    }
                } else {
                    order.append(index)
                }
            }
        }
        if table.items.contains(where: { $0.indexToken != nil }) { return (logical, order) }
        return (order.map { logical[$0] }, nil)
    }

    private func previousIndices(_ node: Node, old: [SettingsLuauValue], new: [SettingsLuauValue]) throws -> [Int?] {
        guard let hints = origins[node.model] else { return SettingsListIdentity.match(
            path: node.model,
            old: old,
            new: new
        ) }
        let indices = hints.compactMap { $0 }
        guard hints.count == new.count, indices.allSatisfy(old.indices.contains),
              Set(indices).count == indices.count
        else {
            throw SettingsLuauError(
                message: "The rows of \(node.model.joined(separator: ".")) changed during this edit. Reopen the list and try again."
            )
        }
        return hints
    }

    private func orderedRows(
        _ node: Node,
        raw: [SettingsLuauValue],
        mapping toSource: [Int?],
        previous: [Int?]
    ) -> [ListRow] {
        guard case let .list(old) = node.old, case let .list(new) = node.new else { return [] }
        var result: [ListRow] = new.indices.compactMap { index in
            guard let before = previous[index] else { return .inserted(index) }
            if let source = toSource[before] { return .kept(source: source, previous: before, next: index) }
            return old[before] == new[index] ? nil : .inserted(index)
        }
        let kept = previous.compactMap { $0 }
        if kept == kept.sorted() {
            var existing = result.filter { $0.source != nil }.sorted { ($0.source ?? 0) < ($1.source ?? 0) }
                .makeIterator()
            for index in result.indices where result[index].source != nil {
                if let row = existing.next() { result[index] = row }
            }
        }
        let mapped = Set(toSource.compactMap { $0 })
        guard mapped.count < raw.count else { return result }
        let removedKeys = Set(old.map { SettingsListIdentity.key(for: $0, in: node.model) })
            .subtracting(new.map { SettingsListIdentity.key(for: $0, in: node.model) })
        for index in raw.indices where !mapped.contains(index) && !removedKeys.contains(SettingsListIdentity.key(
            for: raw[index],
            in: node.model
        )) {
            let next = result.firstIndex { ($0.source ?? -1) > index } ?? result.endIndex
            result.insert(.untouched(index), at: next)
        }
        return result
    }
}

extension SettingsTableEdit.Node {
    fileprivate mutating func retainIDIfNeeded(native: SettingsLuauValue, projected: SettingsLuauValue) {
        guard raw["id"] == nil, native["id"] != nil, old != new || projected["id"] != new["id"],
              case var .record(fields) = old else { return }
        fields.removeValue(forKey: "id")
        old = .record(fields)
    }
}

extension SettingsLuauValue {
    var listRows: [SettingsLuauValue] {
        if case let .list(rows) = self { return rows }
        return []
    }
}
