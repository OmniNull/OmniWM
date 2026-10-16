// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellProviderInbox {
    func actionPrepared(_ key: ShellResourceLeaseKey, result: Result<Data, ShellResourceFailure>) -> Bool {
        let changed = state.withLock { state -> (Bool, (@Sendable () -> Void)?) in
            guard var registered = Self.registration(state, key), registered.resource?.delivery == .active,
                  registered.resource?.input == .preparing, !registered.queued else { return (false, nil) }
            switch result {
            case let .success(frame): registered.resource?.input = .ready(frame)
            case let .failure(error):
                registered.resource?.input = .finished
                registered.queued = true
                state.controls.append(Queued(
                    identity: registered.identity,
                    control: .result(id: key.id, outcome: .failure(Self.bounded(error.description)))
                ))
            }
            state.registered[key.id] = registered
            return (true, Self.wakeIfNeeded(&state, immediate: true))
        }
        changed.1?()
        return changed.0
    }

    func preparedFrame(_ key: ShellResourceLeaseKey) -> Data? {
        state.withLock { state in
            guard let registered = Self.registration(state, key), registered.resource?.delivery == .active,
                  case let .ready(frame)? = registered.resource?.input else { return nil }
            return frame
        }
    }

    func preparingAction(_ key: ShellResourceLeaseKey) -> Bool {
        state.withLock { state in
            guard let registered = Self.registration(state, key) else { return false }
            return registered.resource?.delivery == .active && registered.resource?.input == .preparing && !registered
                .queued
        }
    }

    func markSubmitted(_ key: ShellResourceLeaseKey) -> Bool {
        state.withLock { state in
            guard let registered = Self.registration(state, key), registered.resource?.delivery == .active,
                  !registered.queued,
                  case .ready? = registered.resource?.input,
                  let entry = state.entries[key.id.owner], entry.identity == registered.identity,
                  entry.accepting, !entry.terminal else { return false }
            state.registered[key.id]?.resource?.input = .submitted
            return true
        }
    }

    func actionUnsent(_ key: ShellResourceLeaseKey) {
        let wake = state.withLock { state -> (@Sendable () -> Void)? in
            guard Self.registration(state, key)?.resource != nil else { return nil }
            state.registered[key.id]?.resource?.input = .finished
            return Self.wakeIfNeeded(&state, immediate: true)
        }
        wake?()
    }

    func incarnationDrained(_ identity: ShellProviderIdentity) {
        let wake = state.withLock { state -> (@Sendable () -> Void)? in
            var changed = false
            for id in state.registered.keys
                where state.registered[id]?.identity == identity && state.registered[id]?.resource != nil
            {
                state.registered[id]?.resource?.input = .finished
                changed = true
            }
            return changed ? Self.wakeIfNeeded(&state, immediate: true) : nil
        }
        wake?()
    }

    @discardableResult
    func prepareResultMetadata(
        _ key: ShellResourceLeaseKey,
        result: Result<ShellPreparedProviderOutputs, ShellResourceFailure>
    ) -> Bool {
        let prepared = state.withLock { state -> (Bool, (@Sendable () -> Void)?) in
            guard let registered = Self.registration(state, key),
                  registered.resource?.utility == .decoding
            else { return (
                false,
                nil
            ) }
            state.registered[key.id]?.resource?.utility = .none
            guard registered.resource?.delivery == .active,
                  let index = Self.resultIndex(state, key), case .decoding? = state.controls[index].preparation
            else {
                return (false, Self.wakeIfNeeded(&state, immediate: true))
            }
            switch result {
            case let .success(outputs): state.controls[index].preparation = .decoded(outputs)
            case let .failure(error):
                state.controls[index].preparation = nil
                state.controls[index].control = .result(id: key.id, outcome: .failure(Self.bounded(error.description)))
            }
            return (true, Self.wakeIfNeeded(&state, immediate: true))
        }
        prepared.1?()
        return prepared.0
    }

    @discardableResult
    func finishResultImport(
        _ key: ShellResourceLeaseKey,
        result: Result<[ShellResourceID], ShellResourceFailure>
    ) -> Bool {
        let imported = state.withLock { state -> (Bool, (@Sendable () -> Void)?) in
            guard let registered = Self.registration(state, key),
                  registered.resource?.utility == .importing
            else { return (
                false,
                nil
            ) }
            state.registered[key.id]?.resource?.utility = .none
            guard registered.resource?.delivery == .active,
                  let index = Self.resultIndex(state, key), case .importing? = state.controls[index].preparation,
                  case let .result(_, .provider(true, value, _)) = state.controls[index].control
            else {
                return (false, Self.wakeIfNeeded(&state, immediate: true))
            }
            state.controls[index].preparation = nil
            switch result {
            case let .success(ids): state.controls[index].control = .result(
                    id: key.id,
                    outcome: .resources(value: value, ids: ids)
                )
            case let .failure(error): state.controls[index].control = .result(
                    id: key.id,
                    outcome: .failure(Self.bounded(error.description))
                )
            }
            return (true, Self.wakeIfNeeded(&state, immediate: true))
        }
        imported.1?()
        return imported.0
    }

    func beginResultDelivery(_ key: ShellResourceLeaseKey) -> Bool {
        state.withLock { state in
            guard let registered = Self.registration(state, key), registered.queued,
                  registered.resource?.delivery == .active,
                  registered.resource?.utility == ResourceUtility.none else { return false }
            state.registered[key.id]?.resource?.delivery = .consuming
            return true
        }
    }

    func finishResultDelivery(_ key: ShellResourceLeaseKey) {
        let result = state.withLock { state -> (ShellResourceOperation?, (@Sendable () -> Void)?) in
            guard let registered = Self.registration(state, key),
                  registered.resource?.delivery == .consuming
            else { return (
                nil,
                nil
            ) }
            state.registered[key.id]?.resource?.delivery = .done
            return (registered.resource?.operation, Self.wakeIfNeeded(&state, immediate: true))
        }
        result.0?.cancel()
        result.1?()
    }

    func finishActionCleanup(_ key: ShellResourceLeaseKey) {
        state.withLock { state in
            guard Self.registration(state, key)?.resource?.cleanupStarted == true else { return }
            state.registered.removeValue(forKey: key.id)
        }
    }

    func cancel(_ id: ShellServiceID) {
        let result = state.withLock { state -> (ShellResourceOperation?, (@Sendable () -> Void)?) in
            guard var registered = state.registered[id] else { return (nil, nil) }
            if registered.resource?.delivery == .consuming { return (nil, nil) }
            state.controls.removeAll {
                if case let .result(resultID, _) = $0.control { return resultID == id }
                return false
            }
            guard registered.resource != nil else {
                state.registered.removeValue(forKey: id)
                return (nil, nil)
            }
            registered.resource?.delivery = .done
            state.registered[id] = registered
            return (registered.resource?.operation, Self.wakeIfNeeded(&state, immediate: true))
        }
        result.0?.cancel()
        result.1?()
    }

    static func registration(_ state: State, _ key: ShellResourceLeaseKey) -> Registered? {
        guard let registered = state.registered[key.id],
              registered.identity.incarnation == key.incarnation else { return nil }
        return registered
    }

    static func resultIndex(_ state: State, _ key: ShellResourceLeaseKey) -> Int? {
        state.controls.firstIndex {
            guard $0.identity.incarnation == key.incarnation, case let .result(id, _) = $0.control else { return false }
            return id == key.id
        }
    }
}
