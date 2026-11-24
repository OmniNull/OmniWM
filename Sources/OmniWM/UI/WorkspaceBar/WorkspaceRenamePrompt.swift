// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

/// Modal fallback for renaming a workspace when no workspace bar is available to anchor the inline rename panel.
@MainActor
enum WorkspaceRenamePrompt {
    static let title = String(localized: "Rename Workspace")
    static let confirmTitle = String(localized: "Save")
    static let cancelTitle = String(localized: "Cancel")

    static func requestName(currentName: String?, rawName: String) -> String? {
        let nameField = NSTextField(string: currentName ?? "")
        nameField.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        nameField.placeholderString = rawName
        nameField.setAccessibilityLabel(title)

        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = nameField
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle).keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = nameField

        guard CommandPaletteMarkModal.run(alert) == .alertFirstButtonReturn else { return nil }
        return nameField.stringValue
    }
}
