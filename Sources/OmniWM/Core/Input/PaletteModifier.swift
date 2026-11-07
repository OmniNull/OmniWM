// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon

struct PaletteModifier: Equatable, Hashable, Sendable {
    static let allModifierFlags: [UInt32] = [
        UInt32(controlKey), UInt32(optionKey), UInt32(shiftKey), UInt32(cmdKey)
    ]
    static let `default` = PaletteModifier(uncheckedCarbonMask: UInt32(cmdKey))

    let carbonMask: UInt32

    private init(uncheckedCarbonMask: UInt32) {
        carbonMask = uncheckedCarbonMask
    }

    init?(carbonMask: UInt32) {
        let allowedMask = Self.allModifierFlags.reduce(UInt32(0)) { $0 | $1 }
        guard carbonMask != 0,
              carbonMask & ~allowedMask == 0,
              carbonMask != UInt32(shiftKey)
        else { return nil }
        self.carbonMask = carbonMask
    }

    func contains(_ flag: UInt32) -> Bool {
        carbonMask & flag != 0
    }

    func setting(_ flag: UInt32, included: Bool) -> PaletteModifier? {
        PaletteModifier(carbonMask: included ? carbonMask | flag : carbonMask & ~flag)
    }

    var mayBlockTypedCharacters: Bool {
        carbonMask == UInt32(optionKey)
    }

    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(UInt32(controlKey)) { flags.insert(.control) }
        if contains(UInt32(optionKey)) { flags.insert(.option) }
        if contains(UInt32(shiftKey)) { flags.insert(.shift) }
        if contains(UInt32(cmdKey)) { flags.insert(.command) }
        return flags
    }

    var humanReadableString: String {
        KeySymbolMapper.literalModifierNames(carbonMask).joined(separator: "+")
    }

    var symbolsString: String {
        KeySymbolMapper.literalModifierSymbols(carbonMask)
    }

    static func fromHumanReadable(_ string: String) -> PaletteModifier? {
        var mask: UInt32 = 0
        for part in string.components(separatedBy: "+") {
            let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let flag = KeySymbolMapper.baseModifierFlag(named: name) else { return nil }
            mask |= flag
        }
        return PaletteModifier(carbonMask: mask)
    }
}

extension PaletteModifier: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let modifier = PaletteModifier.fromHumanReadable(try container.decode(String.self)) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid command palette modifier")
            )
        }
        self = modifier
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(humanReadableString)
    }
}
