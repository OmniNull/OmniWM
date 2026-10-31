// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

@MainActor
final class LiveDragModifierCapture {
    nonisolated static let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)

    private(set) var isActive = false
    var installsEventTap = true

    private var onModifiersChanged: ((CGEventFlags) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    isolated deinit {
        stop()
    }

    func start(onModifiersChanged: @escaping (CGEventFlags) -> Void) {
        self.onModifiersChanged = onModifiersChanged
        isActive = true
        if installsEventTap, tap == nil {
            installTap()
        }
    }

    func stop() {
        isActive = false
        onModifiersChanged = nil
        EventTapTeardown.tearDown(tap: &tap, runLoopSource: &runLoopSource)
    }

    func reportModifiersChanged(_ flags: CGEventFlags) {
        guard isActive, let onModifiersChanged else { return }
        DispatchQueue.main.async {
            onModifiersChanged(flags)
        }
    }

    private func installTap() {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let capture = Unmanaged<LiveDragModifierCapture>.fromOpaque(userInfo).takeUnretainedValue()
            let flags = event.flags
            MainActor.assumeIsolated {
                capture.handleTapEvent(type: type, flags: flags)
            }
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap else {
            FallbackFiringRecorder.shared.note(.input, "liveDragModifierTapCreateFailed")
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

    private func handleTapEvent(type: CGEventType, flags: CGEventFlags) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if type == .flagsChanged {
            reportModifiersChanged(flags)
        }
    }
}
