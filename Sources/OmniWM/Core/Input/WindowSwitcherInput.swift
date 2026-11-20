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
    enum Source {
        case shortcut
        case external
    }

    struct Decision: Equatable {
        var consumed = false
        var action: WindowSwitcherAction?
    }

    private(set) var activeSource: Source?
    private(set) var generation: UInt64 = 0
    private var suppressedKeys: [Int: Source] = [:]
    var shortcuts = WindowSwitcherShortcuts()
    private var heldModifiers = CGEventFlags.maskCommand

    static let releaseModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]

    var isActive: Bool {
        activeSource != nil
    }

    func holdsKeyboard(for source: Source) -> Bool {
        activeSource == source || suppressedKeys.values.contains(source)
    }

    func ownsKeyUp(_ keyCode: Int, source: Source) -> Bool {
        suppressedKeys[keyCode] == source
    }

    mutating func beginExternalSession(holding flags: CGEventFlags) {
        heldModifiers = flags.intersection(Self.releaseModifiers)
        activeSource = .external
        generation &+= 1
    }

    mutating func cancel(generation: UInt64) {
        guard generation == self.generation else { return }
        activeSource = nil
    }

    mutating func reset() {
        activeSource = nil
        suppressedKeys.removeAll()
    }

    mutating func reset(_ source: Source) {
        if activeSource == source { activeSource = nil }
        suppressedKeys = suppressedKeys.filter { $0.value != source }
    }

    mutating func handle(
        type: CGEventType,
        keyCode: Int,
        flags: CGEventFlags,
        isRepeat: Bool,
        canBegin: Bool,
        source: Source = .shortcut
    ) -> Decision {
        switch type {
        case .keyUp:
            guard suppressedKeys[keyCode] == source else { return Decision() }
            suppressedKeys.removeValue(forKey: keyCode)
            return Decision(consumed: true)
        case .flagsChanged:
            guard activeSource == source, !flags.contains(heldModifiers) else { return Decision() }
            activeSource = nil
            return Decision(action: .commit)
        case .keyDown:
            return handleKeyDown(keyCode: keyCode, flags: flags, isRepeat: isRepeat, canBegin: canBegin, source: source)
        default:
            return Decision()
        }
    }

    private mutating func handleKeyDown(
        keyCode: Int, flags: CGEventFlags, isRepeat: Bool, canBegin: Bool, source: Source
    ) -> Decision {
        if let owner = suppressedKeys[keyCode], owner != source { return Decision() }
        if activeSource == source {
            let decision = activeDecision(keyCode: keyCode, flags: flags, isRepeat: isRepeat)
            if decision.consumed { suppressedKeys[keyCode] = source }
            return decision
        }
        if suppressedKeys[keyCode] == source { return Decision(consumed: true) }
        guard activeSource == nil, source == .shortcut, canBegin, keyCode == kVK_Tab, !isRepeat,
              let shortcut = shortcut(for: flags)
        else { return Decision() }
        heldModifiers = flags.contains(.maskCommand) ? .maskCommand : .maskAlternate
        activeSource = .shortcut
        generation &+= 1
        suppressedKeys[keyCode] = source
        return Decision(
            consumed: true,
            action: .begin(reverse: flags.contains(.maskShift), scope: shortcut.initialScope)
        )
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
            activeSource = nil
            return Decision(consumed: true, action: .commit)
        case kVK_Escape:
            activeSource = nil
            return Decision(consumed: true, action: .cancel)
        default:
            return Decision(consumed: activeSource == .shortcut)
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
