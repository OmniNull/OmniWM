// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellProviderInbox {
    @discardableResult
    func post(_ message: ShellProviderProtocol.Message, from identity: ShellProviderIdentity) -> Admission {
        let result = state.withLock { state -> (Admission, (@Sendable () -> Void)?) in
            if Self.finishSubmittedResult(&state, message: message, identity: identity) {
                return (.accepted, Self.wakeIfNeeded(&state, immediate: true))
            }
            guard !state.closed, state.entries[identity.owner]?.identity == identity,
                  state.entries[identity.owner]?.terminal == false
            else {
                return (.ignored, nil)
            }
            return Self.admit(message, state: &state, identity: identity)
        }
        result.1?()
        return result.0
    }

    private static func finishSubmittedResult(
        _ state: inout State,
        message: ShellProviderProtocol.Message,
        identity: ShellProviderIdentity
    ) -> Bool {
        guard case let .result(token, _, _, _) = message,
              let request = ShellProviderProtocol.request(token) else { return false }
        let id = ShellServiceID(owner: identity.owner, request: request)
        guard var registered = state.registered[id], registered.identity == identity,
              registered.resource?.input == .submitted,
              registered.resource?.delivery == .done || registered.queued else { return false }
        registered.resource?.input = .finished
        state.registered[id] = registered
        return true
    }

    private static func admit(
        _ message: ShellProviderProtocol.Message,
        state: inout State,
        identity: ShellProviderIdentity
    ) -> (Admission, (@Sendable () -> Void)?) {
        switch message {
        case let .state(topic, value):
            return admitState(&state, identity: identity, topic: topic, value: value)
        case let .event(name, value):
            guard state.eventCount < Self.eventLimit else {
                Self.end(&state, identity: identity, status: .failed("Provider event queue exceeded 256 entries"))
                return (
                    .failed("Provider event queue exceeded 256 entries"),
                    Self.wakeIfNeeded(&state, immediate: true)
                )
            }
            state.controls.append(Queued(identity: identity, control: .event(name: name, value: value)))
            state.eventCount += 1
            if state.capture.id != 0 { state.capture.eventsPeak = max(state.capture.eventsPeak, state.eventCount) }
        case let .result(token, ok, value, attachments):
            guard let request = ShellProviderProtocol.request(token) else {
                Self.increment(&state.counters.ignoredResults)
                return (.ignored, nil)
            }
            let id = ShellServiceID(owner: identity.owner, request: request)
            guard var registered = state.registered[id], registered.identity == identity, !registered.queued,
                  registered.resource.map({ $0.delivery == .active && $0.input == .submitted }) ?? true
            else {
                Self.increment(&state.counters.ignoredResults)
                return (.ignored, nil)
            }
            registered.queued = true
            registered.resource?.input = .finished
            state.registered[id] = registered
            let outputMetadata = ok ? attachments : nil
            let outcome: Outcome = outputMetadata == nil || registered.resource != nil
                ? .provider(ok: ok, value: value, attachments: outputMetadata) :
                .failure("unexpected_provider_files")
            state.controls.append(Queued(
                identity: identity,
                control: .result(id: id, outcome: outcome),
                preparation: registered.resource != nil ? outputMetadata
                    .map(Preparation.raw) : nil
            ))
        }
        return (.accepted, Self.wakeIfNeeded(&state, immediate: true))
    }

    private static func admitState(
        _ state: inout State,
        identity: ShellProviderIdentity,
        topic: String,
        value: Data
    ) -> (Admission, (@Sendable () -> Void)?) {
        if state.capture.id != 0 { state.capture.receivedStates &+= 1 }
        let change = Self.replaceState(&state.entries[identity.owner]!, topic: topic, value: value)
        if case let .failed(message) = change.admission {
            Self.end(&state, identity: identity, status: .failed(message))
            return (change.admission, Self.wakeIfNeeded(&state, immediate: true))
        }
        guard change.admission == .accepted else { return (change.admission, nil) }
        if change.coalesced {
            Self.increment(&state.counters.coalescedStates)
            if state.capture.id != 0 { state.capture.coalescedStates &+= 1 }
        }
        return (change.admission, Self.wakeIfNeeded(&state, immediate: false))
    }

    func failAction(_ id: ShellServiceID, identity: ShellProviderIdentity, error: String) {
        let callback = state.withLock { state -> (@Sendable () -> Void)? in
            guard var registered = state.registered[id], registered.identity == identity,
                  !registered.queued else { return nil }
            registered.queued = true
            state.registered[id] = registered
            state.controls.append(Queued(
                identity: identity,
                control: .result(id: id, outcome: .failure(Self.bounded(error)))
            ))
            return Self.wakeIfNeeded(&state, immediate: true)
        }
        callback?()
    }

    func end(_ identity: ShellProviderIdentity, status: Status) {
        let callback = state.withLock { state -> (@Sendable () -> Void)? in
            guard Self.end(&state, identity: identity, status: status) else { return nil }
            return Self.wakeIfNeeded(&state, immediate: true)
        }
        callback?()
    }

    static func replaceState(
        _ entry: inout Entry,
        topic: String,
        value: Data
    ) -> (admission: Admission, coalesced: Bool) {
        let previous = entry.topics[topic]
        if value.elementsEqual([110, 117, 108, 108]) {
            guard let previous else { return (.unchanged, false) }
            entry.topics.removeValue(forKey: topic)
            entry.byteCount -= previous.value.count
        } else {
            guard previous?.value != value else { return (.unchanged, false) }
            let count = entry.byteCount - (previous?.value.count ?? 0) + value.count
            guard previous != nil || entry.topics.count < topicLimit, count <= stateByteLimit else {
                return (.failed("Provider state limit exceeded"), false)
            }
            entry.topics[topic] = Slot(value: value, changed: true)
            entry.byteCount = count
        }
        return (.accepted, previous?.changed == true)
    }

    @discardableResult
    static func end(_ state: inout State, identity: ShellProviderIdentity, status: Status) -> Bool {
        guard var entry = state.entries[identity.owner], entry.identity == identity,
              !entry.terminal else { return false }
        entry.terminal = true
        if case let .failed(error) = status { entry.status = .failed(bounded(error)) }
        else { entry.status = status }
        entry.statusPending = true
        state.entries[identity.owner] = entry
        state.eventCount -= state.controls.reduce(0) { count, queued in
            guard queued.identity == identity, case .event = queued.control else { return count }
            return count + 1
        }
        state.controls.removeAll {
            guard $0.identity == identity, case .event = $0.control else { return false }
            return true
        }
        let pending = state.registered.filter {
            $0.value.identity == identity && !$0.value
                .queued && ($0.value.resource?.delivery == .active || $0.value.resource == nil)
        }
        .map(\.key).sorted { $0.request < $1.request }
        for id in pending {
            state.registered[id]?.queued = true
            state.controls.append(Queued(
                identity: identity,
                control: .result(id: id, outcome: .failure("Provider disconnected"))
            ))
        }
        return true
    }
}
