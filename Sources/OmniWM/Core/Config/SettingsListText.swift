// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct SettingsListText {
    let layout: SettingsTableText
    private let positions: [Int]
    private let allNumbered: Bool

    init(_ layout: SettingsTableText) {
        self.layout = layout
        let items = layout.table.items
        guard items.contains(where: { $0.indexToken != nil }) else {
            positions = []
            allNumbered = false
            return
        }
        var positions = Array(items.indices)
        for (index, item) in items.enumerated() {
            if let logical = item.listIndex { positions[logical] = index }
        }
        self.positions = positions
        allNumbered = items.allSatisfy { $0.indexToken != nil }
    }

    func item(at index: Int) -> SettingsSourceTable.Item {
        layout.table.items[positions.isEmpty ? index : positions[index]]
    }

    func render(_ rows: [SettingsTableText.Row], fileOrder: [Int]? = nil) -> String {
        guard !positions.isEmpty else { return layout.render(rows) }
        let unchangedOrder = positions.count == rows.count && rows.enumerated()
            .allSatisfy { $0.offset == $0.element.origin }
        var implicit = 0
        var physical: [SettingsTableText.Row] = []
        for slot in rows.indices {
            let index = fileOrder?[slot] ?? slot
            let row = rows[index]
            guard let old = row.origin else {
                let numbered = fileOrder != nil || allNumbered || index != implicit
                if !numbered { implicit += 1 }
                physical.append(.init(text: (numbered ? "[\(index + 1)] = " : "") + (row.text ?? "")))
                continue
            }
            let position = positions[old]
            let item = layout.table.items[position]
            var prefix: String?
            if !unchangedOrder {
                if let token = item.indexToken {
                    if old != index {
                        prefix = source(item.bytes.lowerBound ..< token.lowerBound) + String(index + 1)
                            + source(token.upperBound ..< item.value.lowerBound)
                    }
                } else if index == implicit {
                    implicit += 1
                } else {
                    prefix = "[\(index + 1)] = "
                }
            }
            let replacement: String?
            if row.text != nil || prefix != nil {
                replacement = (prefix ?? source(item.bytes.lowerBound ..< item.value.lowerBound))
                    + (row.text ?? source(item.value))
            } else {
                replacement = nil
            }
            physical.append(.init(origin: position, text: replacement))
        }
        if unchangedOrder, fileOrder == nil {
            physical.sort { ($0.origin ?? 0) < ($1.origin ?? 0) }
        }
        return layout.render(physical)
    }

    private func source(_ range: Range<Int>) -> String {
        String(decoding: layout.document.source[range], as: UTF8.self)
    }
}
