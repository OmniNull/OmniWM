// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
import CoreGraphics

enum WindowSwitcherAction: Equatable, Sendable {
    case begin(reverse: Bool, scope: WindowSwitcherScope? = nil)
    case cycle(reverse: Bool)
    case toggleScope
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
    private var heldModifier = CGEventFlags.maskCommand

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
            guard isActive, !flags.contains(heldModifier) else { return Decision() }
            isActive = false
            return Decision(action: .commit)
        }
        guard type == .keyDown else { return Decision() }
        if !isActive {
            if suppressedKeys.contains(keyCode) { return Decision(consumed: true) }
            guard canBegin, keyCode == kVK_Tab, !isRepeat,
                  let shortcut = shortcut(for: flags)
            else { return Decision() }
            heldModifier = flags.contains(.maskCommand) ? .maskCommand : .maskAlternate
            isActive = true
            generation &+= 1
            suppressedKeys.insert(keyCode)
            return Decision(
                consumed: true,
                action: .begin(reverse: flags.contains(.maskShift), scope: shortcut.initialScope)
            )
        }
        suppressedKeys.insert(keyCode)
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
            return Decision(consumed: true, action: isRepeat ? nil : .toggleScope)
        case kVK_Return,
             kVK_ANSI_KeypadEnter:
            isActive = false
            return Decision(consumed: true, action: .commit)
        case kVK_Escape:
            isActive = false
            return Decision(consumed: true, action: .cancel)
        default:
            return Decision(consumed: true)
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
