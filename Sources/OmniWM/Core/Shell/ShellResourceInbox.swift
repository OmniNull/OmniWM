// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Synchronization

final class ShellResourceInbox: Sendable {
    struct Capture: Equatable, Sendable {
        var id: UInt64 = 0
        var changedBegin = 0
        var changedEnd = 0
        var changedPeak = 0
        var wakes = ShellCaptureWakeCounters()

        var detail: String {
            "utility=resource_inbox changed_begin=\(changedBegin) changed_end=\(changedEnd) changed_peak=\(changedPeak)"
                + " " + wakes.detail
        }
    }

    private struct State {
        var attached: Set<ShellServiceOwner> = []
        var changed: Set<ShellServiceOwner> = []
        var wake: (@Sendable () -> Void)?
        var waking = false
        var closed = false
        var capture = Capture()
    }

    private let state = Mutex(State())

    func captureBegin(_ id: UInt64) {
        state.withLock {
            guard id != 0, $0.capture.id != id else { return }
            $0.capture = Capture(id: id, changedBegin: $0.changed.count, changedPeak: $0.changed.count)
        }
    }

    func captureEnd(_ id: UInt64) -> Capture? {
        state.withLock {
            guard id != 0, $0.capture.id == id else { return nil }
            $0.capture.changedEnd = $0.changed.count
            defer { $0.capture = Capture() }
            return $0.capture
        }
    }

    func captureWakeConsumed() {
        state.withLock { if $0.capture.id != 0 { $0.capture.wakes.consume() } }
    }

    func attachWake(_ wake: @escaping @Sendable () -> Void) {
        let signal = state.withLock { state in
            guard !state.closed else { return false }
            state.wake = wake
            guard !state.changed.isEmpty, !state.waking else { return false }
            state.waking = true
            if state.capture.id != 0 { state.capture.wakes.emit() }
            return true
        }
        if signal { wake() }
    }

    func attach(_ owner: ShellServiceOwner) {
        state.withLock { state in
            if !state.closed { state.attached.insert(owner) }
        }
    }

    func changed(_ owner: ShellServiceOwner) {
        let wake = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.closed, state.attached.contains(owner) else { return nil }
            state.changed.insert(owner)
            if state.capture.id != 0 { state.capture.changedPeak = max(state.capture.changedPeak, state.changed.count) }
            guard !state.waking, let wake = state.wake else { return nil }
            state.waking = true
            if state.capture.id != 0 { state.capture.wakes.emit() }
            return wake
        }
        wake?()
    }

    func take() -> Set<ShellServiceOwner> {
        state.withLock { state in
            let changed = state.changed
            state.changed.removeAll(keepingCapacity: true)
            state.waking = false
            return changed
        }
    }

    func detach(_ owner: ShellServiceOwner) {
        state.withLock { state in
            state.attached.remove(owner)
            state.changed.remove(owner)
        }
    }

    func close() {
        state.withLock { state in
            state.closed = true
            state.attached.removeAll()
            state.changed.removeAll()
            state.wake = nil
        }
    }
}
