// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

struct ShellHiddenBarItem: Equatable, Sendable {
    let id: String
    let name: String
    let image: String?
    let width: Double
    let height: Double
}

struct ShellHiddenBarData: Equatable, Sendable {
    var enabled = false
    var available = false
    var rehide = 5.0
    var items: [ShellHiddenBarItem] = []
    var maxWidth = 0.0
    var maxHeight = 0.0
    var cell = 20.0
    var vertical = false
    var menu: HiddenBarMenuPage?

    func write(into writer: inout ShellValueWriter) {
        writer.map(9)
        writer.key("menu")
        if let menu {
            menu.write(into: &writer)
        } else {
            writer.null()
        }
        writer.key("maxWidth")
        writer.number(maxWidth)
        writer.key("maxHeight")
        writer.number(maxHeight)
        writer.key("cell")
        writer.number(cell)
        writer.key("vertical")
        writer.bool(vertical)
        writer.key("enabled")
        writer.bool(enabled)
        writer.key("available")
        writer.bool(available)
        writer.key("rehide")
        writer.number(rehide)
        writer.key("items")
        writer.array(items.count)
        for item in items {
            writer.map(5)
            writer.key("id")
            writer.string(item.id)
            writer.key("name")
            writer.string(item.name)
            writer.key("image")
            if let image = item.image {
                writer.string(image)
            } else {
                writer.null()
            }
            writer.key("w")
            writer.number(item.width)
            writer.key("h")
            writer.number(item.height)
        }
    }
}

extension HiddenBarMenuPage {
    func write(into writer: inout ShellValueWriter) {
        writer.map(3)
        writer.key("title")
        writer.string(title ?? "")
        writer.key("backID")
        if let backID {
            writer.string(backID)
        } else {
            writer.null()
        }
        writer.key("rows")
        writer.array(rows.count)
        for row in rows {
            writer.map(7)
            writer.key("id")
            writer.string(row.id)
            writer.key("title")
            writer.string(row.title)
            writer.key("enabled")
            writer.bool(row.enabled)
            writer.key("mark")
            writer.string(row.mark ?? "")
            writer.key("shortcut")
            writer.string(row.shortcut ?? "")
            writer.key("submenu")
            writer.bool(row.submenu)
            writer.key("separator")
            writer.bool(row.separator)
        }
    }
}
