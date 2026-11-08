// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

let kcpasswordKey: [UInt8] = [0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F]
let encoded = FileHandle.standardInput.readDataToEndOfFile()
let password = String(
    decoding: encoded.enumerated().map { $1 ^ kcpasswordKey[$0 % kcpasswordKey.count] }.prefix { $0 != 0 },
    as: UTF8.self
)
let source = CGEventSource(stateID: .hidSystemState)

func press(_ key: CGKeyCode, typing character: UniChar? = nil) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
        if var character {
            event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
        }
        event?.post(tap: .cghidEventTap)
        usleep(15000)
    }
}

press(56)
usleep(300_000)
for character in password.utf16 {
    press(0, typing: character)
}

press(36)
