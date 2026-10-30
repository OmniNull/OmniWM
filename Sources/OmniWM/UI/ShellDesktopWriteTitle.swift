// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

enum ShellDesktopWriteTitle {
    @MainActor
    static func title(_ target: ShellSettingsWriteQueue.Target, editor: ShellDesktopEditor) -> String {
        let key = target.path.last ?? ""
        var parts = [editor.configuration.styleTitle(target.profile)]
        if let monitor = editor.monitors.first(where: { $0.id == target.monitor }) {
            parts.append(monitor.name)
        }
        if target.path.first == "widgets", target.path.count > 2 {
            let widget = target.path[1]
            parts.append(ShellBarLayout.title(of: widget))
            if let option = editor.schema(for: widget)?.options[key] {
                parts.append(editor.strings.title(option.title))
            } else {
                parts.append(ShellWidgetSettingsModel.title(key))
            }
        } else if target.path.first == "island", target.path.count > 2 {
            let id = target.path[1]
            parts.append(editor.componentTitle(id))
            parts.append(option(editor.componentDescriptor(id)?.options[key], fallback: key, strings: editor.strings))
        } else if target.path.first == "island-root" {
            parts.append(String(localized: "Island"))
            parts.append(option(editor.islandRootOptions[key], fallback: key, strings: editor.strings))
        } else if target.path.first == "drawer", target.path.count > 2 {
            parts.append(ShellBarLayout.title(of: target.path[1]))
            parts.append(drawerSetting(key))
        } else {
            parts.append(setting(key))
        }
        return parts.joined(separator: " · ")
    }

    private static func option(_ option: ShellComponentOption?, fallback: String, strings: ShellStrings) -> String {
        option.map { strings.title($0.title) } ?? ShellWidgetSettingsModel.title(fallback)
    }

    private static func setting(_ key: String) -> String {
        switch key {
        case "height": String(localized: "Bar Thickness")
        case "backgroundOpacity": String(localized: "Background Opacity")
        case "inactiveIconOpacity": String(localized: "Inactive Icon Opacity")
        case "notchActiveZoneWidth": String(localized: "Active Zone Width")
        case "notificationBadgeRefreshIntervalSeconds": String(localized: "Refresh Interval")
        case "autoHideRevealDelayMilliseconds": String(localized: "Auto-Hide Reveal Delay")
        case "autoHideHideDelayMilliseconds": String(localized: "Auto-Hide Hide Delay")
        case "revealHoldMilliseconds": String(localized: "Reveal Hold Delay")
        case "values": String(localized: "Background Effect")
        case "fps": String(localized: "Frame Rate")
        default: ShellWidgetSettingsModel.title(key)
        }
    }

    private static func drawerSetting(_ key: String) -> String {
        switch key {
        case "reach": String(localized: "Hover Area Depth")
        case "width": String(localized: "Hover Area Length")
        default: setting(key)
        }
    }
}
