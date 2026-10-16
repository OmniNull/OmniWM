// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CryptoKit
import Foundation

extension ShellResourceStore {
    enum SavedContent: Codable {
        case bookmark(Data)
        case scopedBookmark(Data)
        case owned(String)
        case text(String)
        case url(URL)
    }

    struct SavedResource: Codable {
        let name: String
        let kind: String
        let uti: String
        let content: SavedContent
    }

    @discardableResult
    func persist(_ token: ShellResourceToken) -> ShellResourcePersistenceResult? {
        guard let request = catalog.persistence(token) else { return nil }
        guard let metadata = catalog.metadata(request.resource, owner: request.id.owner, includingInactive: true) else {
            return finishPersistence(request, error: "resource is unavailable")
        }
        guard metadata.state != .pending else { return nil }
        guard metadata.state == .ready, let record = records[request.resource], record.owner == request.id.owner,
              let item = backing[record.backing]
        else { return finishPersistence(request, error: metadata.error ?? "resource failed") }
        var owned: URL?
        do {
            let content = try savedContent(item, request: request, owned: &owned)
            let saved = SavedResource(
                name: metadata.descriptor.name,
                kind: metadata.descriptor.kind,
                uti: metadata.descriptor.uti,
                content: content
            )
            var next = manifests[request.namespace] ?? [:]
            next[token.string] = saved
            guard next.count <= ShellResourceCatalog.tokenLimit
            else { throw ShellResourceFailure("resource_token_limit") }
            let data = try JSONEncoder().encode(next)
            guard data.count <= Self.manifestLimit
            else { throw ShellResourceFailure("resource manifest exceeds 4 MiB") }
            let folder = namespaceDirectory(request.namespace)
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try writeFile(data, folder.appendingPathComponent("manifest.json"))
            manifests[request.namespace] = next
            return finishPersistence(request, error: nil)
        } catch {
            clean(owned)
            return finishPersistence(request, error: String(describing: error))
        }
    }

    private func savedContent(
        _ item: Backing,
        request: ShellResourcePersistenceRequest,
        owned: inout URL?
    ) throws -> SavedContent {
        let content: SavedContent
        switch item.value {
        case let .file(url):
            if item.ownedDirectory != nil {
                let folder = namespaceDirectory(request.namespace).appendingPathComponent(
                    request.token.string,
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                owned = folder
                try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent("payload"))
                content = .owned(request.token.string)
            } else if item.securityScope != nil {
                content = .scopedBookmark(try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ))
            } else {
                content = .bookmark(try url.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ))
            }
        case let .text(text):
            guard text.utf8.count <= Self.manifestLimit
            else { throw ShellResourceFailure("resource manifest exceeds 4 MiB") }
            content = .text(text)
        case let .url(url):
            guard url.absoluteString.utf8.count <= Self.manifestLimit
            else { throw ShellResourceFailure("resource manifest exceeds 4 MiB") }
            content = .url(url)
        }
        return content
    }

    @discardableResult
    func flush(_ owner: ShellServiceOwner) -> [ShellResourcePersistenceResult] {
        var failures: [ShellResourcePersistenceResult] = []
        for request in catalog.pendingPersistence(owner: owner) {
            if let result = persist(request.token) {
                if result.error != nil { failures.append(result) }
            } else if catalog.persistence(request.token) != nil {
                let error = "resource persistence ended before the resource became ready"
                if let result = finishPersistence(request, error: error) { failures.append(result) }
            }
        }
        return failures
    }

    func restore(_ token: ShellResourceToken, id: ShellResourceID, owner: ShellServiceOwner) throws {
        guard catalog.knows(token, owner: owner), let namespace = catalog.namespace(owner),
              let saved = manifests[namespace]?[token.string]
        else {
            throw ShellResourceFailure("unknown resource token")
        }
        try requirePending([id], owner: owner)
        do {
            let source: Source
            switch saved.content {
            case let .bookmark(data):
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withoutUI, .withoutMounting],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                source = .file(url)
            case let .scopedBookmark(data):
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withoutUI, .withoutMounting, .withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                source = .file(url)
            case let .owned(relative):
                guard relative == token.string else { throw ShellResourceFailure("invalid resource backing token") }
                source = .file(namespaceDirectory(namespace).appendingPathComponent(relative, isDirectory: true)
                    .appendingPathComponent("payload"))
            case let .text(text): source = .text(text)
            case let .url(url): source = .url(url)
            }
            try materialize([source], ids: [id], owner: owner)
        } catch {
            catalog.fail([id], owner: owner, error: String(describing: error))
            throw error
        }
    }

    func finishPersistence(
        _ request: ShellResourcePersistenceRequest,
        error: String?
    ) -> ShellResourcePersistenceResult? {
        guard catalog.finishPersistence(request.token, error: error) != nil else { return nil }
        let result = ShellResourcePersistenceResult(id: request.id, token: request.token, error: error)
        if catalog.isActive(request.id.owner) {
            catalog.deliverPersistence(result)
            persistenceCompleted(result)
        }
        return result
    }

    func loadManifest(_ namespace: ShellStoreNamespace) throws -> [String: SavedResource] {
        do {
            let file = try FileHandle(forReadingFrom: namespaceDirectory(namespace)
                .appendingPathComponent("manifest.json"))
            defer { try? file.close() }
            let data = try file.read(upToCount: Self.manifestLimit + 1) ?? Data()
            guard data.count <= Self.manifestLimit
            else { throw ShellResourceFailure("resource manifest exceeds 4 MiB") }
            return try JSONDecoder().decode([String: SavedResource].self, from: data)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return [:]
        }
    }

    nonisolated func namespaceDirectory(_ namespace: ShellStoreNamespace) -> URL {
        var writer = ShellValueWriter()
        writer.array(3)
        writer.string(namespace.profile)
        writer.string(namespace.package)
        if let instance = namespace.instance { writer.string(instance) } else { writer.null() }
        let name = SHA256.hash(data: Data(writer.bytes)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("persistent", isDirectory: true).appendingPathComponent(
            name,
            isDirectory: true
        )
    }
}
