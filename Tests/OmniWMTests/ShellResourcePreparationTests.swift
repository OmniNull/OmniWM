// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellResourcePreparationTests: XCTestCase {
    private let owner = ShellServiceOwner(generation: 31, owner: 1, epoch: 2)
    private let namespace = ShellStoreNamespace(profile: "lake", package: "lake", instance: "shelf")

    func testPreparationPreloadsDescriptorsAndBindingPerformsNoManifestRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShellResourceStore(directory: directory)
        let token = ShellResourceToken()
        let saved = ShellResourceStore.SavedResource(
            name: "saved",
            kind: "text",
            uti: "public.utf8-plain-text",
            content: .text("hello")
        )
        let folder = store.namespaceDirectory(namespace)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = folder.appendingPathComponent("manifest.json")
        try JSONEncoder().encode([token.string.lowercased(): saved]).write(to: manifest)
        let prepared = await store.prepare(namespace)
        XCTAssertNil(prepared.error)
        XCTAssertEqual(prepared.tokens.count, 1)
        XCTAssertFalse(store.catalog.isActive(owner))
        try FileManager.default.removeItem(at: manifest)
        try store.bind(owner, prepared: prepared)
        XCTAssertTrue(store.catalog.knows(token, owner: owner))
        let id = ShellResourceID()
        let descriptor = try XCTUnwrap(store.catalog.restoringDescriptor(token, id: id, owner: owner))
        try store.catalog.admit([descriptor], owner: owner)
        try await store.restore(token, id: id, owner: owner)
        let pin = try await store.retain([id], owner: owner)
        guard case let .text(value) = try XCTUnwrap(pin.values.first) else { return XCTFail("expected restored text") }
        XCTAssertEqual(value, "hello")
        await store.release(pin)
        let active = await store.prepare(namespace)
        XCTAssertEqual(active.error, "resource namespace is already active")
        _ = await store.retire(owner)
    }

    func testNativeTokenIsMirroredExactlyAndFailedWriteKeepsFailureReadable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShellResourceStore(
            directory: directory,
            writeFile: { _, _ in throw ShellResourceFailure("disk_failure") }
        )
        let prepared = await store.prepare(namespace)
        XCTAssertNil(prepared.error)
        try store.bind(owner, prepared: prepared)
        let resource = ShellResourceID()
        let descriptor = ShellResourceDescriptor(id: resource, name: "text", kind: "text", uti: "public.text")
        try store.catalog.admit([descriptor], owner: owner)
        try await store.materialize([.text("value")], ids: [resource], owner: owner)
        let token = ShellResourceToken()
        let request = ShellServiceID(owner: owner, request: 7)
        XCTAssertEqual(try store.catalog.admitPersistence(resource, id: request, token: token), token)
        XCTAssertThrowsError(try store.catalog.admitPersistence(resource, id: request, token: token))
        XCTAssertEqual(store.catalog.metadata(resource, owner: owner)?.persistence, .pending(token))
        let result = await store.persist(token)
        XCTAssertEqual(result?.id, request)
        XCTAssertEqual(result?.token, token)
        XCTAssertEqual(result?.error, "disk_failure")
        XCTAssertFalse(store.catalog.knows(token, owner: owner))
        XCTAssertEqual(store.catalog.metadata(resource, owner: owner)?.persistence, .failed(token, "disk_failure"))
        _ = await store.retire(owner)
    }

    func testTokenLimitAndInvalidPreloadedMetadataFailWithoutChangingManifest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShellResourceStore(directory: directory)
        let folder = store.namespaceDirectory(namespace)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = folder.appendingPathComponent("manifest.json")
        let entry = ShellResourceStore.SavedResource(
            name: "text",
            kind: "text",
            uti: "public.text",
            content: .text("value")
        )
        let values = Dictionary(uniqueKeysWithValues: (0 ... ShellResourceCatalog.tokenLimit).map { _ in (
            UUID().uuidString,
            entry
        ) })
        let bytes = try JSONEncoder().encode(values)
        try bytes.write(to: manifest)
        let over = await store.prepare(namespace)
        XCTAssertEqual(over.error, "resource_token_limit")
        XCTAssertTrue(over.tokens.isEmpty)
        XCTAssertEqual(try Data(contentsOf: manifest), bytes)
        let token = ShellResourceToken()
        let malformed = ShellResourceStore.SavedResource(
            name: "bad\0name",
            kind: "file",
            uti: "public.data",
            content: .owned("../other")
        )
        try JSONEncoder().encode([token.string: malformed]).write(to: manifest)
        let invalid = await store.prepare(namespace)
        XCTAssertNotNil(invalid.error)
        XCTAssertTrue(invalid.tokens.isEmpty)
        XCTAssertFalse(store.catalog.isActive(owner))
    }
}
