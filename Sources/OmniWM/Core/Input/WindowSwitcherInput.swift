// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import CoreGraphics

enum WindowSwitcherAction: Equatable, Sendable {
    case begin(reverse: Bool, scope: WindowSwitcherScope? = nil)
    case cycle(reverse: Bool)
    case cycleScope
    case close
    case moveRow(reverse: Bool)
    case commit
    case cancel
}

struct WindowSwitcherInput {
    struct Decision: Equatable {
        var consumed = false
        var action: WindowSwitcherAction?
    }

    private(set) var isActive = false
    private(set) var generation: UInt64 = 0
    private var suppressedKeys: Set<Int> = []
    var shortcuts = WindowSwitcherShortcuts()
    private var heldModifiers = CGEventFlags.maskCommand
    private var passesUnhandledKeys = false

    static let releaseModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]

    var holdsKeyboard: Bool {
        isActive || !suppressedKeys.isEmpty
    }

    mutating func beginExternalSession(holding flags: CGEventFlags) {
        heldModifiers = flags.intersection(Self.releaseModifiers)
        passesUnhandledKeys = true
        isActive = true
        generation &+= 1
    }

    mutating func cancel(generation: UInt64) {
        guard generation == self.generation else { return }
        isActive = false
    }

    mutating func reset() {
        isActive = false
        suppressedKeys.removeAll()
    }

    mutating func handle(
        type: CGEventType,
        keyCode: Int,
        flags: CGEventFlags,
        isRepeat: Bool,
        canBegin: Bool
    ) -> Decision {
        if type == .keyUp {
            return Decision(consumed: suppressedKeys.remove(keyCode) != nil)
        }
        if type == .flagsChanged {
            guard isActive, !flags.contains(heldModifiers) else { return Decision() }
            isActive = false
            return Decision(action: .commit)
        }
        guard type == .keyDown else { return Decision() }
        if !isActive {
            if suppressedKeys.contains(keyCode) { return Decision(consumed: true) }
            guard canBegin, keyCode == kVK_Tab, !isRepeat,
                  let shortcut = shortcut(for: flags)
            else { return Decision() }
            heldModifiers = flags.contains(.maskCommand) ? .maskCommand : .maskAlternate
            passesUnhandledKeys = false
            isActive = true
            generation &+= 1
            suppressedKeys.insert(keyCode)
            return Decision(
                consumed: true,
                action: .begin(reverse: flags.contains(.maskShift), scope: shortcut.initialScope)
            )
        }
        let decision = activeDecision(keyCode: keyCode, flags: flags, isRepeat: isRepeat)
        if decision.consumed { suppressedKeys.insert(keyCode) }
        return decision
    }

    private mutating func activeDecision(keyCode: Int, flags: CGEventFlags, isRepeat: Bool) -> Decision {
        switch keyCode {
        case kVK_Tab:
            return Decision(consumed: true, action: .cycle(reverse: flags.contains(.maskShift)))
        case kVK_LeftArrow:
            return Decision(consumed: true, action: .cycle(reverse: true))
        case kVK_RightArrow:
            return Decision(consumed: true, action: .cycle(reverse: false))
        case kVK_ANSI_W:
            return Decision(consumed: true, action: isRepeat ? nil : .close)
        case kVK_UpArrow:
            return Decision(consumed: true, action: .moveRow(reverse: true))
        case kVK_DownArrow:
            return Decision(consumed: true, action: .moveRow(reverse: false))
        case kVK_ANSI_S:
            return Decision(consumed: true, action: isRepeat ? nil : .cycleScope)
        case kVK_Return,
             kVK_ANSI_KeypadEnter:
            isActive = false
            return Decision(consumed: true, action: .commit)
        case kVK_Escape:
            isActive = false
            return Decision(consumed: true, action: .cancel)
        default:
            return Decision(consumed: !passesUnhandledKeys)
        }
    }

    private func shortcut(for flags: CGEventFlags) -> WindowSwitcherShortcutScope? {
        let modifiers = flags.intersection([.maskCommand, .maskAlternate, .maskControl])
        let shortcut: WindowSwitcherShortcutScope
        switch modifiers {
        case .maskCommand: shortcut = shortcuts.commandTab
        case .maskAlternate: shortcut = shortcuts.optionTab
        default: return nil
        }
        return shortcut == .disabled ? nil : shortcut
    }
}
