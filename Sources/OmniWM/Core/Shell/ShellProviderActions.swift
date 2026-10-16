// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import Synchronization

final class ShellProviderActions: Sendable {
    struct Pending: Sendable, Equatable {
        let id: ShellServiceID
        let identity: ShellProviderIdentity
        let frame: Data
    }

    private struct State {
        var identity: ShellProviderIdentity?
        var accepting = false
        var pending: [Pending] = []
        var unwrittenBytes = 0
    }

    private let state = Mutex(State())

    var pendingBytes: Int {
        state.withLock { $0.unwrittenBytes }
    }

    var hasPending: Bool {
        state.withLock { !$0.pending.isEmpty }
    }

    func activate(_ identity: ShellProviderIdentity) {
        state.withLock {
            $0 = State(identity: identity, accepting: true)
        }
    }

    func append(_ frame: Data, id: ShellServiceID, identity: ShellProviderIdentity) -> String? {
        guard !frame.isEmpty, frame.count <= ShellProviderProtocol.lineLimit, frame.last == 10 else {
            return "Invalid provider action frame"
        }
        return state.withLock { state in
            guard state.identity == identity, state.accepting, id.owner == identity.owner else {
                return "Provider disconnected"
            }
            guard !state.pending.contains(where: { $0.id == id }) else { return "Provider action is already queued" }
            guard frame.count <= ShellProviderWriteQueue.byteLimit - state.unwrittenBytes else {
                return "Provider write backlog exceeds 1048576 bytes"
            }
            state.pending.append(Pending(id: id, identity: identity, frame: frame))
            state.unwrittenBytes += frame.count
            return nil
        }
    }

    func takeBatch() -> [Pending] {
        state.withLock { state in
            let count = min(state.pending.count, ShellProviderInbox.batchLimit)
            guard count > 0 else { return [] }
            let batch = Array(state.pending.prefix(count))
            state.pending.removeFirst(count)
            return batch
        }
    }

    func consumed(_ bytes: Int, identity: ShellProviderIdentity) {
        state.withLock {
            guard $0.identity == identity else { return }
            precondition(bytes >= 0 && bytes <= $0.unwrittenBytes)
            $0.unwrittenBytes -= bytes
        }
    }

    @discardableResult
    func cancel(_ id: ShellServiceID, identity: ShellProviderIdentity) -> Bool {
        state.withLock {
            guard $0.identity == identity,
                  let index = $0.pending.firstIndex(where: { $0.id == id }) else { return false }
            $0.unwrittenBytes -= $0.pending[index].frame.count
            $0.pending.remove(at: index)
            return true
        }
    }

    @discardableResult
    func stop(_ identity: ShellProviderIdentity) -> [ShellServiceID] {
        state.withLock {
            guard $0.identity == identity else { return [] }
            let unsent = $0.pending.map(\.id)
            $0.accepting = false
            $0.pending.removeAll()
            $0.unwrittenBytes = 0
            return unsent
        }
    }
}
