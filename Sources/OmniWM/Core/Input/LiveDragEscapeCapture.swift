// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import CoreGraphics
import Foundation

@MainActor
final class LiveDragEscapeCapture {
    private(set) var isActive = false
    var installsEventTap = true

    private var onEscape: (() -> Void)?
    private var swallowsEscapeKeyUp = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    isolated deinit {
        stop()
    }

    func start(onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
        isActive = true
        if installsEventTap, tap == nil {
            installTap()
        }
    }

    func stop() {
        isActive = false
        onEscape = nil
        guard swallowsEscapeKeyUp else {
            EventTapTeardown.tearDown(tap: &tap, runLoopSource: &runLoopSource)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.swallowsEscapeKeyUp = false
            self?.tearDownIfStopped()
        }
    }

    func consumesKeyEvent(type: CGEventType, keyCode: Int64) -> Bool {
        guard keyCode == Int64(kVK_Escape) else { return false }
        switch type {
        case .keyDown:
            guard isActive else { return false }
            swallowsEscapeKeyUp = true
            let onEscape = onEscape
            DispatchQueue.main.async {
                onEscape?()
            }
            return true
        case .keyUp:
            guard isActive || swallowsEscapeKeyUp else { return false }
            swallowsEscapeKeyUp = false
            if !isActive {
                DispatchQueue.main.async { [weak self] in
                    self?.tearDownIfStopped()
                }
            }
            return true
        default:
            return false
        }
    }

    private func tearDownIfStopped() {
        guard !isActive, !swallowsEscapeKeyUp else { return }
        EventTapTeardown.tearDown(tap: &tap, runLoopSource: &runLoopSource)
    }

    private func installTap() {
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let capture = Unmanaged<LiveDragEscapeCapture>.fromOpaque(userInfo).takeUnretainedValue()
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let consumed = MainActor.assumeIsolated {
                capture.handleTapEvent(type: type, keyCode: keyCode)
            }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap else {
            FallbackFiringRecorder.shared.note(.input, "liveDragEscapeTapCreateFailed")
            return
        }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let runLoopSource else {
            EventTapTeardown.tearDown(tap: &self.tap, runLoopSource: &self.runLoopSource)
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleTapEvent(type: CGEventType, keyCode: Int64) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        return consumesKeyEvent(type: type, keyCode: keyCode)
    }
}
