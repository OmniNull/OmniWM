// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class ShellStoreTests: XCTestCase {
    func testLatestSnapshotLoadsBeforeCommitAndCoalescesIntoOneWrite() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Mutex<UInt64>(0)
        let written = Mutex<[Data]>([])
        let commits = Mutex<[ShellStore.Commit]>([])
        let store = ShellStore(directoryURL: directory, now: { clock.withLock { $0 } }, writeFile: { data, url in
            written.withLock { $0.append(data) }
            try data.write(to: url, options: .atomic)
        })
        let namespace = namespace()
        for revision in 1 ... 3 {
            store
                .submit(write(namespace, revision: UInt64(revision))) { commit in
                    commits.withLock { $0.append(commit) }
                }
        }
        let pending = await store.load(namespace)
        XCTAssertEqual(pending.bytes, bytes(3))
        XCTAssertNil(pending.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: namespace).path))
        await store.flushDue()
        XCTAssertTrue(written.withLock { $0.isEmpty })
        clock.withLock { $0 = ShellStore.commitInterval }
        await store.flushDue()
        XCTAssertEqual(written.withLock { $0 }, [Data(bytes(3))])
        XCTAssertEqual(commits.withLock { $0.map(\.revision) }, [3])
        XCTAssertNil(commits.withLock { $0.first?.error })
        _ = await store.close([namespace: owner()])
    }

    func testBackgroundCommitsRemainAtLeastOneSecondApart() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Mutex<UInt64>(0)
        let written = Mutex<[UInt64]>([])
        let store = ShellStore(directoryURL: directory, now: { clock.withLock { $0 } }, writeFile: { _, _ in
            written.withLock { $0.append(clock.withLock { $0 }) }
        })
        let namespace = namespace()
        store.submit(write(namespace, revision: 1)) { _ in }
        _ = await store.load(namespace)
        clock.withLock { $0 = 1_000_000_000 }
        await store.flushDue()
        clock.withLock { $0 = 1_100_000_000 }
        store.submit(write(namespace, revision: 2)) { _ in }
        _ = await store.load(namespace)
        clock.withLock { $0 = 1_999_999_999 }
        await store.flushDue()
        XCTAssertEqual(written.withLock { $0 }, [1_000_000_000])
        clock.withLock { $0 = 2_000_000_000 }
        await store.flushDue()
        XCTAssertEqual(written.withLock { $0 }, [1_000_000_000, 2_000_000_000])
        _ = await store.close([namespace: owner()])
    }

    func testExplicitClosePersistsLatestSnapshotAndNamespacesSurviveRestartIndependently() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShellStore(directoryURL: directory)
        let namespaces = [
            namespace(),
            namespace(instance: "root"),
            namespace(profile: "other"),
            namespace(package: "other")
        ]
        for (index, namespace) in namespaces.enumerated() {
            store.submit(write(namespace, revision: UInt64(index + 1))) { _ in }
        }
        let failures = await store.close(Dictionary(uniqueKeysWithValues: namespaces.map { ($0, owner()) }))
        XCTAssertTrue(failures.isEmpty)
        let restarted = ShellStore(directoryURL: directory)
        for (index, namespace) in namespaces.enumerated() {
            let snapshot = await restarted.load(namespace)
            XCTAssertEqual(snapshot.bytes, bytes(index + 1))
            XCTAssertNil(snapshot.error)
        }
        let absent = await restarted.load(namespace(instance: "missing"))
        XCTAssertNil(absent.bytes)
        XCTAssertNil(absent.error)
    }

    func testFailureRemainsVisibleWithoutBackgroundRetriesAndExplicitFlushCanRetry() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Mutex<UInt64>(0)
        let attempts = Mutex(0)
        let failing = Mutex(true)
        let commits = Mutex<[ShellStore.Commit]>([])
        let store = ShellStore(directoryURL: directory, now: { clock.withLock { $0 } }, writeFile: { data, url in
            attempts.withLock { $0 += 1 }
            if failing.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let namespace = namespace()
        store.submit(write(namespace, revision: 1)) { commit in commits.withLock { $0.append(commit) } }
        _ = await store.load(namespace)
        clock.withLock { $0 = ShellStore.commitInterval }
        await store.flushDue()
        let failed = await store.load(namespace)
        XCTAssertEqual(failed.bytes, bytes(1))
        XCTAssertNotNil(failed.error)
        XCTAssertNotNil(commits.withLock { $0.first?.error })
        clock.withLock { $0 = 10 * ShellStore.commitInterval }
        await store.flushDue()
        XCTAssertEqual(attempts.withLock { $0 }, 1)
        failing.withLock { $0 = false }
        let failures = await store.flush()
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(attempts.withLock { $0 }, 2)
        let recovered = await store.load(namespace)
        XCTAssertEqual(recovered.bytes, bytes(1))
        XCTAssertNil(recovered.error)
        _ = await store.close([namespace: owner()])
    }

    func testOversizedWriteAndStoredSnapshotReportErrorsWithoutUnboundedRead() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commits = Mutex<[ShellStore.Commit]>([])
        let store = ShellStore(directoryURL: directory)
        let namespace = namespace()
        let oversized = ShellStore.Write(
            namespace: namespace,
            id: id(),
            revision: 1,
            bytes: [UInt8](repeating: 0, count: ShellStore.byteLimit + 1)
        )
        store.submit(oversized) { commit in commits.withLock { $0.append(commit) } }
        XCTAssertEqual(commits.withLock { $0.first?.error }, "store snapshot exceeds 256 KiB")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: namespace).path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(oversized.bytes).write(to: store.fileURL(for: namespace))
        let loaded = await store.load(namespace)
        XCTAssertNil(loaded.bytes)
        XCTAssertEqual(loaded.error, "store snapshot exceeds 256 KiB")
    }

    func testFailedCloseRetainsLatestSnapshotForReloadWithoutRetainingCallback() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = Mutex(true)
        let callbacks = Mutex(0)
        let store = ShellStore(directoryURL: directory, now: { 0 }, writeFile: { data, url in
            if failing.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let namespace = namespace()
        store.submit(write(namespace, revision: 1)) { _ in callbacks.withLock { $0 += 1 } }
        let failures = await store.close([namespace: owner()])
        XCTAssertEqual(failures.count, 1)
        let snapshot = await store.load(namespace)
        XCTAssertEqual(snapshot.bytes, bytes(1))
        XCTAssertNotNil(snapshot.error)
        XCTAssertEqual(callbacks.withLock { $0 }, 0)
        failing.withLock { $0 = false }
        let retryFailures = await store.flush()
        XCTAssertTrue(retryFailures.isEmpty)
        let recovered = await store.load(namespace)
        XCTAssertEqual(recovered.bytes, bytes(1))
        XCTAssertNil(recovered.error)
        XCTAssertEqual(callbacks.withLock { $0 }, 0)
    }

    func testOldOwnerCloseCannotFlushOrRemoveReplacementPendingSnapshot() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Mutex<UInt64>(0)
        let written = Mutex<[Data]>([])
        let store = ShellStore(directoryURL: directory, now: { clock.withLock { $0 } }, writeFile: { data, _ in
            written.withLock { $0.append(data) }
        })
        let namespace = namespace()
        store.submit(write(namespace, revision: 1)) { _ in }
        let replacement = ShellServiceOwner(generation: 2, owner: 0, epoch: 1)
        let next = ShellStore.Write(
            namespace: namespace,
            id: ShellServiceID(owner: replacement, request: 1),
            revision: 2,
            bytes: bytes(2)
        )
        store.submit(next) { _ in }
        _ = await store.close([namespace: owner()])
        XCTAssertTrue(written.withLock { $0.isEmpty })
        let snapshot = await store.load(namespace)
        XCTAssertEqual(snapshot.bytes, bytes(2))
        _ = await store.close([namespace: replacement])
        XCTAssertEqual(written.withLock { $0 }, [Data(bytes(2))])
    }

    func testStoreFilesystemWorkRunsAwayFromMainActor() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let onMain = Mutex<Bool?>(nil)
        let store = ShellStore(
            directoryURL: directory,
            writeFile: { _, _ in onMain.withLock { $0 = Thread.isMainThread } }
        )
        let namespace = namespace()
        store.submit(write(namespace, revision: 1)) { _ in }
        _ = await store.close([namespace: owner()])
        XCTAssertEqual(onMain.withLock { $0 }, false)
    }

    func testSubmittingWhileDiskWriteIsBlockedReturnsAndRetainsLatestValue() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "disk write started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let firstBytes = Data(bytes(1))
        let store = ShellStore(directoryURL: directory, writeFile: { data, _ in
            if data == firstBytes {
                started.fulfill()
                release.wait()
            }
        })
        let first = namespace()
        let second = namespace(instance: "second")
        store.submit(write(first, revision: 1)) { _ in }
        let flushing = Task { await store.flush([first]) }
        await fulfillment(of: [started], timeout: 2)
        store.submit(write(second, revision: 2)) { _ in }
        store.submit(write(second, revision: 3)) { _ in }
        release.signal()
        let failures = await flushing.value
        XCTAssertTrue(failures.isEmpty)
        let snapshot = await store.load(second)
        XCTAssertEqual(snapshot.bytes, bytes(3))
        _ = await store.close([first: owner(), second: owner()])
    }

    func testReplacementKeepsTeardownFlushIntentAndItsOwnCompletion() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "disk write holds the store queue")
        let replaced = expectation(description: "replacement is flushed without advancing the clock")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let firstBytes = Data(bytes(1))
        let written = Mutex<[Data]>([])
        let store = ShellStore(directoryURL: directory, now: { 0 }, writeFile: { data, _ in
            if data == firstBytes {
                started.fulfill()
                release.wait()
            }
            written.withLock { $0.append(data) }
        })
        let blocked = namespace(instance: "blocked")
        let target = namespace(instance: "replacement")
        store.submit(write(blocked, revision: 1)) { _ in }
        let flushing = Task { await store.flush([blocked]) }
        await fulfillment(of: [started], timeout: 2)
        store.submit(write(target, revision: 2), final: true) { _ in XCTFail("retired callback") }
        let replacement = ShellServiceOwner(generation: 2, owner: 0, epoch: 1)
        let next = ShellStore.Write(
            namespace: target,
            id: ShellServiceID(owner: replacement, request: 1),
            revision: 1,
            bytes: bytes(3)
        )
        store.submit(next) { commit in
            XCTAssertEqual(commit.id.owner, replacement)
            XCTAssertNil(commit.error)
            replaced.fulfill()
        }
        release.signal()
        _ = await flushing.value
        await fulfillment(of: [replaced], timeout: 2)
        XCTAssertEqual(written.withLock { $0 }, [firstBytes, Data(bytes(3))])
        _ = await store.close([blocked: owner(), target: replacement])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func namespace(
        profile: String = "lake",
        package: String = "lake",
        instance: String? = nil
    ) -> ShellStoreNamespace {
        ShellStoreNamespace(profile: profile, package: package, instance: instance)
    }

    private func owner() -> ShellServiceOwner {
        ShellServiceOwner(generation: 1, owner: 0, epoch: 1)
    }

    private func id() -> ShellServiceID {
        ShellServiceID(owner: owner(), request: 1)
    }

    private func write(_ namespace: ShellStoreNamespace, revision: UInt64) -> ShellStore.Write {
        ShellStore.Write(namespace: namespace, id: id(), revision: revision, bytes: bytes(Int(revision)))
    }

    private func bytes(_ value: Int) -> [UInt8] {
        var writer = ShellValueWriter()
        writer.map(1)
        writer.key("value")
        writer.number(Double(value))
        return writer.bytes
    }
}
