// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

enum MenuShortcutFormatter {
    static func format(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(key.uppercased())
        return parts.joined()
    }

    static func format(attributes: [String: Any]) -> String? {
        guard let key = attributes["AXMenuItemCmdChar"] as? String, !key.isEmpty else { return nil }
        let flags = NSEvent.ModifierFlags.fromAXModifiers(attributes["AXMenuItemCmdModifiers"] as? Int)
        return format(key: key, modifiers: flags)
    }
}
