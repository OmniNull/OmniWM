// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import Synchronization
import XCTest

@MainActor
final class ShellDropIngressTests: XCTestCase {
    private final class Signal: Sendable {
        private struct State {
            var count = 0
            var waiters: [CheckedContinuation<Void, Never>] = []
        }

        private let state = Mutex(State())
        func fire() {
            let waiter = state.withLock { value -> CheckedContinuation<Void, Never>? in
                if !value.waiters.isEmpty { return value.waiters.removeFirst() }
                value.count += 1
                return nil
            }
            waiter?.resume()
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { value in
                    if value.count > 0 { value.count -= 1
                        return true
                    }
                    value.waiters.append(continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        }
    }

    private final class Records: Sendable {
        struct State {
            var admissions = 0
            var transferred = true
            var delivered: [ShellResourceID] = []
            var retired: [ShellResourceID] = []
            var finished: [ShellServiceID] = []
            var pendingAtDelivery = false
        }

        let state = Mutex(State())
        let delivery = Signal()
        let finish = Signal()
    }

    private let owner = ShellServiceOwner(generation: 501, owner: 2, epoch: 3)
    private func reservation(_ request: UInt64, source: UInt64 = 40) -> ShellDropReservation {
        ShellDropReservation(
            id: ShellServiceID(owner: owner, request: request),
            authority: ShellDropAuthority(
                handle: ElementHandle(slot: 1, generation: 3),
                sequence: 1,
                action: 42,
                accepts: ShellDropTypes.all.rawValue,
                sourceID: source
            )
        )
    }

    private func store() async throws -> (ShellResourceStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ShellResourceStore(directory: root)
        try await store.activate(
            owner,
            namespace: ShellStoreNamespace(profile: "fixture", package: "drop", instance: nil)
        )
        return (store, root)
    }

    private func bridge(
        _ store: ShellResourceStore,
        ledger: ShellServiceLedger,
        records: Records
    ) -> ShellDropResourceBridge {
        ShellDropResourceBridge(admit: { reservation, values in
            let values = values.map { ShellResourceDescriptor(
                id: ShellResourceID(),
                name: $0.name,
                kind: $0.kind,
                uti: $0.uti
            ) }
            try store.catalog.admit(values, owner: reservation.id.owner)
            records.state.withLock { $0.admissions += 1 }
            return values.map(\.id)
        }, deliver: { reservation, values, _ in
            let pending = values
                .allSatisfy { store.catalog.metadata($0, owner: reservation.id.owner)?.state == .pending }
            let result = records.state.withLock { value in
                value.delivered = values
                value.pendingAtDelivery = pending
                return value.transferred
            }
            records.delivery.fire()
            return result
        }, retire: { _, values in
            records.state.withLock { $0.retired += values }
        }, finish: { reservation in
            ledger.cancel(reservation.id)
            records.state.withLock { $0.finished.append(reservation.id) }
            records.finish.fire()
        })
    }

    private func text(_ name: String = "text") -> ShellDropItem {
        ShellDropItem(name: name, kind: "text", uti: "public.utf8-plain-text", source: .text("content"))
    }

    func testReadyPreflightConsumesPhysicalCapacityAndSourceCancellationReleasesExactlyOnce() async throws {
        let (store, root) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = ShellServiceLedger(generation: owner.generation)
        let records = Records()
        let ingress = ShellDropIngress(resources: store, report: { _ in })
        let bridge = bridge(store, ledger: ledger, records: records)
        var reservations: [ShellDropReservation] = []
        for number in 1 ... 32 {
            let value = reservation(UInt64(number))
            reservations.append(value)
            XCTAssertTrue(ledger.register(value.id))
            XCTAssertTrue(ingress.prepare(value, ledger: ledger, bridge: bridge))
        }
        let overflow = reservation(33)
        XCTAssertTrue(ledger.register(overflow.id))
        XCTAssertFalse(ingress.prepare(overflow, ledger: ledger, bridge: bridge))
        ledger.cancel(overflow.id)
        XCTAssertEqual(ingress.activeCount, 32)
        ingress.cancel(sourceID: 40)
        for value in reservations { await ingress.waitUntilFinished(value) }
        XCTAssertEqual(ingress.activeCount, 0)
        XCTAssertEqual(ledger.activeCount, 0)
        XCTAssertEqual(records.state.withLock { Set($0.finished) }, Set(reservations.map(\.id)))
        XCTAssertEqual(records.state.withLock { $0.finished.count }, 32)
        XCTAssertEqual(records.state.withLock { $0.admissions }, 0)
    }

    func testImmediateDropPublishesPendingThenMaterializesOnResourceOwner() async throws {
        let (store, root) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = ShellServiceLedger(generation: owner.generation)
        let records = Records()
        let ingress = ShellDropIngress(resources: store, report: { _ in })
        let reservation = reservation(101)
        XCTAssertTrue(ledger.register(reservation.id))
        XCTAssertTrue(ingress.prepare(
            reservation,
            ledger: ledger,
            bridge: bridge(store, ledger: ledger, records: records)
        ))
        ingress.accept(reservation, items: [text()], promises: nil, point: CGPoint(x: 12, y: 34))
        await ingress.waitUntilFinished(reservation)
        let ids = records.state.withLock { $0.delivered }
        XCTAssertEqual(ids.count, 1)
        XCTAssertTrue(records.state.withLock { $0.pendingAtDelivery })
        XCTAssertEqual(store.catalog.metadata(try XCTUnwrap(ids.first), owner: owner)?.state, .ready)
        XCTAssertTrue(records.state.withLock { $0.retired.isEmpty })
        XCTAssertEqual(ingress.activeCount, 0)
        await store.release(ids, owner: owner)
    }

    func testStaleDeliveryDiscardsNativeAndCatalogIDsBeforeFinishing() async throws {
        let (store, root) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = ShellServiceLedger(generation: owner.generation)
        let records = Records()
        records.state.withLock { $0.transferred = false }
        let ingress = ShellDropIngress(resources: store, report: { _ in })
        let reservation = reservation(102)
        XCTAssertTrue(ledger.register(reservation.id))
        XCTAssertTrue(ingress.prepare(
            reservation,
            ledger: ledger,
            bridge: bridge(store, ledger: ledger, records: records)
        ))
        ingress.accept(reservation, items: [text()], promises: nil, point: .zero)
        await ingress.waitUntilFinished(reservation)
        let ids = records.state.withLock { $0.delivered }
        XCTAssertEqual(records.state.withLock { $0.retired }, ids)
        XCTAssertTrue(ids.allSatisfy { store.catalog.metadata($0, owner: owner) == nil })
        XCTAssertEqual(records.state.withLock { $0.finished }, [reservation.id])
    }

    func testCancelledPromiseKeepsDirectoryAndCapacityUntilEveryActualCallback() async throws {
        let (store, root) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = ShellServiceLedger(generation: owner.generation)
        let records = Records()
        let ingress = ShellDropIngress(resources: store, report: { _ in })
        let reservation = reservation(103)
        var received: ShellFilePromiseBatch?
        let promises = ShellDropIngress.Promises(count: 2) { batch, _ in
            received = batch
            return try batch.configure(names: [["a"], ["b"]], types: [[], []])
        }
        XCTAssertTrue(ledger.register(reservation.id))
        XCTAssertTrue(ingress.prepare(
            reservation,
            ledger: ledger,
            bridge: bridge(store, ledger: ledger, records: records)
        ))
        ingress.accept(reservation, items: [], promises: promises, point: .zero)
        await records.delivery.wait()
        let batch = try XCTUnwrap(received)
        ingress.cancel(reservation)
        batch.receive(receiver: 0, url: URL(fileURLWithPath: "/ignored"), error: "cancelled")
        XCTAssertEqual(ingress.activeCount, 1)
        XCTAssertEqual(ledger.activeCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: batch.directory.path))
        XCTAssertTrue(records.state.withLock { $0.finished.isEmpty })
        batch.receive(receiver: 1, url: URL(fileURLWithPath: "/ignored"), error: "cancelled")
        await ingress.waitUntilFinished(reservation)
        XCTAssertEqual(ingress.activeCount, 0)
        XCTAssertEqual(ledger.activeCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.directory.path))
        await store.release(records.state.withLock { $0.delivered }, owner: owner)
    }

    func testCombinedImmediateAndPromiseOverflowRejectsAtomicallyButDrainsActualCallbacks() async throws {
        let (store, root) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = ShellServiceLedger(generation: owner.generation)
        let records = Records()
        let started = Signal()
        let ingress = ShellDropIngress(resources: store, report: { _ in })
        let reservation = reservation(104)
        var received: ShellFilePromiseBatch?
        let promises = ShellDropIngress.Promises(count: 1) { batch, _ in
            received = batch
            let names = try batch.configure(names: [(0 ..< 32).map { "file-\($0)" }], types: [[]])
            started.fire()
            return names
        }
        XCTAssertTrue(ledger.register(reservation.id))
        XCTAssertTrue(ingress.prepare(
            reservation,
            ledger: ledger,
            bridge: bridge(store, ledger: ledger, records: records)
        ))
        ingress.accept(reservation, items: [text()], promises: promises, point: .zero)
        await started.wait()
        let batch = try XCTUnwrap(received)
        XCTAssertEqual(ingress.activeCount, 1)
        XCTAssertEqual(records.state.withLock { $0.admissions }, 0)
        for _ in 0 ..< 32 { batch.receive(receiver: 0, url: URL(fileURLWithPath: "/ignored"), error: "declined") }
        await ingress.waitUntilFinished(reservation)
        XCTAssertEqual(records.state.withLock { $0.admissions }, 0)
        XCTAssertTrue(records.state.withLock { $0.delivered.isEmpty })
        XCTAssertEqual(ingress.activeCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.directory.path))
    }

    func testDeliveredPromisesSurviveSourceHideAndDrainMoreThanOneBatch() async throws {
        let (store, root) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = ShellServiceLedger(generation: owner.generation)
        let records = Records()
        let ingress = ShellDropIngress(resources: store, report: { _ in })
        let reservation = reservation(105)
        var received: ShellFilePromiseBatch?
        let promises = ShellDropIngress.Promises(count: 1) { batch, _ in
            received = batch
            return try batch.configure(names: [(0 ..< 32).map { "file-\($0)" }], types: [[]])
        }
        XCTAssertTrue(ledger.register(reservation.id))
        XCTAssertTrue(ingress.prepare(
            reservation,
            ledger: ledger,
            bridge: bridge(store, ledger: ledger, records: records)
        ))
        ingress.accept(reservation, items: [], promises: promises, point: .zero)
        await records.delivery.wait()
        let batch = try XCTUnwrap(received)
        ingress.cancel(sourceID: reservation.authority.sourceID)
        XCTAssertTrue(reservation.operation.isActive)
        for _ in 0 ..< 32 { batch.receive(
            receiver: 0,
            url: URL(fileURLWithPath: "/ignored"),
            error: "external producer failed"
        ) }
        await ingress.waitUntilFinished(reservation)
        let ids = records.state.withLock { $0.delivered }
        XCTAssertEqual(ids.count, 32)
        XCTAssertTrue(ids.allSatisfy { store.catalog.metadata($0, owner: owner)?.state == .failed })
        XCTAssertTrue(records.state.withLock { $0.retired.isEmpty })
        XCTAssertEqual(records.state.withLock { $0.finished }, [reservation.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.directory.path))
        await store.release(ids, owner: owner)
    }
}
