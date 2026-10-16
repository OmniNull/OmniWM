// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import Synchronization

extension ShellProvider {
    private struct SignalState {
        var identity: ShellProviderIdentity?
        var pending: Signal = []
        var waking = false
        var wake: (@Sendable () -> Void)?
        var captureID: UInt64 = 0
        var captureWakes = ShellCaptureWakeCounters()
    }

    final class Signals: Sendable {
        private let state = Mutex(SignalState())

        func captureBegin(_ id: UInt64) {
            state.withLock {
                guard id != 0, $0.captureID != id else { return }
                $0.captureID = id
                $0.captureWakes = ShellCaptureWakeCounters()
            }
        }

        func captureEnd(_ id: UInt64) -> ShellCaptureWakeCounters? {
            state.withLock {
                guard id != 0, $0.captureID == id else { return nil }
                $0.captureID = 0
                return $0.captureWakes
            }
        }

        func attach(_ wake: @escaping @Sendable () -> Void) {
            state.withLock { $0.wake = wake }
        }

        func arm(_ identity: ShellProviderIdentity?) {
            state.withLock {
                $0.identity = identity
                $0.pending = []
            }
        }

        func post(_ signal: Signal, identity: ShellProviderIdentity) {
            let wake = state.withLock { state -> (@Sendable () -> Void)? in
                guard state.identity == identity else { return nil }
                state.pending.formUnion(signal)
                guard !state.waking, let wake = state.wake else { return nil }
                state.waking = true
                if state.captureID != 0 { state.captureWakes.emit() }
                return wake
            }
            wake?()
        }

        func take() -> (ShellProviderIdentity, Signal)? {
            state.withLock {
                if $0.captureID != 0 { $0.captureWakes.consume() }
                guard let identity = $0.identity, !$0.pending.isEmpty else { return nil }
                let pending = $0.pending
                $0.pending = []
                return (identity, pending)
            }
        }

        func finish() {
            let wake = state.withLock { state -> (@Sendable () -> Void)? in
                if !state.pending.isEmpty {
                    if state.captureID != 0, state.wake != nil { state.captureWakes.emit() }
                    return state.wake
                }
                state.waking = false
                return nil
            }
            wake?()
        }
    }
}
