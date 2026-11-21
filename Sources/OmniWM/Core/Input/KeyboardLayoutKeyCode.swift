// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon

enum KeyboardLayoutKeyCode {
    private static let maxCharacters = 4

    static func letter(_ scalar: Unicode.Scalar) -> UniChar {
        UniChar(scalar.value)
    }

    static func keyCodes<let count: Int>(
        typing letters: InlineArray<count, UniChar>,
        modifiers: UInt32
    ) -> InlineArray<count, UInt16?> {
        var keyCodes = InlineArray<count, UInt16?>(repeating: nil)
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return keyCodes }
        withExtendedLifetime(source) {
            guard let bytes = CFDataGetBytePtr(Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue())
            else { return }
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            withUnsafeTemporaryAllocation(of: UniChar.self, capacity: maxCharacters) { characters in
                guard let buffer = characters.baseAddress else { return }
                scan(layout, modifierState: modifiers >> 8, buffer: buffer, letters: letters, into: &keyCodes)
            }
        }
        return keyCodes
    }

    private static func scan<let count: Int>(
        _ layout: UnsafePointer<UCKeyboardLayout>,
        modifierState: UInt32,
        buffer: UnsafeMutablePointer<UniChar>,
        letters: InlineArray<count, UniChar>,
        into keyCodes: inout InlineArray<count, UInt16?>
    ) {
        let keyboardType = UInt32(LMGetKbdType())
        var remaining = count
        for keyCode in UInt16(0) ..< 128 {
            var deadKeyState: UInt32 = 0
            var length = 0
            guard UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDown),
                modifierState,
                keyboardType,
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                maxCharacters,
                &length,
                buffer
            ) == noErr, length == 1 else { continue }
            let typed = lowercased(buffer[0])
            for index in letters.indices where keyCodes[index] == nil && letters[index] == typed {
                keyCodes[index] = keyCode
                remaining -= 1
            }
            if remaining == 0 { return }
        }
    }

    private static func lowercased(_ character: UniChar) -> UniChar {
        (letter("A") ... letter("Z")).contains(character) ? character - letter("A") + letter("a") : character
    }
}
