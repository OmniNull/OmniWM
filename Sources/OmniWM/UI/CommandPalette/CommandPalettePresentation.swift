// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation
import SwiftUI

enum CommandPalettePresentation {
    static let unavailableMenuStatusText =
        String(localized: "Open the palette while another app is frontmost to search its menus.")

    struct InlineHint: Equatable {
        let title: String
        let shortcut: String
    }

    static func menuModeAvailable(hasMenuFocusTarget: Bool) -> Bool {
        hasMenuFocusTarget
    }

    static func availableMenuStatusText(for appName: String?) -> String {
        String(localized: "Searching menus in \(appName ?? String(localized: "Current App"))")
    }

    static func modeHint(for mode: CommandPaletteMode) -> InlineHint {
        switch mode {
        case .windows:
            InlineHint(title: mode.localizedDisplayName, shortcut: "⌘1")
        case .menu:
            InlineHint(title: mode.localizedDisplayName, shortcut: "⌘2")
        case .clipboard:
            InlineHint(title: mode.localizedDisplayName, shortcut: "⌘3")
        case .commands:
            InlineHint(title: mode.localizedDisplayName, shortcut: "⌘4")
        }
    }

    static func modeNavigationTarget(
        currentMode: CommandPaletteMode,
        isMenuModeAvailable: Bool,
        keyCode: UInt16,
        relevantModifiers: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) -> CommandPaletteMode? {
        if relevantModifiers == .command {
            switch charactersIgnoringModifiers {
            case "1":
                return .windows
            case "2":
                return isMenuModeAvailable ? .menu : nil
            case "3":
                return .clipboard
            case "4":
                return .commands
            default:
                return nil
            }
        }

        guard keyCode == UInt16(kVK_Tab),
              relevantModifiers.isEmpty || relevantModifiers == .shift
        else {
            return nil
        }

        let availableModes = CommandPaletteMode.allCases.filter {
            $0 != .menu || isMenuModeAvailable
        }
        guard let currentIndex = availableModes.firstIndex(of: currentMode) else {
            return availableModes.first
        }

        let offset = relevantModifiers == .shift ? -1 : 1
        let targetIndex = (currentIndex + offset + availableModes.count) % availableModes.count
        return availableModes[targetIndex]
    }

    static func selectedWindowHint(isSummonRightAvailable: Bool) -> InlineHint? {
        guard isSummonRightAvailable else { return nil }
        return InlineHint(title: String(localized: "Summon Right"), shortcut: "⇧↩")
    }

    static func allowsSummonRight(_ item: CommandPaletteWindowItem) -> Bool {
        !item.isAppHidden
    }

    static func windowsStatusText(
        selectedItem: CommandPaletteWindowItem?,
        isSummonRightAvailable: Bool
    ) -> String {
        if selectedItem?.isAppHidden == true {
            return String(localized: "Return · Unhide & Focus")
        }

        return isSummonRightAvailable
            ? String(localized: "Enter jumps. Shift-Enter summons right.")
            : String(localized: "Enter jumps. Shift-Enter unavailable for this session.")
    }
}

extension CommandPaletteMode {
    var localizedDisplayName: String {
        switch self {
        case .windows: String(localized: "Windows")
        case .menu: String(localized: "Menu")
        case .clipboard: String(localized: "Clipboard")
        case .commands: String(localized: "Commands")
        }
    }
}
