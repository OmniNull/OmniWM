// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension HotkeyCenter {
    func dispatchCommandKeyDown(
        keyCode: UInt32, rawFlags: @autoclosure () -> UInt64, isRepeat: @autoclosure () -> Bool = false
    ) -> Bool {
        switch heldTapKeys.keyDown(keyCode, isRepeat: isRepeat) {
        case .suppress:
            return true
        case .ignore:
            return false
        case let .repeatInvocation(invocation):
            routeHotkeyInvocation(invocation)
            return true
        case .resolve:
            break
        }
        let rawFlags = rawFlags()
        if keyboardModeInput.capturesKeys, handleKeyboardModeKeyDown(keyCode: keyCode, rawFlags: rawFlags) {
            return true
        }
        if let entry = CommandHotkeyTapMatcher.firstMatch(
            keyCode: keyCode,
            rawFlags: rawFlags,
            entries: sideSpecificDispatch
        ) {
            if entry.onRelease || entry.repeatWhileHeld {
                heldTapKeys.record(entry.binding, command: entry.command, source: .sided, onRelease: entry.onRelease)
            } else {
                heldTapKeys.suppressed.insert(keyCode)
            }
            guard !entry.onRelease else { return true }
            InputTrace.record("hotkey.sided cmd=\(entry.command.displayName)")
            routeHotkeyInvocation(
                HotkeyInvocation(
                    command: entry.command,
                    trigger: PhysicalHotkeyTrigger(
                        keyCode: entry.binding.keyCode,
                        modifiers: entry.binding.modifiers,
                        isRepeat: false
                    )
                )
            )
            return true
        }
        recordSidedMiss(keyCode: keyCode, rawFlags: rawFlags)
        return false
    }

    private func recordSidedMiss(keyCode: UInt32, rawFlags: UInt64) {
        guard InputTrace.shared.isActive, !sideSpecificDispatch.isEmpty else { return }
        let down = KeySymbolMapper.sidedModifierLabel(rawFlags)
        guard !down.isEmpty else { return }
        let nearMiss = CommandHotkeyTapMatcher.nearMiss(
            keyCode: keyCode,
            rawFlags: rawFlags,
            entries: sideSpecificDispatch
        )
        InputTrace.record(
            "hotkey.sided.miss key=\(KeySymbolMapper.keySymbol(keyCode)) down=\(down) "
                + "closest=\(nearMiss?.entry.command.displayName ?? "none") "
                + "needs=\(nearMiss?.entry.binding.displayString ?? "-") "
                + "reason=\(nearMiss?.reason ?? "-")"
        )
    }
}
