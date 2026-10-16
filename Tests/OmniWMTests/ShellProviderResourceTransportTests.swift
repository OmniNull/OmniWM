// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import XCTest

final class ShellProviderResourceTransportTests: XCTestCase {
    func testCancellationBeforeSubmissionFencesAndFinishesOnceWithoutWaitingForProcess() {
        let (inbox, identity) = fixture()
        let operation = ShellResourceOperation()
        let key = key(identity, 1)
        XCTAssertTrue(inbox.register(key.id, identity: identity, operation: operation))
        inbox.cancel(key.id)
        XCTAssertFalse(operation.isActive)
        XCTAssertEqual(work(inbox), [.finishAction(key)])
        XCTAssertTrue(inbox.takeBatch(now: 0).isEmpty)
        XCTAssertFalse(inbox.actionPrepared(key, result: .success(Data("frame\n".utf8))))
        XCTAssertEqual(inbox.pendingActions, 1)
        inbox.finishActionCleanup(key)
        inbox.finishActionCleanup(key)
        XCTAssertEqual(inbox.pendingActions, 0)
    }

    func testCancelledSubmittedActionRetainsCleanupAcrossEarlyFailureUntilActualDrain() {
        let (inbox, identity) = fixture()
        let key = submitted(inbox, identity, 1)
        inbox.cancel(key.id)
        XCTAssertTrue(inbox.takeBatch(now: 0).isEmpty)
        inbox.end(identity, status: .failed("early"))
        XCTAssertTrue(work(inbox).isEmpty)
        inbox.incarnationDrained(ShellProviderIdentity(owner: identity.owner, incarnation: identity.incarnation + 1))
        XCTAssertTrue(work(inbox).isEmpty)
        XCTAssertEqual(inbox.pendingActions, 1)
        inbox.incarnationDrained(identity)
        XCTAssertEqual(work(inbox), [.finishAction(key)])
        inbox.finishActionCleanup(key)
        XCTAssertEqual(inbox.pendingActions, 0)
    }

    func testLateCorrelatedTerminalResultOnlyFinishesCancelledLease() {
        let (inbox, identity) = fixture()
        let key = submitted(inbox, identity, 4)
        inbox.cancel(key.id)
        inbox.end(identity, status: .failed("early"))
        _ = inbox.takeBatch(now: 0)
        XCTAssertEqual(
            inbox
                .post(
                    .result(id: "r4", ok: true, value: Data("null".utf8), attachments: Data("{}".utf8)),
                    from: identity
                ),
            .accepted
        )
        let batch = inbox.takeBatch(now: 0)
        XCTAssertTrue(batch.compactMap(\.control).isEmpty)
        XCTAssertEqual(batch.compactMap(\.work), [.finishAction(key)])
        inbox.finishActionCleanup(key)
        XCTAssertEqual(
            inbox.post(.result(id: "r4", ok: true, value: Data("null".utf8), attachments: nil), from: identity),
            .ignored
        )
    }

    func testOrdinaryLedgerConsumptionDoesNotCancelBeforeTypedCallbackButEarlyErrorStillWaitsForDrain() {
        let (inbox, identity) = fixture()
        let operation = ShellResourceOperation()
        let key = submitted(inbox, identity, 1, operation: operation)
        inbox.end(identity, status: .failed("early"))
        let batch = inbox.takeBatch(now: 0)
        XCTAssertEqual(batch.compactMap(\.control), [.result(id: key.id, outcome: .failure("Provider disconnected"))])
        XCTAssertTrue(inbox.beginResultDelivery(key))
        inbox.cancel(key.id)
        XCTAssertTrue(operation.isActive)
        inbox.finishResultDelivery(key)
        XCTAssertFalse(operation.isActive)
        XCTAssertTrue(work(inbox).isEmpty)
        inbox.incarnationDrained(identity)
        XCTAssertEqual(work(inbox), [.finishAction(key)])
    }

    func testResultHeadBlocksLaterControlsThroughDecodeAndImportWithoutHotWakes() {
        let (inbox, identity) = fixture()
        let wakes = Mutex(0)
        inbox.attachWake { wakes.withLock { $0 += 1 } }
        let key = submitted(inbox, identity, 1)
        let dataID = ShellServiceID(owner: identity.owner, request: 2)
        XCTAssertTrue(inbox.register(dataID, identity: identity))
        inbox.post(.event(name: "before", value: Data("null".utf8)), from: identity)
        let metadata = Data("{\"files\":[]}".utf8)
        inbox.post(.result(id: "r1", ok: true, value: Data("7".utf8), attachments: metadata), from: identity)
        inbox.post(.event(name: "after", value: Data("null".utf8)), from: identity)
        inbox.post(.result(id: "r2", ok: true, value: Data("8".utf8), attachments: nil), from: identity)
        let first = inbox.takeBatch(now: 0)
        XCTAssertEqual(first.compactMap(\.control), [.event(name: "before", value: Data("null".utf8))])
        XCTAssertEqual(first.compactMap(\.work), [.decodeResult(key, metadata)])
        XCTAssertNil(first.last?.snapshot)
        XCTAssertEqual(inbox.finishBatch(now: 0), .idle)
        let before = wakes.withLock { $0 }
        XCTAssertTrue(inbox.takeBatch(now: 0).isEmpty)
        XCTAssertEqual(inbox.finishBatch(now: 0), .idle)
        XCTAssertEqual(wakes.withLock { $0 }, before)
        let outputs = ShellPreparedProviderOutputs(files: [], descriptors: [])
        XCTAssertTrue(inbox.prepareResultMetadata(key, result: .success(outputs)))
        XCTAssertEqual(work(inbox), [.importResult(key, outputs)])
        XCTAssertEqual(inbox.finishBatch(now: 0), .idle)
        XCTAssertFalse(inbox.prepareResultMetadata(key, result: .failure(ShellResourceFailure("duplicate"))))
        XCTAssertTrue(inbox.takeBatch(now: 0).isEmpty)
        let id = ShellResourceID()
        XCTAssertTrue(inbox.finishResultImport(key, result: .success([id])))
        inbox.post(.state(topic: "latest", value: Data("9".utf8)), from: identity)
        let final = inbox.takeBatch(now: 0)
        XCTAssertEqual(final.compactMap(\.control), [
            .result(id: key.id, outcome: .resources(value: Data("7".utf8), ids: [id])),
            .event(name: "after", value: Data("null".utf8)),
            .result(id: dataID, outcome: .provider(ok: true, value: Data("8".utf8), attachments: nil))
        ])
        XCTAssertEqual(final.first?.snapshot?.topics, [.init(name: "latest", value: Data("9".utf8))])
        XCTAssertTrue(inbox.beginResultDelivery(key))
        inbox.finishResultDelivery(key)
        XCTAssertEqual(work(inbox), [.finishAction(key)])
    }

    func testCancellingBlockedImportUnblocksControlsButWaitsForActualUtilityReturn() {
        let (inbox, identity) = fixture()
        let key = submitted(inbox, identity, 1)
        inbox.post(.result(id: "r1", ok: true, value: Data("null".utf8), attachments: Data("{}".utf8)), from: identity)
        inbox.post(.event(name: "after", value: Data("null".utf8)), from: identity)
        XCTAssertEqual(work(inbox), [.decodeResult(key, Data("{}".utf8))])
        let outputs = ShellPreparedProviderOutputs(files: [], descriptors: [])
        XCTAssertTrue(inbox.prepareResultMetadata(key, result: .success(outputs)))
        XCTAssertEqual(work(inbox), [.importResult(key, outputs)])
        inbox.cancel(key.id)
        let batch = inbox.takeBatch(now: 0)
        XCTAssertEqual(batch.compactMap(\.control), [.event(name: "after", value: Data("null".utf8))])
        XCTAssertTrue(batch.compactMap(\.work).isEmpty)
        XCTAssertFalse(inbox.finishResultImport(key, result: .success([ShellResourceID()])))
        XCTAssertEqual(work(inbox), [.finishAction(key)])
    }

    func testAcceptedOldIncarnationResultRetainsConsumerOwnershipAfterPhysicalDrain() {
        let (inbox, identity) = fixture()
        let key = submitted(inbox, identity, 1)
        inbox.post(.result(id: "r1", ok: true, value: Data("null".utf8), attachments: Data("{}".utf8)), from: identity)
        inbox.end(identity, status: .exited(0))
        inbox.incarnationDrained(identity)
        let replacement = ShellProviderIdentity(owner: identity.owner, incarnation: 2)
        XCTAssertTrue(inbox.activate(replacement))
        let batch = inbox.takeBatch(now: 0)
        XCTAssertEqual(batch.compactMap(\.work), [.decodeResult(key, Data("{}".utf8))])
        XCTAssertEqual(inbox.pendingActions, 1)
        XCTAssertTrue(inbox.prepareResultMetadata(key, result: .failure(ShellResourceFailure("bad metadata"))))
        XCTAssertEqual(
            inbox.takeBatch(now: 0).compactMap(\.control),
            [.result(id: key.id, outcome: .failure("bad metadata"))]
        )
        XCTAssertTrue(inbox.beginResultDelivery(key))
        inbox.finishResultDelivery(key)
        XCTAssertEqual(work(inbox), [.finishAction(key)])
        inbox.finishActionCleanup(key)
        XCTAssertEqual(inbox.binding(for: identity.owner)?.identity, replacement)
        XCTAssertEqual(inbox.pendingActions, 0)
    }

    func testFailureMetadataNeverStartsImportOrChangesProviderFailure() {
        let (inbox, identity) = fixture()
        let key = submitted(inbox, identity, 1)
        let failure = Data("\"conversion_failed\"".utf8)
        inbox.post(
            .result(
                id: "r1",
                ok: false,
                value: failure,
                attachments: Data("{\"files\":[{\"name\":\"a\",\"path\":\"a\"}]}".utf8)
            ),
            from: identity
        )
        let batch = inbox.takeBatch(now: 0)
        XCTAssertTrue(batch.compactMap(\.work).isEmpty)
        XCTAssertEqual(
            batch.compactMap(\.control),
            [.result(id: key.id, outcome: .provider(ok: false, value: failure, attachments: nil))]
        )
        XCTAssertFalse(inbox.prepareResultMetadata(
            key,
            result: .success(ShellPreparedProviderOutputs(files: [], descriptors: []))
        ))
        XCTAssertFalse(inbox.finishResultImport(key, result: .success([ShellResourceID()])))
        XCTAssertTrue(inbox.beginResultDelivery(key))
        inbox.finishResultDelivery(key)
        XCTAssertEqual(work(inbox), [.finishAction(key)])
    }

    func testDataOnlyAttachmentsFailExplicitlyAndPreparationCannotAcceptAProviderReply() {
        let (inbox, identity) = fixture()
        let id = ShellServiceID(owner: identity.owner, request: 1)
        XCTAssertTrue(inbox.register(id, identity: identity))
        inbox.post(.result(id: "r1", ok: true, value: Data("null".utf8), attachments: Data("{}".utf8)), from: identity)
        XCTAssertEqual(
            inbox.takeBatch(now: 0).compactMap(\.control),
            [.result(id: id, outcome: .failure("unexpected_provider_files"))]
        )
        let pending = key(identity, 2)
        XCTAssertTrue(inbox.register(pending.id, identity: identity, operation: ShellResourceOperation()))
        XCTAssertEqual(
            inbox.post(.result(id: "r2", ok: true, value: Data("null".utf8), attachments: nil), from: identity),
            .ignored
        )
        XCTAssertFalse(inbox.isPending(pending.id, identity: identity))
    }

    func testUnsentEvidenceReportsOnlyWholeFramesAndPartialFrameRetainsItsOwner() throws {
        let (_, identity) = fixture()
        let first = ShellServiceID(owner: identity.owner, request: 1)
        let second = ShellServiceID(owner: identity.owner, request: 2)
        let actions = ShellProviderActions()
        actions.activate(identity)
        XCTAssertNil(actions.append(Data("first\n".utf8), id: first, identity: identity))
        XCTAssertTrue(actions.cancel(first, identity: identity))
        XCTAssertFalse(actions.cancel(first, identity: identity))
        XCTAssertNil(actions.append(Data("second\n".utf8), id: second, identity: identity))
        _ = actions.takeBatch()
        XCTAssertFalse(actions.cancel(second, identity: identity))
        var writer = ShellProviderWriteQueue()
        try writer.append(Data("first\n".utf8), id: first)
        try writer.append(Data("second\n".utf8), id: second)
        var calls = 0
        XCTAssertEqual(writer.drain { _ in calls += 1
            return calls == 1 ? .written(1) : .wouldBlock
        }, .blocked)
        var unsent: [ShellServiceID] = []
        XCTAssertEqual(writer.discardUnsent(where: { _ in true }, onDiscard: { unsent.append($0) }), 7)
        XCTAssertEqual(unsent, [second])
        XCTAssertEqual(writer.count, 1)
        XCTAssertFalse(writer.cancel(first))
    }

    private func fixture() -> (ShellProviderInbox, ShellProviderIdentity) {
        let inbox = ShellProviderInbox()
        let identity = ShellProviderIdentity(
            owner: ShellServiceOwner(generation: 1, owner: 1, epoch: 1),
            incarnation: 1
        )
        XCTAssertTrue(inbox.activate(identity))
        _ = inbox.takeBatch(now: 0)
        _ = inbox.finishBatch(now: 0)
        return (inbox, identity)
    }

    private func key(_ identity: ShellProviderIdentity, _ request: UInt64) -> ShellResourceLeaseKey {
        ShellResourceLeaseKey(
            id: ShellServiceID(owner: identity.owner, request: request),
            incarnation: identity.incarnation
        )
    }

    private func submitted(
        _ inbox: ShellProviderInbox,
        _ identity: ShellProviderIdentity,
        _ request: UInt64,
        operation: ShellResourceOperation = ShellResourceOperation()
    ) -> ShellResourceLeaseKey {
        let key = key(identity, request)
        XCTAssertTrue(inbox.register(key.id, identity: identity, operation: operation))
        XCTAssertTrue(inbox.actionPrepared(key, result: .success(Data("frame\n".utf8))))
        XCTAssertTrue(inbox.markSubmitted(key))
        return key
    }

    private func work(_ inbox: ShellProviderInbox) -> [ShellProviderInbox.Work] {
        inbox.takeBatch(now: 0).compactMap(\.work)
    }
}
