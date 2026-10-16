// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import Synchronization

final class ShellProviderInbox: Sendable {
    static let topicLimit = 64
    static let stateByteLimit = 1_048_576
    static let eventLimit = 256
    static let batchLimit = 16
    static let stateInterval: UInt64 = 33_333_334

    struct Capture: Equatable, Sendable {
        var id: UInt64 = 0
        var receivedStates: UInt64 = 0
        var coalescedStates: UInt64 = 0
        var consumedTopics: UInt64 = 0
        var consumedSnapshots: UInt64 = 0
        var actionsBegin = 0
        var actionsEnd = 0
        var actionsPeak = 0
        var eventsBegin = 0
        var eventsEnd = 0
        var eventsPeak = 0
        var wakes = ShellCaptureWakeCounters()

        var detail: String {
            "utility=provider_inbox states_received=\(receivedStates) states_coalesced=\(coalescedStates)"
                + " topics_consumed=\(consumedTopics) snapshots_consumed=\(consumedSnapshots)"
                + " action_begin=\(actionsBegin) action_end=\(actionsEnd) action_peak=\(actionsPeak)"
                + " event_begin=\(eventsBegin) event_end=\(eventsEnd) event_peak=\(eventsPeak) " + wakes.detail
        }
    }

    enum Status: Equatable, Sendable {
        case starting
        case running
        case exited(Int32)
        case failed(String)
    }

    enum Outcome: Equatable, Sendable {
        case provider(ok: Bool, value: Data, attachments: Data?)
        case failure(String)
        case resources(value: Data, ids: [ShellResourceID])
    }

    enum Work: Equatable, Sendable {
        case decodeResult(ShellResourceLeaseKey, Data)
        case importResult(ShellResourceLeaseKey, ShellPreparedProviderOutputs)
        case finishAction(ShellResourceLeaseKey)
    }

    enum Control: Equatable, Sendable {
        case event(name: String, value: Data)
        case result(id: ShellServiceID, outcome: Outcome)
    }

    struct Topic: Equatable, Sendable {
        let name: String
        let value: Data?
    }

    struct Snapshot: Equatable, Sendable {
        let topics: [Topic]
        let status: Status?
    }

    struct Delivery: Equatable, Sendable {
        let identity: ShellProviderIdentity
        let snapshot: Snapshot?
        let control: Control?
        var work: Work?
    }

    enum Admission: Equatable, Sendable {
        case accepted
        case unchanged
        case ignored
        case failed(String)
    }

    enum Continuation: Equatable, Sendable {
        case idle
        case waking
        case deadline(UInt64)
    }

    struct Binding: Sendable {
        let identity: ShellProviderIdentity
        let configuration: ShellProviderConfiguration?
        let accepting: Bool
        let terminal: Bool
    }

    struct Counters: Equatable, Sendable {
        var coalescedStates: UInt64 = 0
        var ignoredResults: UInt64 = 0
    }

    let state = Mutex(State())

    func captureBegin(_ id: UInt64) {
        state.withLock {
            guard id != 0, $0.capture.id != id else { return }
            $0.capture = Capture(
                id: id, actionsBegin: $0.registered.count, actionsPeak: $0.registered.count,
                eventsBegin: $0.eventCount, eventsPeak: $0.eventCount
            )
        }
    }

    func captureEnd(_ id: UInt64) -> Capture? {
        state.withLock {
            guard id != 0, $0.capture.id == id else { return nil }
            $0.capture.actionsEnd = $0.registered.count
            $0.capture.eventsEnd = $0.eventCount
            defer { $0.capture = Capture() }
            return $0.capture
        }
    }

    func captureWakeConsumed() {
        state.withLock { if $0.capture.id != 0 { $0.capture.wakes.consume() } }
    }

    var counters: Counters {
        state.withLock { $0.counters }
    }

    var pendingEvents: Int {
        state.withLock { $0.eventCount }
    }

    var pendingActions: Int {
        state.withLock { $0.registered.count }
    }

    func identity(for owner: ShellServiceOwner) -> ShellProviderIdentity? {
        state.withLock {
            guard let entry = $0.entries[owner], !entry.terminal, entry.accepting else { return nil }
            return entry.identity
        }
    }

    func binding(for owner: ShellServiceOwner) -> Binding? {
        state.withLock {
            $0.entries[owner].map {
                Binding(
                    identity: $0.identity,
                    configuration: $0.configuration,
                    accepting: $0.accepting && !$0.terminal,
                    terminal: $0.terminal
                )
            }
        }
    }

    func stopAccepting(_ identity: ShellProviderIdentity) {
        state.withLock {
            guard $0.entries[identity.owner]?.identity == identity else { return }
            $0.entries[identity.owner]?.accepting = false
        }
    }

    func failUndispatched(_ id: ShellServiceID, error: String) {
        let callback = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.closed, state.registered[id] == nil else { return nil }
            let identity = ShellProviderIdentity(owner: id.owner, incarnation: 0)
            state.registered[id] = Registered(identity: identity, queued: true)
            if state.capture.id != 0 {
                state.capture.actionsPeak = max(state.capture.actionsPeak, state.registered.count)
            }
            state.controls.append(Queued(
                identity: identity,
                control: .result(id: id, outcome: .failure(Self.bounded(error)))
            ))
            return Self.wakeIfNeeded(&state, immediate: true)
        }
        callback?()
    }

    func attachWake(_ wake: @escaping @Sendable () -> Void) {
        let callback = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.closed else { return nil }
            state.wake = wake
            guard Self.hasRunnableControls(state) || state.entries.values
                .contains(where: { $0.statusPending || $0.hasChanges })
            else {
                return nil
            }
            return Self.wakeIfNeeded(&state, immediate: true)
        }
        callback?()
    }

    @discardableResult
    func activate(_ identity: ShellProviderIdentity, configuration: ShellProviderConfiguration? = nil) -> Bool {
        let result = state.withLock { state -> (Bool, (@Sendable () -> Void)?) in
            guard !state.closed else { return (false, nil) }
            if let previous = state.entries[identity.owner] {
                guard previous.terminal,
                      identity.incarnation > previous.identity.incarnation else { return (false, nil) }
            }
            state.entries[identity.owner] = Entry(identity: identity, configuration: configuration)
            return (true, Self.wakeIfNeeded(&state, immediate: true))
        }
        result.1?()
        return result.0
    }

    @discardableResult
    func register(
        _ id: ShellServiceID,
        identity: ShellProviderIdentity,
        operation: ShellResourceOperation? = nil
    ) -> Bool {
        state.withLock { state in
            guard !state.closed, id.owner == identity.owner,
                  let entry = state.entries[identity.owner], entry.identity == identity, !entry.terminal,
                  entry.accepting,
                  state.registered[id] == nil
            else { return false }
            state.registered[id] = Registered(
                identity: identity,
                resource: operation.map { ResourceAction(operation: $0) }
            )
            if state.capture.id != 0 {
                state.capture.actionsPeak = max(state.capture.actionsPeak, state.registered.count)
            }
            return true
        }
    }

    func isPending(_ id: ShellServiceID, identity: ShellProviderIdentity) -> Bool {
        state.withLock {
            guard let registered = $0.registered[id] else { return false }
            return registered.identity == identity && !registered.queued &&
                (registered.resource.map { $0.delivery == .active && $0.input == .submitted } ?? true)
        }
    }

    func running(_ identity: ShellProviderIdentity) {
        let callback = state.withLock { state -> (@Sendable () -> Void)? in
            guard var entry = state.entries[identity.owner], entry.identity == identity,
                  !entry.terminal else { return nil }
            guard entry.status != .running else { return nil }
            entry.status = .running
            entry.statusPending = true
            state.entries[identity.owner] = entry
            return Self.wakeIfNeeded(&state, immediate: true)
        }
        callback?()
    }

    func remove(owner: ShellServiceOwner) {
        let removed = state.withLock { state -> ([ShellResourceOperation], (@Sendable () -> Void)?) in
            var operations: [ShellResourceOperation] = []
            state.entries.removeValue(forKey: owner)
            for id in state.registered.keys where id.owner == owner {
                if let resource = state.registered[id]?.resource {
                    operations.append(resource.operation)
                    state.registered[id]?.resource?.delivery = .done
                } else { state.registered.removeValue(forKey: id) }
            }
            state.eventCount -= state.controls.reduce(0) { count, queued in
                guard queued.identity.owner == owner, case .event = queued.control else { return count }
                return count + 1
            }
            state.controls.removeAll { $0.identity.owner == owner }
            return (operations, operations.isEmpty ? nil : Self.wakeIfNeeded(&state, immediate: true))
        }
        for operation in removed.0 { operation.cancel() }
        removed.1?()
    }

    func close() {
        let ids = state.withLock { state -> [ShellServiceID] in
            state.closed = true
            state.entries.removeAll()
            state.controls.removeAll()
            state.eventCount = 0
            state.deadline = nil
            state.wake = nil
            state.waking = false
            return Array(state.registered.keys)
        }
        for id in ids { cancel(id) }
    }

    static func increment(_ count: inout UInt64) {
        if count != .max { count += 1 }
    }

    static func bounded(_ message: String) -> String {
        String(message.prefix(1024))
    }
}
