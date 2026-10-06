// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation

enum SecureInputShortcutRisk {
    private static let trustedModifiers = UInt32(controlKey | cmdKey)
    private static let trustedKeypadKeyCodes = UInt32(kVK_ANSI_Keypad0) ... UInt32(kVK_ANSI_Keypad7)
    private static let gatedCharacters = CharacterSet.alphanumerics
        .union(.punctuationCharacters)
        .union(.symbols)

    static func isPaused(
        _ trigger: HotkeyTrigger,
        hyperTriggerConfigured: Bool,
        hyperModifiers: UInt32,
        shiftedCharacters: (UInt32) -> String?
    ) -> Bool {
        guard let chord = trigger.chordBinding, !chord.isUnassigned else { return false }
        if !chord.sidedModifiers.isEmpty { return true }
        if hyperTriggerConfigured, hyperModifiers != 0, chord.modifiers & hyperModifiers == hyperModifiers {
            return true
        }
        if chord.modifiers & trustedModifiers != 0 || trustedKeypadKeyCodes.contains(chord.keyCode) {
            return false
        }
        guard let characters = shiftedCharacters(chord.keyCode), !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy(gatedCharacters.contains)
    }

    static func currentLayoutShiftedCharacters() -> (UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return { _ in nil } }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        return { keyCode in
            layoutData.withUnsafeBytes { bytes -> String? in
                guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                    return nil
                }
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout,
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDown),
                    UInt32(shiftKey >> 8),
                    keyboardType,
                    0,
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                guard status == noErr, deadKeyState == 0, length > 0 else { return nil }
                return String(decoding: characters.prefix(length), as: UTF16.self)
            }
        }
    }
}
