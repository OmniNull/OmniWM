// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import XCTest

final class ShellResourceStoreTests: XCTestCase {
    private let owner = ShellServiceOwner(generation: 11, owner: 2, epoch: 3)
    private let namespace = ShellStoreNamespace(profile: "lake", package: "lake", instance: "shelf")

    func testOwnerEpochAndAtomicCapacity() async throws {
        let (store, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.activate(owner, namespace: namespace)
        let descriptors = (0 ..< 511).map { descriptor(name: "item\($0)") }
        try store.catalog.admit(descriptors, owner: owner)
        let last = descriptor()
        let extra = descriptor()
        XCTAssertThrowsError(try store.catalog.admit([last, extra], owner: owner))
        XCTAssertNil(store.catalog.metadata(last.id, owner: owner))
        try store.catalog.admit([last], owner: owner)
        let stale = ShellServiceOwner(generation: owner.generation, owner: owner.owner, epoch: owner.epoch + 1)
        XCTAssertNil(store.catalog.metadata(last.id, owner: stale))
        XCTAssertThrowsError(try store.catalog.admit([extra], owner: stale))
        XCTAssertThrowsError(try store.catalog.admit([extra], owner: owner))
    }

    func testPendingReadyFailedAndRetirementFence() async throws {
        let (store, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.activate(owner, namespace: namespace)
        let ready = descriptor()
        let failed = descriptor()
        try store.catalog.admit([ready, failed], owner: owner)
        XCTAssertEqual(store.catalog.metadata(ready.id, owner: owner)?.state, .pending)
        try await store.materialize([.bytes(Data("one".utf8))], ids: [ready.id], owner: owner)
        await store.fail([failed.id], owner: owner, error: "promise failed")
        XCTAssertEqual(store.catalog.metadata(ready.id, owner: owner)?.size, 3)
        XCTAssertEqual(store.catalog.metadata(failed.id, owner: owner)?.state, .failed)
        store.catalog.deactivate(owner)
        do {
            try await store.materialize([.bytes(Data("late".utf8))], ids: [failed.id], owner: owner)
            XCTFail("retired owner accepted a resource")
        } catch {}
        XCTAssertNil(store.catalog.metadata(ready.id, owner: owner))
        _ = await store.retire(owner)
    }

    func testSessionPinRetainsOwnedFileAndOriginalFileIsNeverDeleted() async throws {
        let (store, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.activate(owner, namespace: namespace)
        let original = directory.appendingPathComponent("original")
        try Data("external".utf8).write(to: original)
        let borrowed = descriptor()
        let owned = descriptor()
        try store.catalog.admit([borrowed, owned], owner: owner)
        try await store.materialize(
            [.file(original), .bytes(Data("owned".utf8))],
            ids: [borrowed.id, owned.id],
            owner: owner
        )
        let pin = try await store.retain([owned.id], owner: owner)
        guard case let .file(file) = try XCTUnwrap(pin.values.first) else { return XCTFail("expected file backing") }
        _ = await store.retire(owner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        await store.release(pin)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testPromiseRetirementDiscardsLateOwnedOutput() async throws {
        let (store, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.activate(owner, namespace: namespace)
        let item = descriptor()
        try store.catalog.admit([item], owner: owner)
        let promise = try await store.promise(item.id, owner: owner)
        _ = await store.retire(owner)
        try Data("late".utf8).write(to: promise.directory.appendingPathComponent("result"))
        do {
            try await store.completePromise(promise, result: .success("result"))
            XCTFail("late promise was registered")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: promise.directory.path))
        XCTAssertNil(store.catalog.metadata(item.id, owner: owner))
    }

    func testProviderWaitsForReadyInputsAndRetainsReleasedInput() async throws {
        let (store, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.activate(owner, namespace: namespace)
        let first = descriptor(name: "first")
        let pending = descriptor(name: "pending")
        try store.catalog.admit([first, pending], owner: owner)
        try await store.materialize([.bytes(Data("a".utf8))], ids: [first.id], owner: owner)
        let replies = Mutex<[Result<ShellResourceStore.ActionFiles, ShellResourceFailure>]>([])
        let key = action(1)
        await store
            .beginAction(key, inputs: [first.id, pending.id], operation: ShellResourceOperation()) { result in
                replies.withLock { $0.append(result) }
            }
        XCTAssertEqual(replies.withLock { $0.count }, 0)
        await store.release([first.id], owner: owner)
        try await store.materialize([.bytes(Data("b".utf8))], ids: [pending.id], owner: owner)
        let result = try XCTUnwrap(replies.withLock { $0.first }).get()
        XCTAssertEqual(result.files.map(\.name), ["first", "pending"])
        XCTAssertEqual(replies.withLock { $0.count }, 1)
        for file in result.files { XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path)) }
        await store.finishAction(key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.outputDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.files[0].url.path))
    }

    func testCancelledPendingActionDoesNotDispatchWhenResourceBecomesReady() async throws {
        let (store, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.activate(owner, namespace: namespace)
        let item = descriptor()
        try store.catalog.admit([item], owner: owner)
        let count = Mutex(0)
        let operation = ShellResourceOperation()
        let key = action(2)
        await store.beginAction(key, inputs: [item.id], operation: operation) { _ in count.withLock { $0 += 1 } }
        operation.cancel()
        try await store.materialize([.bytes(Data())], ids: [item.id], owner: owner)
        XCTAssertEqual(count.withLock { $0 }, 0)
        await store.finishAction(key)
    }

    func testProviderOutputBatchRejectsPartialSuccessAndPathEscapes() async throws {
        let (store, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.activate(owner, namespace: namespace)
        let ready = Mutex<ShellResourceStore.ActionFiles?>(nil)
        let key = action(3)
        await store.beginAction(key, inputs: [], operation: ShellResourceOperation()) { result in
            if case let .success(files) = result { ready.withLock { $0 = files } }
        }
        let output = try XCTUnwrap(ready.withLock { $0 }).outputDirectory
        try Data("valid".utf8).write(to: output.appendingPathComponent("valid"))
        let outside = directory.appendingPathComponent("outside")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: output.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        for path in ["missing", "../outside", outside.path, "escape", "nul\0file"] {
            let first = descriptor()
            let second = descriptor()
            try store.catalog.admit([first, second], owner: owner)
            do {
                try await store.importOutputs(
                    [.init(name: "good", path: "valid"), .init(name: "bad", path: path)],
                    ids: [first.id, second.id],
                    action: key
                )
                XCTFail("invalid output accepted: \(path)")
            } catch {}
            XCTAssertNil(store.catalog.metadata(first.id, owner: owner))
            XCTAssertNil(store.catalog.metadata(second.id, owner: owner))
        }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "private")
        await store.finishAction(key)
    }

    func testOldIncarnationImportUsesItsOriginalDirectoryAndCancellationFence() async throws {
        let (store, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.activate(owner, namespace: namespace)
        let outputs = Mutex<[UInt64: URL]>([:])
        let first = action(4, incarnation: 1)
        let second = action(5, incarnation: 2)
        let oldOperation = ShellResourceOperation()
        for (key, operation) in [(first, oldOperation), (second, ShellResourceOperation())] {
            await store.beginAction(key, inputs: [], operation: operation) { result in
                if case let .success(files) = result { outputs.withLock { $0[key.incarnation] = files.outputDirectory }
                }
            }
        }
        let oldFolder = try XCTUnwrap(outputs.withLock { $0[1] })
        let newFolder = try XCTUnwrap(outputs.withLock { $0[2] })
        try Data("old".utf8).write(to: oldFolder.appendingPathComponent("file"))
        try Data("new".utf8).write(to: newFolder.appendingPathComponent("file"))
        let item = descriptor()
        try store.catalog.admit([item], owner: owner)
        try await store.importOutputs([.init(name: "file", path: "file")], ids: [item.id], action: first)
        let pin = try await store.retain([item.id], owner: owner)
        guard case let .file(url) = try XCTUnwrap(pin.values.first) else { return XCTFail() }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old")
        await store.finishAction(first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let rejected = descriptor()
        try store.catalog.admit([rejected], owner: owner)
        XCTAssertFalse(store.catalog.publish([(rejected.id, 0)], owner: owner, operation: oldOperation))
        XCTAssertEqual(store.catalog.metadata(rejected.id, owner: owner)?.state, .pending)
        await store.release(pin)
        await store.finishAction(second)
    }

    func testAcceptedTokenBecomesDurableOnlyAfterReadyAndRestoresAcrossEpochs() async throws {
        let results = Mutex<[ShellResourcePersistenceResult]>([])
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShellResourceStore(
            directory: directory,
            persistenceCompleted: { result in results.withLock { $0.append(result) } }
        )
        try await store.activate(owner, namespace: namespace)
        let item = descriptor(name: "saved")
        try store.catalog.admit([item], owner: owner)
        let token = try store.catalog.admitPersistence(item.id, id: action(6).id, token: ShellResourceToken())
        XCTAssertFalse(store.catalog.knows(token, owner: owner))
        XCTAssertEqual(store.catalog.metadata(item.id, owner: owner)?.persistence, .pending(token))
        await store.persist(token)
        XCTAssertEqual(results.withLock { $0.count }, 0)
        try await store.materialize([.bytes(Data("persisted".utf8))], ids: [item.id], owner: owner)
        XCTAssertTrue(store.catalog.knows(token, owner: owner))
        XCTAssertEqual(results.withLock { $0.count }, 1)
        XCTAssertNil(results.withLock { $0.first?.error })
        _ = await store.retire(owner)
        let replacement = ShellServiceOwner(generation: 12, owner: 2, epoch: 1)
        let second = ShellResourceStore(directory: directory)
        try await second.activate(replacement, namespace: namespace)
        let id = ShellResourceID()
        let restored = try XCTUnwrap(second.catalog.restoringDescriptor(token, id: id, owner: replacement))
        XCTAssertEqual(restored.name, "saved")
        try second.catalog.admit([restored], owner: replacement)
        try await second.restore(token, id: id, owner: replacement)
        let pin = try await second.retain([id], owner: replacement)
        guard case let .file(url) = try XCTUnwrap(pin.values.first) else { return XCTFail() }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "persisted")
        XCTAssertFalse(second.catalog.knows(token, owner: owner))
        await second.release(pin)
    }

    func testFailedManifestWritePreservesPreviouslyDurableToken() async throws {
        let reject = Mutex(false)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShellResourceStore(directory: directory, writeFile: { data, url in
            if url.lastPathComponent == "manifest.json",
               reject.withLock({ $0 }) { throw ShellResourceFailure("disk rejected write") }
            try data.write(to: url, options: .atomic)
        })
        try await store.activate(owner, namespace: namespace)
        let first = descriptor()
        let second = descriptor()
        try store.catalog.admit([first, second], owner: owner)
        try await store.materialize(
            [.bytes(Data("a".utf8)), .bytes(Data("b".utf8))],
            ids: [first.id, second.id],
            owner: owner
        )
        let accepted = try store.catalog.admitPersistence(first.id, id: action(7).id, token: ShellResourceToken())
        await store.persist(accepted)
        reject.withLock { $0 = true }
        let failed = try store.catalog.admitPersistence(second.id, id: action(8).id, token: ShellResourceToken())
        let result = await store.persist(failed)
        XCTAssertNotNil(result?.error)
        XCTAssertTrue(store.catalog.knows(accepted, owner: owner))
        XCTAssertFalse(store.catalog.knows(failed, owner: owner))
        XCTAssertFalse(FileManager.default
            .fileExists(atPath: store.namespaceDirectory(namespace).appendingPathComponent(failed.string).path))
        let manifest = try Data(contentsOf: store.namespaceDirectory(namespace).appendingPathComponent("manifest.json"))
        XCTAssertTrue(String(decoding: manifest, as: UTF8.self).contains(accepted.string))
        XCTAssertFalse(String(decoding: manifest, as: UTF8.self).contains(failed.string))
    }

    func testManifestCapAndPendingFlushHaveExplicitFailure() async throws {
        let (store, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.activate(owner, namespace: namespace)
        let large = descriptor()
        let pending = descriptor()
        try store.catalog.admit([large, pending], owner: owner)
        try await store.materialize(
            [.text(String(repeating: "x", count: ShellResourceStore.manifestLimit + 1))],
            ids: [large.id],
            owner: owner
        )
        let oversized = try store.catalog.admitPersistence(large.id, id: action(9).id, token: ShellResourceToken())
        let result = await store.persist(oversized)
        XCTAssertEqual(result?.error, "resource manifest exceeds 4 MiB")
        let token = try store.catalog.admitPersistence(pending.id, id: action(10).id, token: ShellResourceToken())
        let failures = await store.flush(owner)
        XCTAssertEqual(failures.map(\.token), [token])
        XCTAssertFalse(store.catalog.knows(token, owner: owner))
        let folder = store.namespaceDirectory(namespace)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 32, count: ShellResourceStore.manifestLimit + 1)
            .write(to: folder.appendingPathComponent("manifest.json"))
        _ = await store.retire(owner)
        do {
            try await ShellResourceStore(directory: directory).activate(owner, namespace: namespace)
            XCTFail("oversized manifest loaded")
        } catch {}
    }

    func testDeactivateFlushesAcceptedReadyPersistenceWithoutLateCallback() async throws {
        let callbacks = Mutex(0)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShellResourceStore(
            directory: directory,
            persistenceCompleted: { _ in callbacks.withLock { $0 += 1 } }
        )
        try await store.activate(owner, namespace: namespace)
        let item = descriptor()
        try store.catalog.admit([item], owner: owner)
        try await store.materialize([.bytes(Data("close".utf8))], ids: [item.id], owner: owner)
        let token = try store.catalog.admitPersistence(item.id, id: action(11).id, token: ShellResourceToken())
        store.catalog.deactivate(owner)
        let failures = await store.retire(owner)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(callbacks.withLock { $0 }, 0)
        let replacement = ShellServiceOwner(generation: 13, owner: 2, epoch: 1)
        let reopened = ShellResourceStore(directory: directory)
        try await reopened.activate(replacement, namespace: namespace)
        XCTAssertTrue(reopened.catalog.knows(token, owner: replacement))
        XCTAssertNil(store.catalog.namespace(owner, includingInactive: true))
    }

    func testManifestRejectsEquivalentUUIDKeysWithoutActivatingOwner() async throws {
        let (store, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let entry = ShellResourceStore.SavedResource(
            name: "x",
            kind: "text",
            uti: "public.utf8-plain-text",
            content: .text("x")
        )
        let manifest = try JSONEncoder().encode([token: entry, token.lowercased(): entry])
        let folder = store.namespaceDirectory(namespace)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifest.write(to: folder.appendingPathComponent("manifest.json"))
        do {
            try await store.activate(owner, namespace: namespace)
            XCTFail("equivalent UUID keys activated an owner")
        } catch {
            XCTAssertEqual(String(describing: error), "invalid or duplicate resource manifest token")
        }
        XCTAssertFalse(store.catalog.isActive(owner))
    }

    private func descriptor(name: String = "file") -> ShellResourceDescriptor {
        ShellResourceDescriptor(id: ShellResourceID(), name: name, kind: "file", uti: "public.data")
    }

    private func action(_ request: UInt64, incarnation: UInt64 = 1) -> ShellResourceLeaseKey {
        ShellResourceLeaseKey(id: ShellServiceID(owner: owner, request: request), incarnation: incarnation)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fixture() throws -> (ShellResourceStore, URL) {
        let directory = try temporaryDirectory()
        return (ShellResourceStore(directory: directory), directory)
    }
}
