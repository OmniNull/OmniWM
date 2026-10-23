// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Synchronization

final class ShellResourceCatalog: Sendable {
    static let ownerLimit = 512
    static let tokenLimit = 4096

    private struct Owner {
        let namespace: ShellStoreNamespace
        let loadError: String?
        var active = true
    }

    private struct Entry {
        let owner: ShellServiceOwner
        var metadata: ShellResourceMetadata
    }

    private struct Sink {
        let changed: @Sendable (ShellServiceOwner) -> Void
        let persistence: @Sendable (ShellResourcePersistenceResult) -> Void
    }

    private struct State {
        var owners: [ShellServiceOwner: Owner] = [:]
        var resources: [ShellResourceID: Entry] = [:]
        var tokens: [ShellStoreNamespace: [ShellResourceToken: ShellResourceDescriptor]] = [:]
        var persistence: [ShellResourceToken: ShellResourcePersistenceRequest] = [:]
        var sinks: [ShellServiceOwner: Sink] = [:]
    }

    private let state = Mutex(State())

    func attach(
        _ owner: ShellServiceOwner,
        changed: @escaping @Sendable (ShellServiceOwner) -> Void,
        persistence: @escaping @Sendable (ShellResourcePersistenceResult) -> Void
    ) {
        state.withLock { state in
            guard state.owners[owner]?.active == true else { return }
            state.sinks[owner] = Sink(changed: changed, persistence: persistence)
        }
    }

    func detach(_ owner: ShellServiceOwner) {
        state.withLock { _ = $0.sinks.removeValue(forKey: owner) }
    }

    func metadata(owner: ShellServiceOwner) -> [ShellResourceMetadata] {
        state.withLock { state in
            guard state.owners[owner]?.active == true else { return [] }
            return state.resources.values.compactMap { $0.owner == owner ? $0.metadata : nil }
        }
    }

    func preparedTokens(_ namespace: ShellStoreNamespace) -> ShellResourceStore.PreparedTokens? {
        state.withLock { state in
            guard let owner = state.owners.values.first(where: { $0.namespace == namespace }) else { return nil }
            return ShellResourceStore.PreparedTokens(
                namespace: namespace,
                tokens: state.tokens[namespace] ?? [:],
                error: owner.loadError
            )
        }
    }

    func deliverPersistence(_ result: ShellResourcePersistenceResult) {
        let sink = state.withLock { state -> (@Sendable (ShellResourcePersistenceResult) -> Void)? in
            guard state.owners[result.id.owner]?.active == true else { return nil }
            return state.sinks[result.id.owner]?.persistence
        }
        sink?(result)
    }

    func activate(
        _ owner: ShellServiceOwner,
        namespace: ShellStoreNamespace,
        tokens: [ShellResourceToken: ShellResourceDescriptor],
        loadError: String? = nil
    ) throws {
        try state.withLock { state in
            guard state.owners[owner] == nil, !state.owners.values.contains(where: { $0.namespace == namespace }) else {
                throw ShellResourceFailure("resource namespace is already active")
            }
            guard tokens.count <= Self.tokenLimit else { throw ShellResourceFailure("resource_token_limit") }
            state.owners[owner] = Owner(namespace: namespace, loadError: loadError)
            state.tokens[namespace] = tokens
        }
    }

    func isBound(_ namespace: ShellStoreNamespace) -> Bool {
        state.withLock { $0.owners.values.contains { $0.namespace == namespace } }
    }

    func isActive(_ owner: ShellServiceOwner) -> Bool {
        state.withLock { $0.owners[owner]?.active == true }
    }

    func namespace(_ owner: ShellServiceOwner, includingInactive: Bool = false) -> ShellStoreNamespace? {
        state.withLock { $0.owners[owner]?.active == true || includingInactive ? $0.owners[owner]?.namespace : nil }
    }

    func metadata(
        _ id: ShellResourceID,
        owner: ShellServiceOwner,
        includingInactive: Bool = false
    ) -> ShellResourceMetadata? {
        state.withLock { state in
            guard state.owners[owner]?.active == true || (includingInactive && state.owners[owner] != nil),
                  let entry = state.resources[id], entry.owner == owner else { return nil }
            return entry.metadata
        }
    }

    func admit(_ descriptors: [ShellResourceDescriptor], owner: ShellServiceOwner) throws {
        try state.withLock { state in
            guard state.owners[owner]?.active == true else { throw ShellResourceFailure("resource owner is inactive") }
            guard !descriptors.isEmpty, descriptors.count <= Self.ownerLimit,
                  Set(descriptors.map(\.id)).count == descriptors.count,
                  descriptors.allSatisfy({
                      state.resources[$0.id] == nil && !$0.name.isEmpty && $0.name.utf8.count <= 1024 &&
                          $0.kind.utf8.count <= 64 && $0.uti.utf8.count <= 256
                  })
            else { throw ShellResourceFailure("invalid resource batch") }
            let count = state.resources.values.reduce(0) { $0 + ($1.owner == owner ? 1 : 0) }
            guard count + descriptors.count <= Self.ownerLimit
            else { throw ShellResourceFailure("resource capacity exceeded") }
            for descriptor in descriptors {
                state.resources[descriptor.id] = Entry(
                    owner: owner,
                    metadata: ShellResourceMetadata(descriptor: descriptor)
                )
            }
        }
    }

    @discardableResult
    func publish(
        _ updates: [(ShellResourceID, UInt64?)],
        owner: ShellServiceOwner,
        operation: ShellResourceOperation? = nil
    ) -> Bool {
        let update = { self.state.withLock { state -> (Bool, (@Sendable (ShellServiceOwner) -> Void)?) in
            guard state.owners[owner]?.active == true, !updates.isEmpty,
                  updates
                      .allSatisfy({
                          state.resources[$0.0]?.owner == owner && state.resources[$0.0]?.metadata.state == .pending })
            else { return (false, nil) }
            for (id, size) in updates {
                state.resources[id]?.metadata.state = .ready
                state.resources[id]?.metadata.size = size
                state.resources[id]?.metadata.revision += 1
            }
            return (true, state.sinks[owner]?.changed)
        }
        }
        let result = operation.map { $0.whileActive(update) ?? (false, nil) } ?? update()
        result.1?(owner)
        return result.0
    }

    func fail(_ ids: [ShellResourceID], owner: ShellServiceOwner, error: String) {
        let changed = state.withLock { state -> (@Sendable (ShellServiceOwner) -> Void)? in
            guard state.owners[owner]?.active == true else { return nil }
            var didChange = false
            for id in ids where state.resources[id]?.owner == owner && state.resources[id]?.metadata.state == .pending {
                state.resources[id]?.metadata.state = .failed
                state.resources[id]?.metadata.error = String(error.prefix(1024))
                state.resources[id]?.metadata.revision += 1
                didChange = true
            }
            return didChange ? state.sinks[owner]?.changed : nil
        }
        changed?(owner)
    }

    func remove(_ ids: [ShellResourceID], owner: ShellServiceOwner) {
        state.withLock { state in
            for id in ids where state.resources[id]?.owner == owner { state.resources.removeValue(forKey: id) }
        }
    }

    func deactivate(_ owner: ShellServiceOwner) {
        state.withLock { $0.owners[owner]?.active = false }
    }

    func retire(_ owner: ShellServiceOwner) {
        state.withLock { state in
            if let retired = state.owners
                .removeValue(forKey: owner) { state.tokens.removeValue(forKey: retired.namespace) }
            state.resources = state.resources.filter { $0.value.owner != owner }
            state.sinks.removeValue(forKey: owner)
        }
    }

    @discardableResult
    func admitPersistence(
        _ resource: ShellResourceID,
        id: ShellServiceID,
        token: ShellResourceToken
    ) throws -> ShellResourceToken {
        try state.withLock { state in
            guard let owner = state.owners[id.owner], owner.active, let entry = state.resources[resource],
                  entry.owner == id.owner,
                  entry.metadata.state != .failed
            else { throw ShellResourceFailure("resource is unavailable") }
            let pending = state.persistence.values.reduce(0) { $0 + ($1.namespace == owner.namespace ? 1 : 0) }
            guard (state.tokens[owner.namespace]?.count ?? 0) + pending < Self.tokenLimit else {
                throw ShellResourceFailure("resource_token_limit")
            }
            guard state.persistence[token] == nil, state.tokens[owner.namespace]?[token] == nil else {
                throw ShellResourceFailure("resource token was already admitted")
            }
            state.persistence[token] = ShellResourcePersistenceRequest(
                id: id,
                resource: resource,
                token: token,
                namespace: owner.namespace
            )
            state.resources[resource]?.metadata.persistence = .pending(token)
            return token
        }
    }

    func persistence(_ token: ShellResourceToken) -> ShellResourcePersistenceRequest? {
        state.withLock { $0.persistence[token] }
    }

    func pendingPersistence(
        owner: ShellServiceOwner? = nil,
        resource: ShellResourceID? = nil
    ) -> [ShellResourcePersistenceRequest] {
        state.withLock { state in
            state.persistence.values
                .filter { (owner == nil || $0.id.owner == owner) && (resource == nil || $0.resource == resource) }
        }
    }

    @discardableResult
    func finishPersistence(_ token: ShellResourceToken, error: String?) -> ShellResourcePersistenceRequest? {
        let result = state.withLock { state -> (
            ShellResourcePersistenceRequest?,
            (@Sendable (ShellServiceOwner) -> Void)?
        ) in
            guard let request = state.persistence.removeValue(forKey: token) else { return (nil, nil) }
            if error == nil, let descriptor = state.resources[request.resource]?.metadata.descriptor {
                state.tokens[request.namespace, default: [:]][token] = descriptor
            }
            guard state.resources[request.resource]?.owner == request.id.owner else {
                return (request, nil)
            }
            if state.resources[request.resource]?.metadata.persistence == .pending(token) {
                state.resources[request.resource]?.metadata.persistence = error
                    .map { .failed(token, $0) } ?? .durable(token)
            }
            return (
                request,
                state.owners[request.id.owner]?.active == true ? state.sinks[request.id.owner]?.changed : nil
            )
        }
        if let request = result.0 { result.1?(request.id.owner) }
        return result.0
    }

    func restoringDescriptor(
        _ token: ShellResourceToken,
        id: ShellResourceID,
        owner: ShellServiceOwner
    ) -> ShellResourceDescriptor? {
        state.withLock { state in
            guard let owner = state.owners[owner], owner.active,
                  let saved = state.tokens[owner.namespace]?[token] else { return nil }
            return ShellResourceDescriptor(id: id, name: saved.name, kind: saved.kind, uti: saved.uti)
        }
    }

    func knows(_ token: ShellResourceToken, owner: ShellServiceOwner) -> Bool {
        state.withLock { state in
            guard let owner = state.owners[owner], owner.active else { return false }
            return state.tokens[owner.namespace]?[token] != nil
        }
    }
}
