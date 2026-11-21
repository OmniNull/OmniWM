// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

enum ShellCommandPaletteBadgeTone: String, Sendable {
    case neutral
    case accent
    case danger
    case warning
    case shortcut
    case shortcutMuted
}

enum ShellCommandPaletteRowKind: String, Sendable {
    case window
    case command
    case heading
    case menu
    case clipboard
    case application
    case file
    case saved
    case showAll
    case executable
    case gridRow
}

struct ShellCommandPaletteData: Equatable, Sendable, ShellValueWritable {
    struct Mode: Equatable, Sendable {
        var id: String
        var title: String
        var symbol: String
        var shortcut: String
        var selected: Bool
        var enabled: Bool
    }

    struct Badge: Equatable, Sendable {
        var text: String
        var tone: ShellCommandPaletteBadgeTone
        var symbol: String?
    }

    struct Icon: Equatable, Sendable {
        var app: String?
        var pid: Int32?
        var symbol: String?
        var bitmap: String?
    }

    struct Row: Equatable, Sendable {
        var id: String
        var kind: ShellCommandPaletteRowKind
        var title: String
        var subtitle: String
        var icon: Icon
        var badges: [Badge]
        var marks: [Badge]
        var hint: String?
        var hintShortcut: String?
        var selected: Bool
        var enabled: Bool
        var pinned = false
        var actions: [Action] = []
        var cells: [Row] = []
    }

    struct Action: Equatable, Sendable {
        var id: String
        var title: String
        var symbol: String
        var shortcut: String
    }

    struct Preview: Equatable, Sendable, ShellValueWritable {
        var id: String
        var state: String
        var text: String?
        var image: String?
        var width = 0.0
        var height = 0.0
        var title: String?
        var symbol: String?
        var details: [Detail] = []

        func write(into writer: inout ShellValueWriter) {
            writer.map(9)
            writer.key("id")
            writer.string(id)
            writer.key("state")
            writer.string(state)
            writer.key("text")
            ShellCommandPaletteData.write(text, into: &writer)
            writer.key("image")
            ShellCommandPaletteData.write(image, into: &writer)
            writer.key("width")
            writer.number(width)
            writer.key("height")
            writer.number(height)
            writer.key("title")
            ShellCommandPaletteData.write(title, into: &writer)
            writer.key("symbol")
            ShellCommandPaletteData.write(symbol, into: &writer)
            ShellCommandPaletteData.write(details, key: "details", into: &writer)
        }
    }

    struct Detail: Equatable, Sendable, ShellValueWritable {
        var label: String
        var value: String

        func write(into writer: inout ShellValueWriter) {
            writer.map(2)
            writer.key("label")
            writer.string(label)
            writer.key("value")
            writer.string(value)
        }
    }

    var open = false
    var expanded = false
    var width = 0.0
    var height = 0.0
    var mode = ""
    var modes: [Mode] = []
    var placeholder = ""
    var query = ""
    var state = "results"
    var emptyText = ""
    var emptySymbol = ""
    var feedback: String?
    var actions: [Action] = []
    var rows: [Row] = []
    var selected = ""
    var first = 0
    var total = 0
    var before = 0.0
    var after = 0.0
    var unified = false
    var browseModes = false
    var error: String?
    var preview: Preview?
    var launcher: Launcher?
    var emptyAction: Action?

    struct Launcher: Equatable, Sendable, ShellValueWritable {
        var filters: [Mode] = []
        var chips: [Mode] = []
        var views: [Mode] = []
        var add: Action?
        var columns = 1
        var grid = false

        func write(into writer: inout ShellValueWriter) {
            writer.map(6)
            ShellCommandPaletteData.write(filters, key: "filters", into: &writer)
            ShellCommandPaletteData.write(chips, key: "chips", into: &writer)
            ShellCommandPaletteData.write(views, key: "views", into: &writer)
            writer.key("add")
            if let add { add.write(into: &writer) } else { writer.null() }
            writer.key("columns")
            writer.number(Double(columns))
            writer.key("grid")
            writer.bool(grid)
        }
    }

    func write(into writer: inout ShellValueWriter) {
        writer.map(25)
        writer.key("open")
        writer.bool(open)
        writer.key("expanded")
        writer.bool(expanded)
        writer.key("width")
        writer.number(width)
        writer.key("height")
        writer.number(height)
        writer.key("mode")
        writer.string(mode)
        writer.key("modes")
        writer.array(modes.count)
        for mode in modes {
            mode.write(into: &writer)
        }
        writer.key("placeholder")
        writer.string(placeholder)
        writer.key("query")
        writer.string(query)
        writer.key("state")
        writer.string(state)
        writer.key("emptyText")
        writer.string(emptyText)
        writer.key("emptySymbol")
        writer.string(emptySymbol)
        writer.key("feedback")
        Self.write(feedback, into: &writer)
        writer.key("actions")
        writer.array(actions.count)
        for action in actions {
            action.write(into: &writer)
        }
        writeResults(into: &writer)
    }

    private func writeResults(into writer: inout ShellValueWriter) {
        writer.key("rows")
        writer.array(rows.count)
        for row in rows {
            row.write(into: &writer)
        }
        writer.key("selected")
        writer.string(selected)
        writer.key("first")
        writer.number(Double(first))
        writer.key("total")
        writer.number(Double(total))
        writer.key("before")
        writer.number(before)
        writer.key("after")
        writer.number(after)
        writer.key("unified")
        writer.bool(unified)
        writer.key("browseModes")
        writer.bool(browseModes)
        writer.key("error")
        Self.write(error, into: &writer)
        writer.key("preview")
        if let preview { preview.write(into: &writer) } else { writer.null() }
        writer.key("launcher")
        if let launcher { launcher.write(into: &writer) } else { writer.null() }
        writer.key("emptyAction")
        if let emptyAction { emptyAction.write(into: &writer) } else { writer.null() }
    }

    fileprivate static func write(_ value: String?, into writer: inout ShellValueWriter) {
        if let value { writer.string(value) } else { writer.null() }
    }

    fileprivate static func write(
        _ values: [some ShellValueWritable],
        key: String,
        into writer: inout ShellValueWriter
    ) {
        writer.key(key)
        writer.array(values.count)
        for value in values {
            value.write(into: &writer)
        }
    }
}

extension ShellCommandPaletteData.Mode: ShellValueWritable {
    func write(into writer: inout ShellValueWriter) {
        writer.map(6)
        writer.key("id")
        writer.string(id)
        writer.key("title")
        writer.string(title)
        writer.key("symbol")
        writer.string(symbol)
        writer.key("shortcut")
        writer.string(shortcut)
        writer.key("selected")
        writer.bool(selected)
        writer.key("enabled")
        writer.bool(enabled)
    }
}

extension ShellCommandPaletteData.Badge: ShellValueWritable {
    func write(into writer: inout ShellValueWriter) {
        writer.map(3)
        writer.key("text")
        writer.string(text)
        writer.key("tone")
        writer.string(tone.rawValue)
        writer.key("symbol")
        ShellCommandPaletteData.write(symbol, into: &writer)
    }
}

extension ShellCommandPaletteData.Icon: ShellValueWritable {
    func write(into writer: inout ShellValueWriter) {
        writer.map(4)
        writer.key("app")
        ShellCommandPaletteData.write(app, into: &writer)
        writer.key("pid")
        if let pid { writer.number(Double(pid)) } else { writer.null() }
        writer.key("symbol")
        ShellCommandPaletteData.write(symbol, into: &writer)
        writer.key("bitmap")
        ShellCommandPaletteData.write(bitmap, into: &writer)
    }
}

extension ShellCommandPaletteData.Row: ShellValueWritable {
    func write(into writer: inout ShellValueWriter) {
        writer.map(14)
        writer.key("id")
        writer.string(id)
        writer.key("kind")
        writer.string(kind.rawValue)
        writer.key("title")
        writer.string(title)
        writer.key("subtitle")
        writer.string(subtitle)
        writer.key("icon")
        icon.write(into: &writer)
        writer.key("badges")
        writer.array(badges.count)
        for badge in badges {
            badge.write(into: &writer)
        }
        writer.key("marks")
        writer.array(marks.count)
        for mark in marks {
            mark.write(into: &writer)
        }
        writer.key("hint")
        ShellCommandPaletteData.write(hint, into: &writer)
        writer.key("hintShortcut")
        ShellCommandPaletteData.write(hintShortcut, into: &writer)
        writer.key("selected")
        writer.bool(selected)
        writer.key("enabled")
        writer.bool(enabled)
        writer.key("pinned")
        writer.bool(pinned)
        writer.key("actions")
        writer.array(actions.count)
        for action in actions { action.write(into: &writer) }
        writer.key("cells")
        writer.array(cells.count)
        for cell in cells { cell.write(into: &writer) }
    }
}

extension ShellCommandPaletteData.Action: ShellValueWritable {
    func write(into writer: inout ShellValueWriter) {
        writer.map(4)
        writer.key("id")
        writer.string(id)
        writer.key("title")
        writer.string(title)
        writer.key("symbol")
        writer.string(symbol)
        writer.key("shortcut")
        writer.string(shortcut)
    }
}
