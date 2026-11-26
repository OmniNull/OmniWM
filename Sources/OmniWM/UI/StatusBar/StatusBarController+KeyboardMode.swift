// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension StatusBarController {
    nonisolated static func keyboardModeTitle(_ kind: KeyboardModeKind, name: String? = nil) -> String? {
        switch kind {
        case .normal: nil
        case .paused: String(localized: "Paused")
        case .prefix: String(localized: "Prefix")
        case .window: String(localized: "Window Mode")
        case .named: name ?? String(localized: "Key Mode")
        }
    }

    static func keyboardModeColor(_ kind: KeyboardModeKind) -> NSColor {
        kind == .paused ? .systemOrange : .systemGreen
    }

    static func keyboardModeStatusImage(_ kind: KeyboardModeKind, name: String? = nil) -> NSImage? {
        let symbol = switch kind {
        case .paused: "pause.circle.fill"
        case .window: "macwindow"
        case .normal,
             .prefix,
             .named: "keyboard"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: keyboardModeTitle(kind, name: name))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [keyboardModeColor(kind)]))
        image?.isTemplate = false
        return image
    }

    static func keyboardModeToolTip(_ kind: KeyboardModeKind, name: String? = nil) -> String? {
        switch kind {
        case .normal: nil
        case .paused: String(localized: "OmniWM shortcuts are paused.")
        case .prefix: String(localized: "Prefix: the next key runs an OmniWM command. Escape cancels.")
        case .window: String(localized: "Window mode: keys run OmniWM commands until you press Escape.")
        case .named: String(localized: "\(name ?? "Key") mode: its keys run their commands until you press Escape.")
        }
    }
}
