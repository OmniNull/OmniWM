// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellResourceHTTPTests: XCTestCase {
    func testBodyReadsReadyValuesAndRejectsForeignPendingCancelledAndOversizedResources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShellResourceStore(directory: directory)
        let owner = ShellServiceOwner(generation: 1, owner: 2, epoch: 3)
        try await store.activate(
            owner,
            namespace: ShellStoreNamespace(profile: "lake", package: "lake", instance: "upload")
        )
        let items = (0 ..< 4).map { ShellResourceDescriptor(
            id: ShellResourceID(),
            name: "item\($0)",
            kind: "file",
            uti: "public.data"
        ) }
        try store.catalog.admit(items, owner: owner)
        try await store.materialize(
            [
                .bytes(Data([0, 1, 255])),
                .text("hello"),
                .bytes(Data(repeating: 0, count: ShellHTTPService.byteLimit + 1))
            ],
            ids: Array(items.prefix(3)).map(\.id),
            owner: owner
        )
        let bytes = try await store.httpBody(items[0].id, owner: owner, operation: ShellResourceOperation())
        let text = try await store.httpBody(items[1].id, owner: owner, operation: ShellResourceOperation())
        XCTAssertEqual(bytes, [0, 1, 255])
        XCTAssertEqual(text, Array("hello".utf8))
        do {
            _ = try await store.httpBody(items[2].id, owner: owner, operation: ShellResourceOperation())
            XCTFail("oversized body accepted")
        } catch { XCTAssertEqual((error as? ShellHTTPFailure)?.code, "body_too_large") }
        do {
            _ = try await store.httpBody(items[3].id, owner: owner, operation: ShellResourceOperation())
            XCTFail("pending resource accepted")
        } catch { XCTAssertTrue(error is ShellResourceFailure) }
        let foreign = ShellServiceOwner(generation: 1, owner: 3, epoch: 3)
        do {
            _ = try await store.httpBody(items[0].id, owner: foreign, operation: ShellResourceOperation())
            XCTFail("foreign resource accepted")
        } catch { XCTAssertTrue(error is ShellResourceFailure) }
        let cancelled = ShellResourceOperation()
        cancelled.cancel()
        do {
            _ = try await store.httpBody(items[0].id, owner: owner, operation: cancelled)
            XCTFail("cancelled body accepted")
        } catch { XCTAssertEqual((error as? ShellHTTPFailure)?.code, "cancelled") }
        _ = await store.retire(owner)
    }

    func testCancelledPreparationCannotStartHTTPAfterLedgerHandoff() {
        let ledger = ShellServiceLedger(generation: 1)
        let id = ShellServiceID(owner: ShellServiceOwner(generation: 1, owner: 0, epoch: 1), request: 1)
        XCTAssertTrue(ledger.register(id))
        ledger.cancel(id)
        let service = ShellHTTPService(ledger: ledger)
        XCTAssertFalse(service.start(
            id,
            request: ShellHTTPRequest(url: "https://upload.example"),
            policy: .hosts(["upload.example"]),
            registered: true
        ))
        XCTAssertEqual(service.activeCount, 0)
        XCTAssertEqual(ledger.activeCount, 0)
    }
}
