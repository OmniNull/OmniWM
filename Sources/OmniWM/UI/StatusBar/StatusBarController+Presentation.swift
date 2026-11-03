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

    nonisolated static func statusButtonAccessibilityValue(
        workspaceLabel: String?,
        focusedAppName: String?,
        isRecording: Bool,
        isSecureInputActive: Bool,
        layout: ActiveLayoutKind? = nil
    ) -> String {
        var components: [String] = []
        if isRecording {
            components.append(String(localized: "Recording diagnostics"))
        }
        if isSecureInputActive {
            components.append(String(localized: "Secure Input is on"))
        }
        if let workspaceLabel, !workspaceLabel.isEmpty {
            components.append(String(localized: "Workspace \(workspaceLabel)"))
        }
        if let focusedAppName, !focusedAppName.isEmpty {
            components.append(String(localized: "Focused app \(focusedAppName)"))
        }
        if let layout {
            components.append(Self.layoutDisplayName(layout))
        }
        return components.isEmpty ? String(localized: "Window manager controls") : components
            .joined(separator: String(localized: ", "))
    }

    static func statusButtonImage(icon: NSImage?, layout: ActiveLayoutKind?) -> NSImage? {
        guard let layout else { return icon }
        let symbol = switch layout {
        case .niri: "rectangle.split.3x1"
        case .dwindle: "rectangle.split.2x2"
        }
        guard let layoutImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        else { return icon }
        let iconWidth = icon?.size.width ?? 0
        let spacing: CGFloat = icon == nil ? 0 : 5
        let height = max(icon?.size.height ?? 0, layoutImage.size.height)
        let isTemplate = icon?.isTemplate ?? true
        let image = NSImage(
            size: NSSize(width: iconWidth + spacing + layoutImage.size.width, height: height),
            flipped: false
        ) { _ in
            if let icon {
                icon.draw(in: NSRect(
                    x: 0,
                    y: (height - icon.size.height) / 2,
                    width: iconWidth,
                    height: icon.size.height
                ))
            }
            let layoutRect = NSRect(
                x: iconWidth + spacing,
                y: (height - layoutImage.size.height) / 2,
                width: layoutImage.size.width,
                height: layoutImage.size.height
            )
            if isTemplate {
                layoutImage.draw(in: layoutRect)
            } else {
                let coloredLayout = layoutImage.withSymbolConfiguration(.init(paletteColors: [.labelColor]))
                    ?? layoutImage
                coloredLayout.draw(in: layoutRect)
            }
            return true
        }
        image.isTemplate = isTemplate
        return image
    }
}
