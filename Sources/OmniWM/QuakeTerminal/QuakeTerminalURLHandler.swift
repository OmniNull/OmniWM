// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import GhosttyKit

@MainActor
enum QuakeTerminalURLHandler {
    static func handle(
        _ action: ghostty_action_open_url_s,
        open: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Bool {
        guard action.kind == GHOSTTY_ACTION_OPEN_URL_KIND_OSC8 else { return false }
        guard let count = Int(exactly: action.len), count > 0,
              let string = String(data: Data(bytes: action.url, count: count), encoding: .utf8),
              let url = hyperlinkURL(string)
        else {
            Log.terminal.notice("Blocked an unsupported or malformed terminal hyperlink")
            return true
        }

        if !open(url) {
            Log.terminal.error("Failed to open terminal hyperlink")
        }
        return true
    }

    private static func hyperlinkURL(_ string: String) -> URL? {
        let unsafeCharacters = CharacterSet.controlCharacters.union(.whitespacesAndNewlines)
        guard !string.unicodeScalars.contains(where: unsafeCharacters.contains),
              let url = URL(string: string, encodingInvalidCharacters: false),
              let scheme = url.scheme?.lowercased() else { return nil }

        switch scheme {
        case "http",
             "https":
            guard let host = url.host, !host.isEmpty else { return nil }
        case "mailto":
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  !components.path.isEmpty else { return nil }
        default:
            return nil
        }
        return url
    }
}
