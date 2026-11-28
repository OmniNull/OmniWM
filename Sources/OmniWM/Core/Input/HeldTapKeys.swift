// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

struct HeldTapKeys: ~Copyable {
    enum Source {
        case named(Int)
        case sided
    }

    enum KeyDown {
        case resolve
        case ignore
        case suppress
        case repeatInvocation(HotkeyInvocation)
    }

    private enum Slot {
        case repeating(KeyBinding, HotkeyCommand, Source)
        case retired
    }

    private var slots = InlineArray<128, Slot?>(repeating: nil)
    private var occupied = 0
    var suppressed: Set<UInt32> = []

    var isEmpty: Bool {
        occupied == 0
    }

    var suppressedCount: Int {
        suppressed.count + occupied
    }

    var hasSuppressedKeys: Bool {
        !suppressed.isEmpty || !isEmpty
    }

    func contains(_ code: UInt32) -> Bool {
        !isEmpty && Int(code) < slots.count && slots[Int(code)] != nil
    }

    func keyDown(_ code: UInt32, isRepeat: () -> Bool) -> KeyDown {
        if suppressed.contains(code) { return .suppress }
        let repeats = isRepeat()
        guard contains(code) else { return repeats ? .ignore : .resolve }
        guard repeats, case let .repeating(binding, command, _) = slots[Int(code)] else { return .suppress }
        return .repeatInvocation(HotkeyInvocation(
            command: command,
            trigger: PhysicalHotkeyTrigger(keyCode: code, modifiers: binding.modifiers, isRepeat: true)
        ))
    }

    mutating func record(_ binding: KeyBinding, command: HotkeyCommand, source: Source) {
        let index = Int(binding.keyCode)
        precondition(index < slots.count)
        if slots[index] == nil { occupied += 1 }
        slots[index] = .repeating(binding, command, source)
    }

    mutating func release(_ code: UInt32) -> Bool {
        guard contains(code) else { return suppressed.remove(code) != nil }
        slots[Int(code)] = nil
        occupied -= 1
        return true
    }

    mutating func retire(where predicate: (KeyBinding, borrowing HotkeyCommand, Source) -> Bool) {
        guard !isEmpty else { return }
        for index in slots.indices {
            if case let .repeating(binding, command, source) = slots[index], predicate(binding, command, source) {
                slots[index] = .retired
            }
        }
    }

    mutating func clear() {
        guard !isEmpty else { return }
        for index in slots.indices { slots[index] = nil }
        occupied = 0
    }
}

extension HotkeyCenter {
    var suppressedHotkeyKeyCodes: Set<UInt32> {
        _read { yield heldTapKeys.suppressed }
        _modify { yield &heldTapKeys.suppressed }
    }

    func retireHeldBindings() {
        heldTapKeys.retire { _, _, _ in true }
        carbonRegistrations.retireRepeatBindings()
    }

    func retireRemovedSidedHolds() {
        heldTapKeys.retire { binding, command, source in
            guard case .sided = source else { return false }
            return !sideSpecificDispatch.contains {
                $0.repeatWhileHeld && $0.binding == binding && $0.command == command
            }
        }
    }

    func retireRemovedNamedHolds() {
        heldTapKeys.retire { binding, command, source in
            guard case let .named(id) = source else { return false }
            guard let index = namedKeyModes.index(of: id) else { return true }
            return !namedKeyModes.modes[index].entries.contains {
                $0.repeatWhileHeld && $0.binding == binding && $0.command == command
            }
        }
    }
}
