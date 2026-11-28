// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import CoreGraphics

struct NamedKeyModes: Equatable {
    struct Mode: Equatable {
        let id: Int
        let name: String
        let entries: [KeyboardModeTable.Entry]
        fileprivate let slots: [UInt8]

        init(id: Int, name: String, entries: [KeyboardModeTable.Entry]) {
            var slots = [UInt8](repeating: 0, count: NamedKeyModes.keyCodeLimit * 2)
            for (index, entry) in entries.enumerated() {
                if let slot = NamedKeyModes.slot(for: entry.binding) { slots[slot] = UInt8(index + 1) }
            }
            self.id = id
            self.name = name
            self.entries = entries
            self.slots = slots
        }
    }

    static let modeLimit = 16
    static let nameLimit = 32
    static let keyLimit = 64
    fileprivate static let keyCodeLimit = 128
    private static let reservedNames: Set<String> = ["normal", "paused", "prefix", "window"]
    private static let modifierKeyCodes: Set<UInt32> = [
        kVK_Shift, kVK_RightShift, kVK_Control, kVK_RightControl, kVK_Option, kVK_RightOption,
        kVK_Command, kVK_RightCommand, kVK_CapsLock, kVK_Function
    ].reduce(into: []) { $0.insert(UInt32($1)) }

    enum Entry: Equatable {
        case entered
        case alreadyActive
        case refused

        var result: ExternalCommandResult {
            switch self {
            case .entered: .executed
            case .alreadyActive: .noChange
            case .refused: .ignoredDisabled
            }
        }
    }

    private(set) var modes: [Mode] = []

    var isEmpty: Bool {
        modes.isEmpty
    }

    init() {}

    init(_ modes: [Mode]) {
        self.modes = modes
    }

    func index(of id: Int) -> Int? {
        modes.firstIndex { $0.id == id }
    }

    func command(in index: Int, keyCode: UInt32, rawFlags: UInt64) -> HotkeyCommand? {
        guard let slot = entryIndex(in: index, keyCode: keyCode, rawFlags: rawFlags) else { return nil }
        return modes[index].entries[slot].command
    }

    func entryIndex(in index: Int, keyCode: UInt32, rawFlags: UInt64) -> Int? {
        guard keyCode < UInt32(Self.keyCodeLimit) else { return nil }
        let shifted = rawFlags & CGEventFlags.maskShift.rawValue != 0 ? 1 : 0
        let slot = Int(modes[index].slots[Int(keyCode) << 1 | shifted])
        return slot == 0 ? nil : slot - 1
    }

    static func slot(for key: KeyBinding) -> Int? {
        guard KeyboardModeTable.isSupported(key), key.keyCode < UInt32(keyCodeLimit),
              !modifierKeyCodes.contains(key.keyCode)
        else { return nil }
        return Int(key.keyCode) << 1 | (key.modifiers & UInt32(shiftKey) != 0 ? 1 : 0)
    }

    static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1 ... nameLimit).contains(bytes.count), let first = bytes.first,
              (UInt8(ascii: "a") ... UInt8(ascii: "z")) ~= first,
              !reservedNames.contains(name)
        else { return false }
        return bytes.allSatisfy {
            (UInt8(ascii: "a") ... UInt8(ascii: "z")) ~= $0 || (UInt8(ascii: "0") ... UInt8(ascii: "9")) ~= $0
                || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_")
        }
    }
}
