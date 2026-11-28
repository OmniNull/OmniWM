// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMAutomation

enum ShellDrawerName {
    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func problem(_ name: String, drawers: [String], widgets: [String]) -> String? {
        let name = normalized(name)
        if name.isEmpty { return String(localized: "Enter a drawer name.") }
        if name.contains(where: \.isWhitespace) { return String(localized: "Drawer names can't contain spaces.") }
        if name.contains(".") { return String(localized: "Drawer names can't contain periods.") }
        if name.utf8.count > ShellRuntimeLimits.keyLimit { return String(localized: "This drawer name is too long.") }
        if !ShellComponentCatalog.validName(name) {
            return String(localized: "Drawer names can't contain /, \\, : or control characters.")
        }
        if drawers.contains(name) { return String(localized: "This style already has a drawer named \(name).") }
        if widgets.contains(name) { return String(localized: "\(name) is a widget name. Choose another name.") }
        return nil
    }

    static func editable(_ id: String) -> Bool {
        !id.contains(".")
    }

    static func widgets(_ layout: ShellBarLayout, config: ShellConfig) -> [String] {
        layout.widgets.map(\.name) + [config.hiddenBarWidget, config.island?.root].compactMap(\.self)
            + ShellBarLayout.internalWidgets
    }
}
