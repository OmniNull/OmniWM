// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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

    enum MarkAction: Equatable {
        case set
        case remove
    }

    static let setMarkShortcut = "⌃⌥⇧M"
    static let removeMarkShortcut = "⌃⌥⇧R"

    static func markAction(
        forKeyCode keyCode: UInt16,
        relevantModifiers: NSEvent.ModifierFlags
    ) -> MarkAction? {
        guard relevantModifiers == [.control, .option, .shift] else { return nil }
        return switch keyCode {
        case UInt16(kVK_ANSI_M):
            .set
        case UInt16(kVK_ANSI_R):
            .remove
        default:
            nil
        }
    }

    static func menuModeAvailable(hasMenuFocusTarget: Bool) -> Bool {
        hasMenuFocusTarget
    }

    static func searchPlaceholder(for mode: CommandPaletteMode) -> String {
        switch mode {
        case .windows: String(localized: "Search windows...")
        case .menu: String(localized: "Search menu items...")
        case .clipboard: String(localized: "Search clipboard history...")
        case .commands: String(localized: "Search OmniWM commands...")
        case .applications: String(localized: "Search apps and saved entries...")
        case .files: String(localized: "Search files...")
        }
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
        case .applications:
            InlineHint(title: mode.localizedDisplayName, shortcut: "⌘5")
        case .files:
            InlineHint(title: mode.localizedDisplayName, shortcut: "⌘6")
        }
    }

    private static let modeDigitByKeyCode: [UInt16: String] = [
        UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_Keypad1): "1",
        UInt16(kVK_ANSI_2): "2", UInt16(kVK_ANSI_Keypad2): "2",
        UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_Keypad3): "3",
        UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_Keypad4): "4",
        UInt16(kVK_ANSI_5): "5", UInt16(kVK_ANSI_Keypad5): "5",
        UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_Keypad6): "6"
    ]

    static func topHitIndex(
        keyCode: UInt16,
        relevantModifiers: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) -> Int? {
        guard relevantModifiers == .command,
              let digit = (modeDigitByKeyCode[keyCode] ?? charactersIgnoringModifiers)
                  .flatMap({ $0.count == 1 ? Int($0) : nil }),
              (1 ... UnifiedSearch.topHitLimit).contains(digit)
        else { return nil }
        return digit - 1
    }

    static func topHitShortcut(at index: Int) -> String {
        "⌘\(index + 1)"
    }

    static func accessibilityValue(_ value: String, topHitShortcut: String?) -> String {
        guard let topHitShortcut else { return value }
        return String(localized: "\(value), top hit \(topHitShortcut)")
    }

    static func modeNavigationTarget(
        currentMode: CommandPaletteMode,
        isMenuModeAvailable: Bool,
        keyCode: UInt16,
        relevantModifiers: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) -> CommandPaletteMode? {
        if relevantModifiers == .command {
            switch modeDigitByKeyCode[keyCode] ?? charactersIgnoringModifiers {
            case "1":
                return .windows
            case "2":
                return isMenuModeAvailable ? .menu : nil
            case "3":
                return .clipboard
            case "4":
                return .commands
            case "5":
                return .applications
            case "6":
                return .files
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

    static func allowsSummonRight(
        _ item: CommandPaletteWindowItem,
        isTiling: Bool,
        isCurrentWorkspaceEmpty: Bool
    ) -> Bool {
        !item.isAppHidden && (isCurrentWorkspaceEmpty || isTiling)
    }

    static func windowsStatusText(
        selectedItem: CommandPaletteWindowItem?,
        isSummonRightAvailable: Bool,
        isSelectedWindowEligibleForSummon: Bool = true,
        isCurrentWorkspaceEmpty: Bool = false
    ) -> String {
        if selectedItem?.isAppHidden == true {
            return String(localized: "Return · Unhide & Focus")
        }

        let summonText = if isCurrentWorkspaceEmpty {
            String(localized: "Shift-Enter moves here (empty workspace).")
        } else if !isSelectedWindowEligibleForSummon {
            String(localized: "Shift-Enter unavailable for this window.")
        } else if isSummonRightAvailable {
            String(localized: "Shift-Enter summons right.")
        } else {
            String(localized: "Shift-Enter unavailable without an anchor.")
        }
        return String(localized: "Enter jumps. \(summonText)")
    }
}

extension CommandPaletteMode {
    var localizedDisplayName: String {
        switch self {
        case .windows: String(localized: "Windows")
        case .menu: String(localized: "Menu")
        case .clipboard: String(localized: "Clipboard")
        case .commands: String(localized: "Commands")
        case .applications: String(localized: "Launcher")
        case .files: String(localized: "Files")
        }
    }
}
