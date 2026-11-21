// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
enum LauncherEntryRemovalPrompt {
    static func confirm(
        _ entry: LauncherEntry, clearsShortcut: Bool, from window: NSWindow?,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard let window else { return completion(false) }
        makeAlert(entry: entry, clearsShortcut: clearsShortcut).beginSheetModal(for: window) { response in
            completion(response == .alertSecondButtonReturn)
        }
    }

    static func makeAlert(entry: LauncherEntry, clearsShortcut: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove “\(entry.name)”?")
        alert.informativeText = informativeText(clearsShortcut: clearsShortcut)
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        let remove = alert.addButton(withTitle: String(localized: "Remove"))
        remove.hasDestructiveAction = true
        remove.keyEquivalent = ""
        alert.window.defaultButtonCell = nil
        return alert
    }

    private static func informativeText(clearsShortcut: Bool) -> String {
        clearsShortcut
            ? String(
                localized: "This removes the saved launcher entry and clears its keyboard shortcut. Your apps and script files stay on disk."
            )
            : String(localized: "This removes the saved launcher entry. Your apps and script files stay on disk.")
    }
}
