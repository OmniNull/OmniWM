// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMShellCore

extension CommandPaletteShellPresenter {
    func drawsPublishedList() -> Bool {
        guard let published, let container = surface.layout.handle(forKey: Self.resultsKey) else { return false }
        let leading = published.before > 0 ? 1 : 0
        let count = leading + published.rows.count + (published.after > 0 ? 1 : 0)
        var position = 0
        var matches = true
        surface.layout.core.forEachChild(of: container) { child, key in
            defer { position += 1 }
            guard matches, position < count else {
                matches = false
                return
            }
            let row = position - leading
            if row < 0 {
                matches = key == Self.beforeKey
                    && surface.layout.core.layoutFrame(of: child).height == Float(published.before)
            } else if row < published.rows.count {
                let item = published.rows[row]
                matches = key == ShellWidgetLayout.elementKey(item.id)
                    && (item.cells.isEmpty || draws(item.cells, in: child))
            } else {
                matches = key == Self.afterKey
                    && surface.layout.core.layoutFrame(of: child).height == Float(published.after)
            }
        }
        return matches && position == count
    }

    private func draws(_ cells: [ShellCommandPaletteData.Row], in row: ElementHandle) -> Bool {
        var index = 0
        var matches = true
        surface.layout.core.forEachChild(of: row) { _, key in
            matches = matches && index < cells.count && key == ShellWidgetLayout.elementKey(cells[index].id)
            index += 1
        }
        return matches && index == cells.count
    }
}
