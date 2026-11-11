// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension HotkeyCenter {
    func beginExternalWindowSwitcherSession(holding flags: CGEventFlags) -> UInt64? {
        guard !commandHotkeysSuspended, keyboardModeInput.kind == .normal, setupHyperTriggerTapIfNeeded() else {
            return nil
        }
        windowSwitcherInput.beginExternalSession(holding: flags)
        updateEventTapEnablement()
        return windowSwitcherInput.generation
    }

    func cancelWindowSwitcherSession(generation: UInt64) {
        windowSwitcherInput.cancel(generation: generation)
        releaseWindowSwitcherTapIfIdle()
    }

    func handleWindowSwitcherEvent(type: CGEventType, event: CGEvent) -> Bool {
        let decision = windowSwitcherInput.handle(
            type: type,
            keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            canBegin: isRunning && windowSwitcherEnabled && !commandHotkeysSuspended
                && keyboardModeInput.kind == .normal
        )
        if let action = decision.action { onWindowSwitcherAction?(action, windowSwitcherInput.generation) }
        if decision.consumed, type == .keyUp, windowSwitcherMayReleaseTap {
            DispatchQueue.main.async { [weak self] in self?.releaseWindowSwitcherTapIfIdle() }
        }
        return decision.consumed
    }

    private var windowSwitcherMayReleaseTap: Bool {
        !windowSwitcherInput.holdsKeyboard && !(isRunning && keyboardTapRequiredOutsideModes)
    }

    private func releaseWindowSwitcherTapIfIdle() {
        guard windowSwitcherMayReleaseTap else { return }
        if isRunning {
            updateEventTapEnablement()
        } else {
            EventTapTeardown.tearDown(tap: &hyperTriggerTap, runLoopSource: &hyperTriggerRunLoopSource)
        }
    }
}
