// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@preconcurrency import CoreGraphics
import Foundation

extension HotkeyCenter {
    typealias WindowSwitcherTapFactory = (
        CGEventTapLocation, CGEventTapPlacement, CGEventTapOptions, CGEventMask, CGEventTapCallBack,
        UnsafeMutableRawPointer?
    ) -> CFMachPort?

    func beginExternalWindowSwitcherSession(
        holding flags: CGEventFlags,
        createTap: WindowSwitcherTapFactory = CGEvent.tapCreate
    ) -> UInt64? {
        guard !commandHotkeysSuspended, keyboardModeInput.kind == .normal,
              setupExternalWindowSwitcherTapIfNeeded(createTap: createTap)
        else { return nil }
        windowSwitcherInput.beginExternalSession(holding: flags)
        return windowSwitcherInput.generation
    }

    func cancelWindowSwitcherSession(generation: UInt64) {
        windowSwitcherInput.cancel(generation: generation)
        releaseExternalWindowSwitcherTapIfIdle()
        if !windowSwitcherInput.holdsKeyboard(for: .shortcut), !keyboardTapRequiredOutsideModes {
            updateEventTapEnablement()
        }
    }

    func handleWindowSwitcherEvent(type: CGEventType, event: CGEvent, source: WindowSwitcherInput.Source) -> Bool {
        let decision = windowSwitcherInput.handle(
            type: type,
            keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            canBegin: isRunning && windowSwitcherEnabled && !commandHotkeysSuspended
                && keyboardModeInput.kind == .normal,
            source: source
        )
        if let action = decision.action { onWindowSwitcherAction?(action, windowSwitcherInput.generation) }
        return decision.consumed
    }

    private func setupExternalWindowSwitcherTapIfNeeded(createTap: WindowSwitcherTapFactory) -> Bool {
        if let externalWindowSwitcherTap {
            if !CGEvent.tapIsEnabled(tap: externalWindowSwitcherTap) {
                CGEvent.tapEnable(tap: externalWindowSwitcherTap, enable: true)
            }
            return true
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated {
                center.handleExternalWindowSwitcherEvent(type: type, event: event)
            }
        }
        guard let tap = createTap(
            .cgSessionEventTap, .tailAppendEventTap, .defaultTap, CGEventMask(mask), callback,
            Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        externalWindowSwitcherTap = tap
        externalWindowSwitcherRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    private func handleExternalWindowSwitcherEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            InputTapHealth.recordTapDisabled(mouse: false, byTimeout: type == .tapDisabledByTimeout)
            let wasActive = windowSwitcherInput.activeSource == .external
            windowSwitcherInput.reset(.external)
            if wasActive { onWindowSwitcherAction?(.cancel, windowSwitcherInput.generation) }
            scheduleExternalWindowSwitcherTapRelease()
            return Unmanaged.passUnretained(event)
        }
        let consumed = handleWindowSwitcherEvent(type: type, event: event, source: .external)
        if consumed, type == .keyUp, !windowSwitcherInput.holdsKeyboard(for: .external) {
            scheduleExternalWindowSwitcherTapRelease()
        }
        return consumed ? nil : Unmanaged.passUnretained(event)
    }

    private func scheduleExternalWindowSwitcherTapRelease() {
        DispatchQueue.main.async { [weak self] in self?.releaseExternalWindowSwitcherTapIfIdle() }
    }

    func releaseExternalWindowSwitcherTapIfIdle() {
        guard !windowSwitcherInput.holdsKeyboard(for: .external) else { return }
        EventTapTeardown.tearDown(tap: &externalWindowSwitcherTap, runLoopSource: &externalWindowSwitcherRunLoopSource)
    }
}
