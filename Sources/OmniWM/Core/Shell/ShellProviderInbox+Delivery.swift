// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellProviderInbox {
    func takeBatch(now: UInt64) -> [Delivery] {
        state.withLock { state in
            var result: [Delivery] = []
            result = Self.takeCleanup(&state, owner: nil)
            while result.count < Self.batchLimit, let queued = state.controls.first {
                guard queued.runnable else { break }
                if case let .result(id, _) = queued.control {
                    if let preparation = Self.takePreparation(&state, queued: queued, id: id) {
                        result.append(preparation)
                        return result
                    }
                    if state.registered[id]?.resource == nil { state.registered.removeValue(forKey: id) }
                } else { state.eventCount -= 1 }
                state.controls.removeFirst()
                result.append(Delivery(
                    identity: queued.identity,
                    snapshot: Self.consume(&state, identity: queued.identity, now: now),
                    control: queued.control
                ))
            }
            if result.count < Self.batchLimit {
                let identities = state.entries.values.compactMap { entry in
                    entry.statusPending || (entry.hasChanges && entry.deadline <= now) ? entry.identity : nil
                }
                for identity in identities.prefix(Self.batchLimit - result.count) {
                    if let snapshot = Self.consume(&state, identity: identity, now: now) {
                        result.append(Delivery(identity: identity, snapshot: snapshot, control: nil))
                    }
                }
            }
            return result
        }
    }

    private static func takePreparation(_ state: inout State, queued: Queued, id: ShellServiceID) -> Delivery? {
        let key = ShellResourceLeaseKey(id: id, incarnation: queued.identity.incarnation)
        let work: Work
        switch queued.preparation {
        case let .raw(bytes)?:
            state.controls[0].preparation = .decoding
            state.registered[id]?.resource?.utility = .decoding
            work = .decodeResult(key, bytes)
        case let .decoded(outputs)?:
            state.controls[0].preparation = .importing
            state.registered[id]?.resource?.utility = .importing
            work = .importResult(key, outputs)
        default: return nil
        }
        return Delivery(identity: queued.identity, snapshot: nil, control: nil, work: work)
    }

    func takeCleanup(owner: ShellServiceOwner? = nil) -> [Delivery] {
        state.withLock { Self.takeCleanup(&$0, owner: owner) }
    }

    static func takeCleanup(_ state: inout State, owner: ShellServiceOwner?) -> [Delivery] {
        var result: [Delivery] = []
        for id in state.registered.keys.sorted(by: { $0.request < $1.request }) where result.count < batchLimit {
            guard owner == nil || id.owner == owner,
                  let registered = state.registered[id], registered.resource?.canClean == true else { continue }
            state.registered[id]?.resource?.cleanupStarted = true
            let key = ShellResourceLeaseKey(id: id, incarnation: registered.identity.incarnation)
            result.append(Delivery(
                identity: registered.identity,
                snapshot: nil,
                control: nil,
                work: .finishAction(key)
            ))
        }
        return result
    }

    func takeState(_ identity: ShellProviderIdentity, now: UInt64) -> Snapshot? {
        state.withLock { Self.consume(&$0, identity: identity, now: now) }
    }

    @discardableResult
    func finishBatch(now: UInt64) -> Continuation {
        let result = state.withLock { state -> (Continuation, (@Sendable () -> Void)?) in
            guard !state.closed else { return (.idle, nil) }
            if Self.hasRunnableControls(state) || state.entries.values.contains(where: {
                $0.statusPending || ($0.hasChanges && $0.deadline <= now)
            }) {
                state.deadline = nil
                state.waking = state.wake != nil
                if state.capture.id != 0, state.wake != nil { state.capture.wakes.emit() }
                return (.waking, state.wake)
            }
            state.waking = false
            state.deadline = state.entries.values.filter { $0.hasChanges }.map(\.deadline).min()
            return (state.deadline.map(Continuation.deadline) ?? .idle, nil)
        }
        result.1?()
        return result.0
    }

    func deadlineFired(_ expected: UInt64, now: UInt64) {
        let callback = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.closed, state.deadline == expected, now >= expected else { return nil }
            state.deadline = nil
            return Self.wakeIfNeeded(&state, immediate: true)
        }
        callback?()
    }

    static func hasRunnableControls(_ state: State) -> Bool {
        state.controls.first?.runnable == true || state.registered.values.contains { $0.resource?.canClean == true }
    }

    static func wakeIfNeeded(_ state: inout State, immediate: Bool) -> (@Sendable () -> Void)? {
        guard !state.closed, !state.waking, let wake = state.wake,
              immediate || state.deadline == nil else { return nil }
        state.deadline = nil
        state.waking = true
        if state.capture.id != 0 { state.capture.wakes.emit() }
        return wake
    }

    static func consume(_ state: inout State, identity: ShellProviderIdentity, now: UInt64) -> Snapshot? {
        guard var entry = state.entries[identity.owner], entry.identity == identity else { return nil }
        var topics: [Topic] = []
        for name in entry.topics.keys.sorted() where entry.topics[name]?.changed == true {
            if state.capture.id != 0 { state.capture.consumedTopics &+= 1 }
            topics.append(Topic(name: name, value: entry.topics[name]?.value))
            entry.topics[name]?.changed = false
        }
        for name in entry.deliveredTopics.sorted() where entry.topics[name] == nil {
            topics.append(Topic(name: name, value: nil))
        }
        let status = entry.statusPending ? entry.status : nil
        guard !topics.isEmpty || status != nil else { return nil }
        if state.capture.id != 0 { state.capture.consumedSnapshots &+= 1 }
        entry.statusPending = false
        if !topics.isEmpty {
            entry.deliveredTopics = Set(entry.topics.keys)
            entry.lastConsumption = now
        }
        state.entries[identity.owner] = entry
        return Snapshot(topics: topics, status: status)
    }
}
