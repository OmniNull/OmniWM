// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension StatusBarController {
    static func statusButtonTitle(
        workspaceLabel: String?,
        focusedAppName: String?,
        modeTitle: String? = nil
    ) -> String {
        var title = workspaceLabel.map { " \($0)" } ?? ""
        if let focusedAppName, !focusedAppName.isEmpty {
            title += " \u{2013} \(truncatedStatusBarAppName(focusedAppName))"
        }
        if let modeTitle {
            title = " \(modeTitle)" + (title.isEmpty ? "" : " \u{00B7}" + title)
        }
        return title
    }

    nonisolated static func layoutDisplayName(_ layout: ActiveLayoutKind) -> String {
        switch layout {
        case .niri: String(localized: "Niri (Scrolling)")
        case .dwindle: String(localized: "Dwindle (BSP)")
        }
    }

    static func statusButtonAttributedTitle(
        _ title: String,
        layout: ActiveLayoutKind?,
        font: NSFont
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: title, attributes: [.font: font])
        guard let layout else { return result }
        let symbol = switch layout {
        case .niri: "rectangle.split.3x1"
        case .dwindle: "rectangle.split.2x2"
        }
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular))
        else { return result }
        image.isTemplate = true
        let height = font.capHeight + 2
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0,
            y: floor((font.capHeight - height) / 2),
            width: height * image.size.width / image.size.height,
            height: height
        )
        result.append(NSAttributedString(string: " "))
        result.append(NSAttributedString(attachment: attachment))
        return result
    }
}
