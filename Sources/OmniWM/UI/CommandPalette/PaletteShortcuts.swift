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
        case let .mode(mode):
            String(
                localized: "While the command palette is open, \(chord) switches to \(mode.localizedDisplayName) mode instead."
            )
        case .togglePreview:
            String(localized: "While the command palette is open, \(chord) toggles the file preview instead.")
        case .reveal:
            String(
                localized: "While the command palette is open, \(chord) reveals the selected item in Finder instead."
            )
        case .setMark:
            String(localized: "While the command palette is open, \(chord) marks the selected window instead.")
        case .removeMark:
            String(
                localized: "While the command palette is open, \(chord) removes a mark from the selected window instead."
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
    private static let markModifiers = UInt32(controlKey | optionKey | shiftKey)

    let chords: [PaletteShortcutChord]

    init(modifier: PaletteModifier, keyCodeForLetter: (Character) -> UInt32?) {
        func chord(_ shortcut: PaletteShortcut, _ keyCode: UInt32, _ modifiers: UInt32) -> PaletteShortcutChord {
            PaletteShortcutChord(shortcut: shortcut, binding: KeyBinding(keyCode: keyCode, modifiers: modifiers))
        }
        func letter(_ character: Character, ansi: Int) -> UInt32 {
            keyCodeForLetter(character) ?? UInt32(ansi)
        }
        let mask = modifier.carbonMask
        chords = Self.modeKeyCodes.flatMap { mode, keyCodes in
            keyCodes.map { chord(.mode(mode), UInt32($0), mask) }
        } + [
            chord(.togglePreview, letter("y", ansi: kVK_ANSI_Y), mask),
            chord(.reveal, UInt32(kVK_Return), mask),
            chord(.reveal, UInt32(kVK_ANSI_KeypadEnter), mask),
            chord(.reveal, letter("r", ansi: kVK_ANSI_R), mask),
            chord(.setMark, UInt32(kVK_ANSI_M), Self.markModifiers),
            chord(.removeMark, UInt32(kVK_ANSI_R), Self.markModifiers)
        ]
    }

    static func current(
        modifier: PaletteModifier,
        layoutLookup: (UInt32) -> (Character) -> UInt32? = KeyboardLayoutKeyCode.current(modifiers:)
    ) -> PaletteShortcuts {
        PaletteShortcuts(modifier: modifier, keyCodeForLetter: layoutLookup(modifier.carbonMask & UInt32(shiftKey)))
    }

    func collisions(with trigger: HotkeyTrigger) -> [PaletteShortcutChord] {
        guard let binding = trigger.chordBinding else { return [] }
        return chords.filter { $0.binding.conflicts(with: binding) }
    }
}
