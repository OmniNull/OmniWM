// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class ShellDesktopServicesTests: XCTestCase {
    private final class Signal: Sendable {
        private struct State {
            var count = 0
            var waiters: [CheckedContinuation<Void, Never>] = []
        }

        private let state = Mutex(State())

        func fire() {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                if !state.waiters.isEmpty { return state.waiters.removeFirst() }
                state.count += 1
                return nil
            }
            waiter?.resume()
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state in
                    if state.count > 0 { state.count -= 1
                        return true
                    }
                    state.waiters.append(continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        }
    }

    @MainActor
    private final class Platform {
        var picks = 0
        var cancellations = 0
        var picker: ShellDesktopPlatform.PickCompletion?
        var opens: [URL] = []
        var openCompletion: (@Sendable (String?) -> Void)?
        var reveals: [URL] = []
        let opened = Signal()
        let cancelled = Signal()

        var value: ShellDesktopPlatform {
            ShellDesktopPlatform(pick: { [self] _, _, completion in
                picks += 1
                picker = completion
                return { self.cancellations += 1
                    self.cancelled.fire()
                }
            }, open: { [self] url, completion in
                opens.append(url)
                openCompletion = completion
                opened.fire()
            }, reveal: { [self] url in
                reveals.append(url)
                return false
            })
        }
    }

    private let owner = ShellServiceOwner(generation: 5, owner: 2, epoch: 3)

    private func id(_ request: UInt64, owner: ShellServiceOwner? = nil) -> ShellServiceID {
        ShellServiceID(owner: owner ?? self.owner, request: request)
    }

    private func store() async throws -> (ShellResourceStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ShellResourceStore(directory: root)
        try await store.activate(
            owner,
            namespace: ShellStoreNamespace(profile: "fixture", package: "desktop", instance: nil)
        )
        return (store, root)
    }

    private func source() -> ShellDesktopSource {
        ShellDesktopSource(window: nil, isCurrent: { true }, beginFocus: { _ in { _ in } })
    }

    private func bridge(_ store: ShellResourceStore, retired: Signal? = nil) -> ShellDesktopResourceBridge {
        ShellDesktopResourceBridge(admit: { id, items in
            let descriptors = items.map {
                ShellResourceDescriptor(id: ShellResourceID(), name: $0.name, kind: $0.kind, uti: $0.uti)
            }
            try store.catalog.admit(descriptors, owner: id.owner)
            return descriptors.map(\.id)
        }, retireIDs: { owner, ids in
            for id in ids { XCTAssertNil(store.catalog.metadata(id, owner: owner)) }
            retired?.fire()
        })
    }

    func testLedgerDistinguishesDeliveryQueuedCancellationCloseAndUndeliveredTail() {
        let ledger = ShellServiceLedger(generation: owner.generation)
        let discarded = Mutex<[UInt64]>([])
        let discard: @Sendable (ShellServiceCompletion) -> Void = { completion in
            _ = ledger.activeCount
            discarded.withLock { $0.append(completion.id.request) }
        }
        for number in 1 ... 4 {
            XCTAssertTrue(ledger.register(id(UInt64(number)), discard: discard))
            XCTAssertTrue(ledger.complete(ShellServiceCompletion(id: id(UInt64(number)), payload: [0])))
        }
        let delivered = ledger.takeBatch(limit: 2)
        XCTAssertEqual(discarded.withLock { $0 }, [])
        delivered[1].discardUndelivered()
        XCTAssertEqual(discarded.withLock { $0 }, [2])
        ledger.cancel(id(3))
        XCTAssertEqual(discarded.withLock { $0 }, [2, 3])
        ledger.cancel(owner: owner)
        XCTAssertEqual(discarded.withLock { $0 }, [2, 3, 4])
        XCTAssertTrue(ledger.register(id(5), discard: discard))
        XCTAssertTrue(ledger.complete(ShellServiceCompletion(id: id(5), payload: [0])))
        ledger.close()
        XCTAssertEqual(discarded.withLock { $0 }, [2, 3, 4, 5])
        XCTAssertFalse(ledger.complete(ShellServiceCompletion(id: id(5), payload: [0])))
        XCTAssertEqual(discarded.withLock { $0 }, [2, 3, 4, 5])
        XCTAssertEqual(ledger.activeCount, 0)
    }

    func testPickerCancellationReleasesPublicCapacityButWaitsForActualDialogCompletion() async throws {
        let (store, root) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let platform = Platform()
        let desktop = ShellDesktopServices(resources: store, platform: platform.value)
        let ledger = ShellServiceLedger(generation: owner.generation)
        let bridge = bridge(store)
        XCTAssertTrue(desktop.perform(
            ShellDesktopRequest(id: id(1), action: .pick(multiple: true)),
            ledger: ledger,
            bridge: bridge,
            source: source()
        ))
        XCTAssertEqual(platform.picks, 1)
        ledger.cancel(id(1))
        XCTAssertEqual(ledger.activeCount, 0)
        await platform.cancelled.wait()
        XCTAssertEqual(platform.cancellations, 1)
        XCTAssertTrue(desktop.perform(
            ShellDesktopRequest(id: id(2), action: .pick(multiple: false)),
            ledger: ledger,
            bridge: bridge,
            source: source()
        ))
        XCTAssertEqual(platform.picks, 1)
        let busy = try XCTUnwrap(ledger.takeBatch().first)
        XCTAssertEqual(try ShellServiceValue.decode(busy.payload).fields?["error"]?.string, "picker_busy")
        platform.picker?(.failure(ShellResourceFailure("cancelled")))
        XCTAssertTrue(ledger.takeBatch().isEmpty)
        XCTAssertTrue(desktop.perform(
            ShellDesktopRequest(id: id(3), action: .pick(multiple: false)),
            ledger: ledger,
            bridge: bridge,
            source: source()
        ))
        XCTAssertEqual(platform.picks, 2)
        platform.picker?(.failure(ShellResourceFailure("cancelled")))
        let cancelled = try XCTUnwrap(ledger.takeBatch().first)
        XCTAssertEqual(try ShellServiceValue.decode(cancelled.payload).fields?["error"]?.string, "cancelled")
        ledger.close()
    }

    func testPickedResourcesUseIssuedIDsAndQueuedCancellationDisposesUnpublishedHandles() async throws {
        let (store, root) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("selected.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("picked".utf8).write(to: file)
        let platform = Platform()
        let desktop = ShellDesktopServices(resources: store, platform: platform.value)
        let ledger = ShellServiceLedger(generation: owner.generation)
        let completed = Signal()
        let retired = Signal()
        ledger.attachWake { completed.fire() }
        XCTAssertTrue(desktop.perform(
            ShellDesktopRequest(id: id(1), action: .pick(multiple: false)),
            ledger: ledger,
            bridge: bridge(store, retired: retired),
            source: source()
        ))
        platform.picker?(.success([file]))
        await completed.wait()
        let delivered = try XCTUnwrap(ledger.takeBatch().first)
        let selected = try XCTUnwrap(delivered.desktopResources?.first)
        XCTAssertEqual(store.catalog.metadata(selected, owner: owner)?.state, .ready)
        delivered.discardUndelivered()
        await retired.wait()
        XCTAssertNil(store.catalog.metadata(selected, owner: owner))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        _ = ledger.finishBatch()
        XCTAssertTrue(desktop.perform(
            ShellDesktopRequest(id: id(2), action: .pick(multiple: false)),
            ledger: ledger,
            bridge: bridge(store, retired: retired),
            source: source()
        ))
        platform.picker?(.success([file]))
        await completed.wait()
        ledger.cancel(id(2))
        await retired.wait()
        XCTAssertTrue(ledger.takeBatch().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testOpenRetainsBackingThroughNativeCompletionAndRejectsForeignOwner() async throws {
        let (store, root) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let resource = ShellResourceDescriptor(
            id: ShellResourceID(),
            name: "owned.txt",
            kind: "file",
            uti: "public.text"
        )
        try store.catalog.admit([resource], owner: owner)
        try await store.materialize([.bytes(Data("owned".utf8))], ids: [resource.id], owner: owner)
        let platform = Platform()
        let desktop = ShellDesktopServices(resources: store, platform: platform.value)
        let ledger = ShellServiceLedger(generation: owner.generation)
        let completed = Signal()
        ledger.attachWake { completed.fire() }
        XCTAssertTrue(desktop.perform(
            ShellDesktopRequest(id: id(1), action: .open(resource.id)),
            ledger: ledger,
            bridge: bridge(store)
        ))
        await platform.opened.wait()
        let opened = try XCTUnwrap(platform.opens.first)
        await store.release([resource.id], owner: owner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: opened.path))
        platform.openCompletion?("fixture native error")
        await completed.wait()
        let result = try XCTUnwrap(ledger.takeBatch().first)
        XCTAssertEqual(try ShellServiceValue.decode(result.payload).fields?["error"]?.string, "fixture native error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.path))
        _ = ledger.finishBatch()
        let other = ShellResourceDescriptor(id: ShellResourceID(), name: "other", kind: "text", uti: "public.text")
        try store.catalog.admit([other], owner: owner)
        try await store.materialize([.text("owner-only")], ids: [other.id], owner: owner)
        let foreign = ShellServiceOwner(generation: owner.generation, owner: 7, epoch: 1)
        try await store.activate(
            foreign,
            namespace: ShellStoreNamespace(profile: "fixture", package: "foreign", instance: nil)
        )
        XCTAssertTrue(desktop.perform(
            ShellDesktopRequest(id: id(2, owner: foreign), action: .open(other.id)),
            ledger: ledger,
            bridge: bridge(store)
        ))
        await completed.wait()
        XCTAssertEqual(platform.opens.count, 1)
        XCTAssertNotNil(try ShellServiceValue.decode(XCTUnwrap(ledger.takeBatch().first).payload).fields?["error"]?
            .string)
    }

    func testReservationRejectionAndInvalidFileURLNeverPresentOrOpen() async throws {
        let (store, root) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let platform = Platform()
        let desktop = ShellDesktopServices(resources: store, platform: platform.value)
        let closed = ShellServiceLedger(generation: owner.generation)
        closed.close()
        XCTAssertFalse(desktop.perform(
            ShellDesktopRequest(id: id(1), action: .pick(multiple: false)),
            ledger: closed,
            bridge: bridge(store),
            source: source()
        ))
        XCTAssertEqual(platform.picks, 0)
        let ledger = ShellServiceLedger(generation: owner.generation)
        XCTAssertTrue(desktop.perform(
            ShellDesktopRequest(id: id(2), action: .openURL(URL(fileURLWithPath: "/private/file"))),
            ledger: ledger,
            bridge: bridge(store)
        ))
        let failure = try XCTUnwrap(ledger.takeBatch().first)
        XCTAssertEqual(
            try ShellServiceValue.decode(failure.payload).fields?["error"]?.string,
            "file_url_requires_resource"
        )
        XCTAssertTrue(platform.opens.isEmpty)
        XCTAssertTrue(platform.reveals.isEmpty)
        let descriptor = ShellResourceDescriptor(
            id: ShellResourceID(),
            name: "reveal",
            kind: "file",
            uti: "public.data"
        )
        try store.catalog.admit([descriptor], owner: owner)
        try await store.materialize([.bytes(Data([1]))], ids: [descriptor.id], owner: owner)
        let completed = Signal()
        _ = ledger.finishBatch()
        ledger.attachWake { completed.fire() }
        XCTAssertTrue(desktop.perform(
            ShellDesktopRequest(id: id(3), action: .reveal(descriptor.id)),
            ledger: ledger,
            bridge: bridge(store)
        ))
        await completed.wait()
        XCTAssertEqual(platform.reveals.count, 1)
        let reveal = try XCTUnwrap(ledger.takeBatch().first)
        XCTAssertEqual(try ShellServiceValue.decode(reveal.payload).fields?["error"]?.string, "reveal_failed")
    }
}
