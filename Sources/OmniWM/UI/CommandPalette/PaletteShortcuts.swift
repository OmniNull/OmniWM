// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon

enum PaletteShortcut: Equatable {
    case mode(CommandPaletteMode)
    case togglePreview
    case reveal
    case setMark
    case removeMark
}

struct PaletteShortcutChord: Equatable {
    let shortcut: PaletteShortcut
    let binding: KeyBinding

    var note: String {
        let chord = binding.displayString
        return switch shortcut {
        case .mode(.menu):
            String(
                localized: "While the command palette is open, \(chord) is reserved for switching to \(CommandPaletteMode.menu.localizedDisplayName) mode when it is available."
            )
        case let .mode(mode):
            String(
                localized: "While the command palette is open, \(chord) is reserved for switching to \(mode.localizedDisplayName) mode."
            )
        case .togglePreview:
            String(
                localized: "While the command palette is open, \(chord) is reserved for toggling the file preview in \(CommandPaletteMode.files.localizedDisplayName) mode."
            )
        case .reveal:
            String(
                localized: "While the command palette is open, \(chord) is reserved for revealing the selected item in Finder in \(CommandPaletteMode.applications.localizedDisplayName) and \(CommandPaletteMode.files.localizedDisplayName) modes; in other modes it acts like Return."
            )
        case .setMark:
            String(
                localized: "While the command palette is open, \(chord) is reserved for marking the selected window in \(CommandPaletteMode.windows.localizedDisplayName) mode."
            )
        case .removeMark:
            String(
                localized: "While the command palette is open, \(chord) is reserved for removing a mark from the selected window in \(CommandPaletteMode.windows.localizedDisplayName) mode."
            )
        }
    }
}

struct PaletteShortcuts {
    private static let modeKeyCodes: [(CommandPaletteMode, keyCodes: [Int])] = [
        (.windows, [kVK_ANSI_1, kVK_ANSI_Keypad1]),
        (.menu, [kVK_ANSI_2, kVK_ANSI_Keypad2]),
        (.clipboard, [kVK_ANSI_3, kVK_ANSI_Keypad3]),
        (.commands, [kVK_ANSI_4, kVK_ANSI_Keypad4]),
        (.applications, [kVK_ANSI_5, kVK_ANSI_Keypad5]),
        (.files, [kVK_ANSI_6, kVK_ANSI_Keypad6])
    ]
    private static let command = UInt32(cmdKey)
    private static let markModifiers = UInt32(controlKey | optionKey | shiftKey)
    private static let letters: InlineArray<2, UniChar> = [
        KeyboardLayoutKeyCode.letter("y"),
        KeyboardLayoutKeyCode.letter("r")
    ]

    let chords: [PaletteShortcutChord]

    init(previewKeyCode: UInt16?, revealKeyCode: UInt16?) {
        func chord(_ shortcut: PaletteShortcut, _ keyCode: UInt32, _ modifiers: UInt32) -> PaletteShortcutChord {
            PaletteShortcutChord(shortcut: shortcut, binding: KeyBinding(keyCode: keyCode, modifiers: modifiers))
        }
        let previewKey = previewKeyCode.map(UInt32.init) ?? UInt32(kVK_ANSI_Y)
        let revealKey = revealKeyCode.map(UInt32.init) ?? UInt32(kVK_ANSI_R)
        chords = Self.modeKeyCodes.flatMap { mode, keyCodes in
            keyCodes.map { chord(.mode(mode), UInt32($0), Self.command) }
        } + [
            chord(.togglePreview, previewKey, Self.command),
            chord(.reveal, UInt32(kVK_Return), Self.command),
            chord(.reveal, UInt32(kVK_ANSI_KeypadEnter), Self.command),
            chord(.reveal, revealKey, Self.command),
            chord(.setMark, UInt32(kVK_ANSI_M), Self.markModifiers),
            chord(.removeMark, UInt32(kVK_ANSI_R), Self.markModifiers)
        ]
    }

    static func current(
        layoutLookup: (InlineArray<2, UniChar>, UInt32) -> InlineArray<2, UInt16?> = KeyboardLayoutKeyCode
            .keyCodes(typing:modifiers:)
    ) -> PaletteShortcuts {
        let keyCodes = layoutLookup(letters, 0)
        return PaletteShortcuts(previewKeyCode: keyCodes[0], revealKeyCode: keyCodes[1])
    }

    func collisions(with trigger: HotkeyTrigger) -> [PaletteShortcutChord] {
        guard let binding = trigger.chordBinding else { return [] }
        return chords.filter { $0.binding.conflicts(with: binding) }
    }
}
