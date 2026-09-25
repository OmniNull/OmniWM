// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import GhosttyKit

@MainActor
enum QuakeClipboardAlert {
    enum Kind: Equatable {
        case read
        case write
        case unsafePaste

        init?(_ request: ghostty_clipboard_request_e) {
            switch request {
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
                 GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ:
                self = .read
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
                 GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE:
                self = .write
            case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
                self = .unsafePaste
            default:
                return nil
            }
        }
    }

    static func make(
        kind: Kind,
        contents: String,
        programName: String? = nil,
        canRemember: Bool = false,
        previewImage: NSImage? = nil
    ) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let requester = programName.map { "\"\($0)\"" } ?? String(localized: "A terminal application")
        switch kind {
        case .read:
            alert.messageText = String(localized: "Allow Clipboard Read?")
            alert.informativeText = String(localized:
                "\(requester) wants to read the contents of the clipboard.")
        case .write:
            alert.messageText = String(localized: "Allow Clipboard Write?")
            alert.informativeText = String(localized:
                "\(requester) wants to replace the contents of the clipboard.")
        case .unsafePaste:
            alert.messageText = String(localized: "Allow Potentially Unsafe Paste?")
            alert.informativeText = String(localized:
                "The text being pasted contains characters that may run commands in the terminal.")
        }

        let preview = preview(contents)
        if !preview.isEmpty {
            alert.informativeText += "\n\n" + preview
        }
        if let previewImage {
            alert.icon = previewImage
        }
        if canRemember {
            alert.accessoryView = NSButton(
                checkboxWithTitle: String(localized: "Remember this choice for the session"),
                target: nil,
                action: nil
            )
        }
        alert.addButton(withTitle: String(localized: "Deny"))
        alert.addButton(withTitle: String(localized: "Allow"))
        return alert
    }

    static func responseAllows(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertSecondButtonReturn
    }

    private static func preview(_ contents: String) -> String {
        let limit = 200
        guard contents.count > limit else { return contents }
        return String(contents.prefix(limit)) + "…"
    }
}
