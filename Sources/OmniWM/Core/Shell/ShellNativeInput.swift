// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import Synchronization

struct ShellNativeInput: Sendable {
    enum Event: Sendable {
        case drop(ShellDropReservation, [ShellResourceID], CGPoint)
        case finishDrop(ShellDropReservation)
        case beginDrag(ShellServiceID, ShellResourceOperation)
        case finishDrag(ShellServiceID, ShellResourceOperation, copied: Bool, deliver: Bool)
    }

    let event: Event
    let completion: CheckedContinuation<Bool, Never>
}

final class ShellNativeInputPort: Sendable {
    private struct State {
        var mailbox: AsyncStream<ShellWidgetMessage>.Continuation?
        var closed = false
    }

    private let state = Mutex(State())

    var isConnected: Bool {
        state.withLock { !$0.closed && $0.mailbox != nil }
    }

    func attach(_ mailbox: AsyncStream<ShellWidgetMessage>.Continuation) {
        state.withLock { state in
            if !state.closed, state.mailbox == nil { state.mailbox = mailbox }
        }
    }

    func send(_ event: ShellNativeInput.Event) async -> Bool {
        await withCheckedContinuation { completion in
            guard let mailbox = state.withLock({ $0.mailbox }) else { completion.resume(returning: false)
                return
            }
            switch mailbox.yield(.nativeInput(ShellNativeInput(event: event, completion: completion))) {
            case .enqueued: break
            case .terminated: completion.resume(returning: false)
            case let .dropped(message):
                if case let .nativeInput(input) = message { input.completion.resume(returning: false) }
            @unknown default: completion.resume(returning: false)
            }
        }
    }

    func close() {
        state.withLock { state in
            state.closed = true
            state.mailbox = nil
        }
    }
}
