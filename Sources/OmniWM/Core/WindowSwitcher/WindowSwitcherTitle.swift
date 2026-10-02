// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum WindowSwitcherTitle {
    static func label(appName: String, title: String) -> String {
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        var detail = title.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.hasPrefix("/") {
            detail = (detail as NSString).lastPathComponent
        }
        guard !detail.isEmpty, detail.caseInsensitiveCompare(app) != .orderedSame else { return app }
        for separator in [" — ", " – ", " - "] {
            if detail.hasPrefix(app + separator) { return detail }
            if detail.hasSuffix(separator + app) {
                detail.removeLast(separator.count + app.count)
                break
            }
        }
        return "\(app) — \(detail)"
    }
}
