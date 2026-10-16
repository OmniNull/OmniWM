// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

struct ShellBarWindow: Equatable, Sendable {
    let id: String
    let title: String
    let focused: Bool
    let hidden: Bool
}

struct ShellBarItem: Equatable, Sendable {
    let id: String
    let bundle: String
    let name: String
    let focused: Bool
    let count: Int
    let hidden: Int
    var badge = ""
    var floating = false
    let windows: [ShellBarWindow]
}

struct ShellBarWorkspace: Equatable, Sendable {
    let id: String
    let name: String
    let focused: Bool
    let windows: [ShellBarItem]
}

struct ShellBarScratchpad: Equatable, Sendable {
    let id: Int
    let name: String
    let focused: Bool
    let revealed: Bool
    let visible: Bool
    let windows: [ShellBarItem]
    var compact = false
}

struct ShellBarStyle: Equatable, Sendable {
    var height: Double = 24
    var labels = true
    var backgrounds = true
    var accents = true
    var inactive: Double = -1
    var position = "top"
    var vertical = false
    var notch = "moveBelowMenuBar"
    var notchWidth: Double = 0
    var level = "statusBar"
    var offsetX: Double = 0
    var offsetY: Double = 0
    var autoHide = false
    var reveal = "off"
    var opacity: Double = 1
    var transparent = false
    var solidBlack = false
    var accentColor: String?
    var textColor: String?
    var statsButton = true
    var secureInput = false
    var previews = true
    var hideInFullscreen = true

    func write(to writer: inout ShellValueWriter) {
        let optional = { (value: String?) -> (inout ShellValueWriter) -> Void in
            { writer in value.map { writer.string($0) } ?? writer.null() }
        }
        let fields: [(String, (inout ShellValueWriter) -> Void)] = [
            ("height", { $0.number(height) }),
            ("labels", { $0.bool(labels) }),
            ("backgrounds", { $0.bool(backgrounds) }),
            ("accents", { $0.bool(accents) }),
            ("inactive", { $0.number(inactive) }),
            ("position", { $0.string(position) }),
            ("vertical", { $0.bool(vertical) }),
            ("notch", { $0.string(notch) }),
            ("notchWidth", { $0.number(notchWidth) }),
            ("level", { $0.string(level) }),
            ("offsetX", { $0.number(offsetX) }),
            ("offsetY", { $0.number(offsetY) }),
            ("autoHide", { $0.bool(autoHide) }),
            ("reveal", { $0.string(reveal) }),
            ("opacity", { $0.number(opacity) }),
            ("transparent", { $0.bool(transparent) }),
            ("solidBlack", { $0.bool(solidBlack) }),
            ("accentColor", optional(accentColor)),
            ("textColor", optional(textColor)),
            ("statsButton", { $0.bool(statsButton) }),
            ("secureInput", { $0.bool(secureInput) }),
            ("previews", { $0.bool(previews) }),
            ("hideInFullscreen", { $0.bool(hideInFullscreen) })
        ]
        writer.map(fields.count)
        for (key, value) in fields {
            writer.key(key)
            value(&writer)
        }
    }
}

struct ShellBarDrag: Equatable, Sendable {
    struct Gap: Equatable, Sendable {
        let workspace: String
        let before: Int
    }

    var sources: [String] = []
    var workspaces: [String] = []
    var icons: [String] = []
    var gaps: [Gap] = []

    func write(to writer: inout ShellValueWriter) {
        writer.map(4)
        for (key, values) in [("sources", sources), ("workspaces", workspaces), ("icons", icons)] {
            writer.key(key)
            writer.array(values.count)
            for value in values {
                writer.string(value)
            }
        }
        writer.key("gaps")
        writer.array(gaps.count)
        for gap in gaps {
            writer.map(2)
            writer.key("workspace")
            writer.string(gap.workspace)
            writer.key("before")
            writer.number(Double(gap.before))
        }
    }
}

struct ShellBarData: Equatable, Sendable {
    var monitor = ""
    var island = WorkspaceBarIslandSlice.all
    var badges = "off"
    var style = ShellBarStyle()
    var workspaces: [ShellBarWorkspace] = []
    var scratchpads: [ShellBarScratchpad] = []
    var drag: ShellBarDrag?
    var surface: ShellIslandData?

    func write(to writer: inout ShellValueWriter) {
        writer.map(7)
        writer.key("drag")
        if let drag {
            drag.write(to: &writer)
        } else {
            writer.null()
        }
        writer.key("monitor")
        writer.string(monitor)
        writer.key("island")
        writer.string(island.rawValue)
        writer.key("badges")
        writer.string(badges)
        writer.key("style")
        style.write(to: &writer)
        writer.key("workspaces")
        writer.array(workspaces.count)
        for workspace in workspaces {
            writer.map(4)
            writer.key("id")
            writer.string(workspace.id)
            writer.key("name")
            writer.string(workspace.name)
            writer.key("focused")
            writer.bool(workspace.focused)
            writer.key("windows")
            Self.write(workspace.windows, to: &writer)
        }
        writer.key("scratchpads")
        writer.array(scratchpads.count)
        for scratchpad in scratchpads {
            writer.map(7)
            writer.key("id")
            writer.number(Double(scratchpad.id))
            writer.key("compact")
            writer.bool(scratchpad.compact)
            writer.key("name")
            writer.string(scratchpad.name)
            writer.key("focused")
            writer.bool(scratchpad.focused)
            writer.key("revealed")
            writer.bool(scratchpad.revealed)
            writer.key("visible")
            writer.bool(scratchpad.visible)
            writer.key("windows")
            Self.write(scratchpad.windows, to: &writer)
        }
    }

    private static func write(_ items: [ShellBarItem], to writer: inout ShellValueWriter) {
        writer.array(items.count)
        for item in items {
            writer.map(9)
            writer.key("id")
            writer.string(item.id)
            writer.key("bundle")
            writer.string(item.bundle)
            writer.key("name")
            writer.string(item.name)
            writer.key("focused")
            writer.bool(item.focused)
            writer.key("count")
            writer.number(Double(item.count))
            writer.key("hidden")
            writer.number(Double(item.hidden))
            writer.key("badge")
            writer.string(item.badge)
            writer.key("floating")
            writer.bool(item.floating)
            writer.key("windows")
            writer.array(item.windows.count)
            for window in item.windows {
                writer.map(4)
                writer.key("id")
                writer.string(window.id)
                writer.key("title")
                writer.string(window.title)
                writer.key("focused")
                writer.bool(window.focused)
                writer.key("hidden")
                writer.bool(window.hidden)
            }
        }
    }
}

extension ShellBarData {
    func displayChanged(from previous: ShellBarData?) -> Bool {
        guard let previous else { return true }
        if monitor != previous.monitor || style.height != previous.style.height
            || style.vertical != previous.style.vertical || style.notchWidth != previous.style.notchWidth
        {
            return true
        }
        switch (surface, previous.surface) {
        case let (current?, old?):
            return current.display != old.display || current.size != old.size || current.notch != old.notch
                || current.menuBar != old.menuBar || current.scale != old.scale || current.main != old.main
        case (nil, nil): return false
        default: return true
        }
    }
}
