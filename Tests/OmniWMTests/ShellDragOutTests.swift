// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import Synchronization
import XCTest

@MainActor
final class ShellDragOutTests: XCTestCase {
    private actor Admission {
        private var pending: CheckedContinuation<ShellDragOutPreparation, any Error>?
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var count = 0

        func prepare() async throws -> ShellDragOutPreparation {
            try await withCheckedThrowingContinuation { continuation in
                count += 1
                pending = continuation
                let waiters = waiters
                self.waiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }

        func waitForRequest() async {
            if pending != nil { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func finish(_ value: ShellDragOutPreparation) {
            let continuation = pending
            pending = nil
            continuation?.resume(returning: value)
        }
    }

    private actor Gate {
        private var started = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var continuation: CheckedContinuation<Void, Never>?

        func enter() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started = true
                let waiters = waiters
                self.waiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }

        func waitUntilEntered() async {
            if started { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private let owner = ShellServiceOwner(generation: 71, owner: 0, epoch: 1)

    private func authority(
        sequence: Int = 1,
        declaration: UInt32 = 42,
        action: UInt32 = 9,
        source: UInt64 = 1
    ) -> ShellDragOutAuthority {
        ShellDragOutAuthority(
            handle: ElementHandle(slot: 1, generation: 8),
            sequence: sequence,
            declaration: declaration,
            action: action,
            sourceID: source
        )
    }

    private func prepared(
        _ authority: ShellDragOutAuthority,
        request: UInt64 = 1,
        begin: @escaping @Sendable () async -> Void = {},
        finish: @escaping @Sendable (Bool, Bool) async -> Void = { _, _ in }
    )
        -> ShellDragOutPreparation
    {
        ShellDragOutPreparation(
            id: ShellServiceID(owner: owner, request: request),
            authority: authority,
            resources: [],
            pin: ShellResourceStore.Pin(id: UUID(), values: []),
            operation: ShellResourceOperation(),
            begin: begin,
            finish: finish
        )
    }

    func testMouseUpBeforePinCompletesDiscardsLatePreparation() async throws {
        let admission = Admission()
        let calls = Mutex<[String]>([])
        let tracker = ShellDragOutTracker(bridge: ShellDragOutBridge(prepare: { _ in try await admission.prepare() }))
        tracker.start(authority(), at: .zero)
        let task = try XCTUnwrap(tracker.preparation)
        await admission.waitForRequest()
        XCTAssertNil(tracker.take(at: CGPoint(x: 30, y: 0), threshold: 6))
        tracker.cancel()
        await admission.finish(prepared(
            authority(),
            begin: { calls.withLock { $0.append("began") } },
            finish: { copied, deliver in
                calls.withLock { $0.append("finish:\(copied):\(deliver)") }
            }
        ))
        await task.value
        XCTAssertNil(tracker.authority)
        XCTAssertNil(tracker.ready)
        XCTAssertEqual(calls.withLock { $0 }, ["finish:false:false"])
    }

    func testReadyPinDoesNotStartUntilNextExplicitThresholdEvent() async throws {
        let admission = Admission()
        let calls = Mutex<[String]>([])
        let tracker = ShellDragOutTracker(bridge: ShellDragOutBridge(prepare: { _ in try await admission.prepare() }))
        tracker.start(authority(), at: CGPoint(x: 10, y: 10))
        let task = try XCTUnwrap(tracker.preparation)
        await admission.waitForRequest()
        XCTAssertNil(tracker.take(at: CGPoint(x: 50, y: 10), threshold: 6))
        await admission.finish(prepared(authority(), begin: { calls.withLock { $0.append("began") } }))
        await task.value
        XCTAssertTrue(calls.withLock { $0.isEmpty })
        XCTAssertNil(tracker.take(at: CGPoint(x: 13, y: 14), threshold: 6))
        let ready = try XCTUnwrap(tracker.take(at: CGPoint(x: 16, y: 10), threshold: 6))
        XCTAssertNil(tracker.take(at: CGPoint(x: 50, y: 10), threshold: 6))
        tracker.cancel()
        XCTAssertTrue(calls.withLock { $0.isEmpty })
        await ready.finish(false, false)
    }

    func testReplacedSourceRejectsLatePinWithoutCancellingNewPreparation() async throws {
        let first = Admission()
        let second = Admission()
        let released = Mutex<[UInt64]>([])
        let tracker = ShellDragOutTracker(bridge: ShellDragOutBridge(prepare: { authority in
            try await (authority.sourceID == 1 ? first : second).prepare()
        }))
        tracker.start(authority(), at: .zero)
        let old = try XCTUnwrap(tracker.preparation)
        await first.waitForRequest()
        tracker.start(authority(source: 2), at: .zero)
        let next = try XCTUnwrap(tracker.preparation)
        await second.waitForRequest()
        await first.finish(prepared(authority(), finish: { _, _ in released.withLock { $0.append(1) } }))
        await old.value
        XCTAssertEqual(tracker.authority?.sourceID, 2)
        XCTAssertEqual(released.withLock { $0 }, [1])
        await second.finish(prepared(authority(source: 2), request: 2))
        await next.value
        let value = try XCTUnwrap(tracker.take(at: CGPoint(x: 10, y: 0), threshold: 6))
        XCTAssertEqual(value.id.request, 2)
        await value.finish(false, false)
    }

    func testAuthorityKeepsStableDeclarationAcrossSequenceOnlyChanges() {
        XCTAssertEqual(authority(), authority(sequence: 99))
        XCTAssertNotEqual(authority(), authority(declaration: 43))
        XCTAssertNotEqual(authority(), authority(action: 10))
        XCTAssertNotEqual(authority(), authority(source: 2))
    }

    func testActualSessionEndOrdersCallbacksAndKeepsPinThroughOwnerRetirement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShellResourceStore(directory: directory)
        try await store.activate(owner, namespace: ShellStoreNamespace(profile: "test", package: "drag", instance: nil))
        let resource = ShellResourceDescriptor(
            id: ShellResourceID(),
            name: "drag.txt",
            kind: "file",
            uti: "public.plain-text"
        )
        try store.catalog.admit([resource], owner: owner)
        try await store.materialize([.bytes(Data("contents".utf8))], ids: [resource.id], owner: owner)
        let pin = try await store.retain([resource.id], owner: owner)
        guard case let .file(file) = try XCTUnwrap(pin.values.first) else { return XCTFail("missing file backing") }
        let gate = Gate()
        let calls = Mutex<[String]>([])
        let operation = ShellResourceOperation()
        let value = ShellDragOutPreparation(
            id: ShellServiceID(owner: owner, request: 1),
            authority: authority(),
            resources: [resource.id],
            pin: pin,
            operation: operation,
            begin: {
                calls.withLock { $0.append("began") }
                await gate.enter()
            },
            finish: { copied, deliver in
                calls.withLock { $0.append("finish:\(copied):\(deliver)") }
                await store.release(pin)
            }
        )
        var session: ShellDragOutSession? = ShellDragOutSession(prepared: value)
        weak let retained = session
        let completion = try XCTUnwrap(session?.completion)
        session?.begin()
        session?.begin()
        await gate.waitUntilEntered()
        operation.cancel()
        _ = await store.retire(owner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        session = nil
        XCTAssertNotNil(retained)
        XCTAssertEqual(calls.withLock { $0 }, ["began"])
        retained?.end(copied: true)
        retained?.end(copied: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        await gate.release()
        await completion.value
        XCTAssertEqual(calls.withLock { $0 }, ["began", "finish:true:true"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(retained)
    }
}
