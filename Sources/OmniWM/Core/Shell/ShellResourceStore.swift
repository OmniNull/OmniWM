// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CryptoKit
import Foundation

actor ShellResourceStore {
    struct PreparedTokens: Sendable {
        let namespace: ShellStoreNamespace
        let tokens: [ShellResourceToken: ShellResourceDescriptor]
        let error: String?
    }

    enum Source: Sendable {
        case file(URL)
        case bytes(Data)
        case text(String)
        case url(URL)
    }

    enum Value: Sendable {
        case file(URL)
        case text(String)
        case url(URL)
    }

    struct Promise: Sendable {
        let resource: ShellResourceID
        let owner: ShellServiceOwner
        let directory: URL
    }

    struct Pin: Sendable {
        let id: UUID
        let values: [Value]
    }

    struct Backing {
        let id: UUID
        let value: Value
        let size: UInt64?
        let ownedDirectory: URL?
        var securityScope: ShellResourceSecurityScope?
        var references = 1
    }

    struct Record {
        let owner: ShellServiceOwner
        let backing: UUID
    }

    struct Action {
        let operation: ShellResourceOperation
        let inputs: [ShellResourceID]
        let directory: URL
        var backing: [ShellResourceID: UUID] = [:]
        var files: [ShellResourceID: ShellResourceFile] = [:]
        var pending: Set<ShellResourceID>
        var completion: (@Sendable (Result<ActionFiles, ShellResourceFailure>) -> Void)?
    }

    struct ActionFiles: Sendable {
        let files: [ShellResourceFile]
        let outputDirectory: URL
    }

    static let manifestLimit = 4 << 20
    static let attachmentLimit = 32
    nonisolated let catalog: ShellResourceCatalog
    nonisolated let directory: URL
    let queue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.resources", qos: .utility)
    let writeFile: @Sendable (Data, URL) throws -> Void
    let persistenceCompleted: @Sendable (ShellResourcePersistenceResult) -> Void
    var records: [ShellResourceID: Record] = [:]
    var backing: [UUID: Backing] = [:]
    var pins: [UUID: [UUID]] = [:]
    var selections: [UUID: PreparingSelection] = [:]
    var actions: [ShellResourceLeaseKey: Action] = [:]
    var waiting: [ShellResourceID: Set<ShellResourceLeaseKey>] = [:]
    var manifests: [ShellStoreNamespace: [String: SavedResource]] = [:]

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(
        directory: URL,
        catalog: ShellResourceCatalog = ShellResourceCatalog(),
        writeFile: @escaping @Sendable (Data, URL) throws
            -> Void = { try SettingsFileAccess.writeAtomically($0, at: $1) },
        persistenceCompleted: @escaping @Sendable (ShellResourcePersistenceResult) -> Void = { _ in }
    ) {
        self.directory = directory
        self.catalog = catalog
        self.writeFile = writeFile
        self.persistenceCompleted = persistenceCompleted
    }

    func prepare(_ namespace: ShellStoreNamespace) -> PreparedTokens {
        do {
            guard !catalog.isBound(namespace)
            else { throw ShellResourceFailure("resource namespace is already active") }
            let saved = try loadManifest(namespace)
            guard saved.count <= ShellResourceCatalog.tokenLimit
            else { throw ShellResourceFailure("resource_token_limit") }
            var tokens: [ShellResourceToken: ShellResourceDescriptor] = [:]
            var normalized: [String: SavedResource] = [:]
            for (value, entry) in saved {
                guard let id = UUID(uuidString: value), tokens[ShellResourceToken(id)] == nil,
                      Self.validMetadata(entry.name, limit: 1024), Self.validMetadata(entry.kind, limit: 64),
                      Self.validMetadata(entry.uti, limit: 256)
                else { throw ShellResourceFailure("invalid or duplicate resource manifest token") }
                let token = ShellResourceToken(id)
                if case let .owned(relative) = entry.content, relative != token.string {
                    throw ShellResourceFailure("invalid resource backing token")
                }
                tokens[token] = ShellResourceDescriptor(
                    id: ShellResourceID(id),
                    name: entry.name,
                    kind: entry.kind,
                    uti: entry.uti
                )
                normalized[token.string] = entry
            }
            manifests[namespace] = normalized
            return PreparedTokens(namespace: namespace, tokens: tokens, error: nil)
        } catch {
            return PreparedTokens(namespace: namespace, tokens: [:], error: String(describing: error))
        }
    }

    nonisolated func bind(_ owner: ShellServiceOwner, prepared: PreparedTokens) throws {
        try catalog.activate(owner, namespace: prepared.namespace, tokens: prepared.tokens, loadError: prepared.error)
    }

    func activate(_ owner: ShellServiceOwner, namespace: ShellStoreNamespace) throws {
        let prepared = prepare(namespace)
        if let error = prepared.error { throw ShellResourceFailure(error) }
        try bind(owner, prepared: prepared)
    }

    private static func validMetadata(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && !value.utf8.contains(0)
    }

    func materialize(_ sources: [Source], ids: [ShellResourceID], owner: ShellServiceOwner) throws {
        try requirePending(ids, owner: owner)
        guard sources.count == ids.count else { throw ShellResourceFailure("resource batch size mismatch") }
        var prepared: [Backing] = []
        do {
            for source in sources { prepared.append(try prepare(source)) }
            try install(prepared, ids: ids, owner: owner)
        } catch {
            for item in prepared { clean(item.ownedDirectory) }
            catalog.fail(ids, owner: owner, error: String(describing: error))
            finishWaiting(ids)
            throw error
        }
        finishWaiting(ids)
    }

    func promise(_ id: ShellResourceID, owner: ShellServiceOwner) throws -> Promise {
        try requirePending([id], owner: owner)
        return Promise(resource: id, owner: owner, directory: try makeDirectory("promises"))
    }

    func completePromise(_ promise: Promise, result: Result<String, ShellResourceFailure>) throws {
        defer { clean(promise.directory) }
        var prepared: Backing?
        do {
            try requirePending([promise.resource], owner: promise.owner)
            let path = try result.get()
            let item = try copyOutput(path, directory: promise.directory, operation: ShellResourceOperation())
            prepared = item
            try install([item], ids: [promise.resource], owner: promise.owner)
            finishWaiting([promise.resource])
        } catch {
            clean(prepared?.ownedDirectory)
            fail([promise.resource], owner: promise.owner, error: String(describing: error))
            throw error
        }
    }

    func fail(_ ids: [ShellResourceID], owner: ShellServiceOwner, error: String) {
        catalog.fail(ids, owner: owner, error: error)
        finishWaiting(ids)
    }

    func release(_ ids: [ShellResourceID], owner: ShellServiceOwner) {
        catalog.remove(ids, owner: owner)
        for id in ids where records[id]?.owner == owner {
            if let record = records.removeValue(forKey: id) { releaseBacking(record.backing) }
        }
        finishWaiting(ids)
    }

    func retain(_ ids: [ShellResourceID], owner: ShellServiceOwner) throws -> Pin {
        guard !ids.isEmpty,
              ids.count <= Self.attachmentLimit else { throw ShellResourceFailure("invalid resource list") }
        let resources = try ids.map { id -> Backing in
            guard catalog.metadata(id, owner: owner)?.state == .ready, let record = records[id], record.owner == owner,
                  let item = backing[record.backing]
            else { throw ShellResourceFailure("resource is not ready") }
            return item
        }
        let id = UUID()
        pins[id] = resources.map(\.id)
        for item in resources { backing[item.id]?.references += 1 }
        return Pin(id: id, values: resources.map(\.value))
    }

    func release(_ pin: Pin) {
        guard let ids = pins.removeValue(forKey: pin.id) else { return }
        for id in ids { releaseBacking(id) }
    }

    @discardableResult
    func retire(_ owner: ShellServiceOwner) -> [ShellResourcePersistenceResult] {
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
        for key in actions.keys.filter({ $0.id.owner == owner }) { finishAction(key) }
        for id in records.keys.filter({ records[$0]?.owner == owner }) {
            if let record = records.removeValue(forKey: id) { releaseBacking(record.backing) }
        }
        return failures
    }

    func requirePending(_ ids: [ShellResourceID], owner: ShellServiceOwner) throws {
        guard !ids.isEmpty, Set(ids).count == ids.count,
              ids.allSatisfy({ catalog.metadata($0, owner: owner)?.state == .pending && records[$0] == nil })
        else { throw ShellResourceFailure("resource admission is no longer valid") }
    }

    func prepare(_ source: Source) throws -> Backing {
        switch source {
        case let .file(url):
            let scope = ShellResourceSecurityScope.begin(url)
            return Backing(
                id: UUID(),
                value: .file(url),
                size: try fileSize(url),
                ownedDirectory: nil,
                securityScope: scope
            )
        case let .bytes(bytes):
            let folder = try makeDirectory("temporary")
            do {
                let file = folder.appendingPathComponent("payload")
                try writeFile(bytes, file)
                return Backing(id: UUID(), value: .file(file), size: UInt64(bytes.count), ownedDirectory: folder)
            } catch {
                clean(folder)
                throw error
            }
        case let .text(text):
            return Backing(id: UUID(), value: .text(text), size: UInt64(text.utf8.count), ownedDirectory: nil)
        case let .url(url):
            guard url.scheme != nil else { throw ShellResourceFailure("invalid resource URL") }
            return Backing(id: UUID(), value: .url(url), size: nil, ownedDirectory: nil)
        }
    }

    func install(
        _ prepared: [Backing],
        ids: [ShellResourceID],
        owner: ShellServiceOwner,
        operation: ShellResourceOperation? = nil
    ) throws {
        try requirePending(ids, owner: owner)
        for (id, item) in zip(ids, prepared) {
            records[id] = Record(owner: owner, backing: item.id)
            backing[item.id] = item
        }
        let published = catalog.publish(Array(zip(ids, prepared.map(\.size))), owner: owner, operation: operation)
        guard published else {
            for id in ids {
                if let record = records.removeValue(forKey: id) { backing.removeValue(forKey: record.backing) }
            }
            throw ShellResourceFailure("resource operation was cancelled")
        }
    }

    func fileSize(_ url: URL) throws -> UInt64 {
        guard url.isFileURL else { throw ShellResourceFailure("resource is not a file") }
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular, let size = values[.size] as? NSNumber else {
            throw ShellResourceFailure("resource is not a regular file")
        }
        return size.uint64Value
    }

    func makeDirectory(_ group: String) throws -> URL {
        let path = directory.appendingPathComponent(group, isDirectory: true).appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return path
    }

    func releaseBacking(_ id: UUID) {
        guard var item = backing[id] else { return }
        item.references -= 1
        if item.references == 0 {
            backing.removeValue(forKey: id)
            clean(item.ownedDirectory)
        } else { backing[id] = item }
    }

    func clean(_ url: URL?) {
        guard let url else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
        catch { Log.shell.error("Could not remove shell resource backing: \(error.localizedDescription)") }
    }

    func finishWaiting(_ ids: [ShellResourceID]) {
        let keys = Set(ids.flatMap { waiting[$0] ?? [] })
        for key in keys { resolveAction(key) }
        for id in ids {
            for request in catalog.pendingPersistence(resource: id) { persist(request.token) }
        }
    }
}
