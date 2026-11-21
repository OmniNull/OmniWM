// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation

extension ShellResourceStore {
    func beginAction(
        _ key: ShellResourceLeaseKey,
        inputs: [ShellResourceID],
        operation: ShellResourceOperation,
        completion: @escaping @Sendable (Result<ActionFiles, ShellResourceFailure>) -> Void
    ) {
        do {
            guard catalog.isActive(key.id.owner), operation.isActive, actions[key] == nil,
                  inputs.count <= Self.attachmentLimit, Set(inputs).count == inputs.count,
                  inputs.allSatisfy({ catalog.metadata($0, owner: key.id.owner) != nil })
            else { throw ShellResourceFailure("invalid resource action") }
            guard actions.keys.filter({ $0.id.owner == key.id.owner }).count < 32,
                  actions.keys.filter({ $0.id.owner.generation == key.id.owner.generation }).count < 256
            else {
                throw ShellResourceFailure("resource_actions_busy")
            }
            let folder = try makeDirectory("actions")
            actions[key] = Action(
                operation: operation,
                inputs: inputs,
                directory: folder,
                pending: Set(inputs),
                completion: completion
            )
            for id in inputs { waiting[id, default: []].insert(key) }
            resolveAction(key)
        } catch {
            if operation.isActive { completion(.failure(ShellResourceFailure(String(describing: error)))) }
        }
    }

    func resolveAction(_ key: ShellResourceLeaseKey) {
        guard var action = actions[key] else { return }
        guard action.operation.isActive, catalog.isActive(key.id.owner) else { finishAction(key)
            return
        }
        do {
            for id in action.pending {
                try resolveInput(id, key: key, action: &action)
            }
            actions[key] = action
            guard action.pending.isEmpty, let completion = action.completion else { return }
            let files = try action.inputs.map { id -> ShellResourceFile in
                guard let file = action.files[id]
                else { throw ShellResourceFailure("resource was released") }
                return file
            }
            actions[key]?.completion = nil
            if action.operation.isActive { completion(.success(ActionFiles(
                files: files,
                outputDirectory: action.directory
            ))) }
        } catch {
            actions[key] = action
            let callback = action.completion
            let active = action.operation.isActive
            finishAction(key)
            if active { callback?(.failure(ShellResourceFailure(String(describing: error)))) }
        }
    }

    private func resolveInput(_ id: ShellResourceID, key: ShellResourceLeaseKey, action: inout Action) throws {
        guard let metadata = catalog.metadata(id, owner: key.id.owner)
        else { throw ShellResourceFailure("resource was released") }
        if metadata.state == .failed { throw ShellResourceFailure(metadata.error ?? "resource failed") }
        guard metadata.state == .ready else { return }
        guard let record = records[id], record.owner == key.id.owner, let item = backing[record.backing],
              case let .file(url) = item.value
        else { throw ShellResourceFailure("provider inputs must be file-backed resources") }
        action.backing[id] = item.id
        action.files[id] = ShellResourceFile(name: metadata.descriptor.name, url: url)
        backing[item.id]?.references += 1
        action.pending.remove(id)
        waiting[id]?.remove(key)
        if waiting[id]?.isEmpty == true { waiting.removeValue(forKey: id) }
    }

    @discardableResult
    func retire(_ owner: ShellServiceOwner) async -> [ShellResourcePersistenceResult] {
        let namespace = catalog.namespace(owner, includingInactive: true)
        catalog.deactivate(owner)
        for token in selections.keys.filter({ selections[$0]?.owner == owner }) {
            if let selected = selections.removeValue(forKey: token) {
                for item in selected.items { clean(item.ownedDirectory) }
            }
        }
        let failures = flush(owner)
        catalog.retire(owner)
        if let namespace { manifests.removeValue(forKey: namespace) }
        let actionKeys = actions.keys.filter { $0.id.owner == owner }
        for key in actionKeys { finishAction(key) }
        for id in records.keys.filter({ records[$0]?.owner == owner }) {
            if let record = records.removeValue(forKey: id) { releaseBacking(record.backing) }
        }
        for key in actionKeys {
            guard let slot = actions.index(forKey: key) else { continue }
            await withCheckedContinuation { completion in
                actions.values[slot].conversionWaiters.append(completion)
            }
        }
        return failures
    }

    func finishAction(_ key: ShellResourceLeaseKey) {
        guard actions[key]?.cancelForCleanup() == true else { return }
        guard let action = actions.removeValue(forKey: key) else { return }
        for id in action.inputs {
            waiting[id]?.remove(key)
            if waiting[id]?.isEmpty == true { waiting.removeValue(forKey: id) }
        }
        for id in action.backing.values { releaseBacking(id) }
        clean(action.directory)
    }

    func importOutputs(
        _ outputs: [ShellResourceOutput],
        ids: [ShellResourceID],
        action key: ShellResourceLeaseKey
    ) throws {
        guard let action = actions[key], action.pending.isEmpty, action.completion == nil,
              action.operation.isActive
        else {
            throw ShellResourceFailure("resource action is unavailable")
        }
        guard !outputs.isEmpty, outputs.count <= Self.attachmentLimit, outputs.count == ids.count else {
            throw ShellResourceFailure("invalid provider output batch")
        }
        try requirePending(ids, owner: key.id.owner)
        var prepared: [Backing] = []
        do {
            for output in outputs {
                guard !output.name.isEmpty, output.name.utf8.count <= 1024, !output.name.contains("\0") else {
                    throw ShellResourceFailure("invalid provider output name")
                }
                prepared.append(try copyOutput(output.path, directory: action.directory, operation: action.operation))
            }
            try install(prepared, ids: ids, owner: key.id.owner, operation: action.operation)
        } catch {
            for item in prepared { clean(item.ownedDirectory) }
            catalog.remove(ids, owner: key.id.owner)
            throw error
        }
        finishWaiting(ids)
    }

    func copyOutput(_ path: String, directory: URL, operation: ShellResourceOperation) throws -> Backing {
        let received = try ShellResourceReceivedFile.copy(
            path,
            directory: directory,
            root: self.directory,
            operation: operation
        )
        return Backing(id: UUID(), value: .file(received.file), size: received.size, ownedDirectory: received.directory)
    }
}
