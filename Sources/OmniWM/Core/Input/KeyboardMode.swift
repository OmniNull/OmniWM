// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import CoreGraphics
import Foundation

enum KeyboardModeKind: String, Equatable, Sendable {
    case normal
    case paused
    case prefix
    case window
    case named
}

enum KeyboardModeKeyFailure: Equatable {
    case duplicateKey
    case overlapsShortcut
    case unsupportedKey
}

struct KeyboardModeTable: Equatable {
    struct Entry: Equatable {
        let binding: KeyBinding
        let command: HotkeyCommand
        let repeatWhileHeld: Bool

        init(binding: KeyBinding, command: HotkeyCommand, repeatWhileHeld: Bool = false) {
            self.binding = binding
            self.command = command
            self.repeatWhileHeld = repeatWhileHeld
        }

        var isSupported: Bool {
            KeyboardModeTable.isEligible(command) && KeyboardModeTable.isSupported(binding)
        }

        func conflicts(with other: Self) -> Bool {
            command != other.command && binding == other.binding
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var failures: [HotkeyCommand: KeyboardModeKeyFailure] = [:]
    private var shortcuts: [KeyBinding] = []

    var isEmpty: Bool {
        entries.isEmpty
    }

    init(bindings: [HotkeyBinding] = []) {
        let candidates = bindings.compactMap { binding in
            binding.modeKey.map { Entry(binding: $0, command: binding.command) }
        }
        guard !candidates.isEmpty else { return }
        shortcuts = bindings.compactMap(\.binding.chordBinding)
        for candidate in candidates {
            if !candidate.isSupported {
                failures[candidate.command] = .unsupportedKey
            } else if shortcuts.contains(where: { $0.conflicts(with: candidate.binding) }) {
                failures[candidate.command] = .overlapsShortcut
            } else if candidates.contains(where: candidate.conflicts(with:)) {
                failures[candidate.command] = .duplicateKey
            } else {
                entries.append(candidate)
            }
        }
    }

    static func isSupported(_ key: KeyBinding) -> Bool {
        !key.isUnassigned
            && key.sidedModifiers.isEmpty
            && key.modifiers & ~UInt32(shiftKey) == 0
            && key.keyCode != UInt32(kVK_Escape)
    }

    static func isEligible(_ command: HotkeyCommand) -> Bool {
        if case .keyboardMode = command { return false }
        return true
    }

    func command(keyCode: UInt32, rawFlags: UInt64) -> HotkeyCommand? {
        entries.first {
            CommandHotkeyTapMatcher.matches($0.binding, keyCode: keyCode, rawFlags: rawFlags)
        }?.command
    }

    func isShortcut(keyCode: UInt32, rawFlags: UInt64) -> Bool {
        shortcuts.contains { CommandHotkeyTapMatcher.matches($0, keyCode: keyCode, rawFlags: rawFlags) }
    }
}

struct KeyboardModeInput: Equatable {
    enum State: Equatable {
        case normal
        case paused
        case prefix(repeatDeadline: TimeInterval?)
        case window
        case named(Int)
    }

    struct Decision: Equatable {
        var consumed = false
        var command: HotkeyCommand?
        var heldBinding: KeyBinding?
    }

    static let repeatWindow: TimeInterval = 0.5
    private static let commandModifierMask = CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue

    var state = State.normal

    var kind: KeyboardModeKind {
        Self.kind(of: state)
    }

    var capturesKeys: Bool {
        Self.capturesKeys(in: state)
    }

    static func kind(of state: State) -> KeyboardModeKind {
        switch state {
        case .normal: .normal
        case .paused: .paused
        case .prefix: .prefix
        case .window: .window
        case .named: .named
        }
    }

    static func capturesKeys(in state: State) -> Bool {
        switch state {
        case .prefix,
             .window,
             .named:
            true
        case .normal,
             .paused:
            false
        }
    }

    mutating func handleNamedKeyDown(
        keyCode: UInt32,
        rawFlags: UInt64,
        mode index: Int,
        in modes: borrowing NamedKeyModes
    ) -> Decision {
        if rawFlags & Self.commandModifierMask != 0 { return Decision() }
        if keyCode == UInt32(kVK_Escape) {
            state = .normal
            return Decision(consumed: true)
        }
        guard let slot = modes.entryIndex(in: index, keyCode: keyCode, rawFlags: rawFlags) else { return Decision() }
        let held = modes.modes[index].entries[slot].repeatWhileHeld
            ? modes.modes[index].entries[slot].binding : nil
        return Decision(consumed: true, command: modes.modes[index].entries[slot].command, heldBinding: held)
    }

    mutating func handleKeyDown(
        keyCode: UInt32,
        rawFlags: UInt64,
        isRepeat: Bool,
        now: TimeInterval,
        table: KeyboardModeTable
    ) -> Decision {
        guard capturesKeys, !isRepeat else { return Decision() }
        if case let .prefix(deadline?) = state, now >= deadline {
            state = .normal
            return Decision()
        }
        if rawFlags & Self.commandModifierMask != 0 {
            if case .prefix = state { state = .normal }
            return Decision()
        }
        if keyCode == UInt32(kVK_Escape) {
            state = .normal
            return Decision(consumed: true)
        }
        if table.isShortcut(keyCode: keyCode, rawFlags: rawFlags) {
            if case .prefix = state { state = .normal }
            return Decision()
        }
        let command = table.command(keyCode: keyCode, rawFlags: rawFlags)
        switch state {
        case .prefix(repeatDeadline: nil):
            guard let command else {
                state = .normal
                return Decision(consumed: true)
            }
            state = command.repeatsInPrefix ? .prefix(repeatDeadline: now + Self.repeatWindow) : .normal
            return Decision(consumed: true, command: command)
        case .prefix(repeatDeadline: .some):
            guard let command, command.repeatsInPrefix else {
                state = .normal
                return Decision()
            }
            state = .prefix(repeatDeadline: now + Self.repeatWindow)
            return Decision(consumed: true, command: command)
        case .window:
            return Decision(consumed: true, command: command)
        case .normal,
             .paused,
             .named:
            return Decision()
        }
    }
}
