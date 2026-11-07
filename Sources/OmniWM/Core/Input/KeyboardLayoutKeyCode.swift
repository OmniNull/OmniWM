// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation

enum KeyboardLayoutKeyCode {
    static func current(commandHeld: Bool) -> (Character) -> UInt32? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return { _ in nil } }
        let layoutData = withExtendedLifetime(source) {
            Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        }
        let modifierState = commandHeld ? UInt32(cmdKey >> 8) : 0
        let keyboardType = UInt32(LMGetKbdType())
        var keyCodes: [Character: UInt32] = [:]
        layoutData.withUnsafeBytes { bytes in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for keyCode in UInt16(0) ..< 128 {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout,
                    keyCode,
                    UInt16(kUCKeyActionDown),
                    modifierState,
                    keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                guard status == noErr,
                      let character = String(decoding: characters.prefix(length), as: UTF16.self)
                          .lowercased().first,
                      length == 1,
                      keyCodes[character] == nil
                else { continue }
                keyCodes[character] = UInt32(keyCode)
            }
        }
        return { keyCodes[$0] }
    }
}
