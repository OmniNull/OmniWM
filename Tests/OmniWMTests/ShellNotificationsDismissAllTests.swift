// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellNotificationsDismissAllTests: XCTestCase {
    @MainActor
    private final class Gate {
        var snapshot: ShellNotificationsData
        var entered: (Int) -> Void = { _ in }
        var actionEntered: () -> Void = {}
        var readEntered: (Int) -> Void = { _ in }
        var holdNextRead = false
        var storageRevision = Gate.revision(0)
        private(set) var readCount = 0
        private(set) var batches: [[ShellNotificationActionRequest]] = []
        private(set) var actions: [ShellNotificationActionRequest] = []
        private var progress: [Int: @MainActor @Sendable (ShellNotificationActionOutcome) -> Void] = [:]
        private var pending: [Int: CheckedContinuation<ShellNotificationActionOutcome, Never>] = [:]
        private var pendingAction: CheckedContinuation<ShellNotificationActionOutcome, Never>?
        private var pendingReads: [Int: CheckedContinuation<ShellNotificationsData, Never>] = [:]

        init(snapshot: ShellNotificationsData) {
            self.snapshot = snapshot
        }

        static func revision(_ stamp: Int64) -> ShellNotificationsController.StorageRevision {
            .init(database: .init(
                deviceID: 1, inode: 1, modificationTimeNanoseconds: stamp,
                statusChangeTimeNanoseconds: stamp, fileSize: 32
            ))
        }

        func read(_: URL) async -> ShellNotificationsData {
            let index = readCount
            readCount += 1
            if holdNextRead {
                holdNextRead = false
                return await withCheckedContinuation { continuation in
                    pendingReads[index] = continuation
                    readEntered(index)
                }
            }
            return snapshot
        }

        @discardableResult
        func finishRead(_ index: Int, with value: ShellNotificationsData) -> Bool {
            guard let continuation = pendingReads.removeValue(forKey: index) else { return false }
            continuation.resume(returning: value)
            return true
        }

        func dismissAll(
            _ requests: [ShellNotificationActionRequest],
            progress: @escaping @MainActor @Sendable (ShellNotificationActionOutcome) -> Void
        ) async -> ShellNotificationActionOutcome {
            let index = batches.count
            batches.append(requests)
            self.progress[index] = progress
            return await withCheckedContinuation { continuation in
                pending[index] = continuation
                entered(index)
            }
        }

        func perform(_ request: ShellNotificationActionRequest) async -> ShellNotificationActionOutcome {
            actions.append(request)
            return await withCheckedContinuation { continuation in
                pendingAction = continuation
                actionEntered()
            }
        }

        func emit(_ index: Int, _ outcome: ShellNotificationActionOutcome) {
            progress[index]?(outcome)
        }

        @discardableResult
        func finish(_ index: Int, _ outcome: ShellNotificationActionOutcome) -> Bool {
            guard let continuation = pending.removeValue(forKey: index) else { return false }
            progress.removeValue(forKey: index)
            continuation.resume(returning: outcome)
            return true
        }

        @discardableResult
        func finishAction(_ outcome: ShellNotificationActionOutcome) -> Bool {
            guard let continuation = pendingAction else { return false }
            pendingAction = nil
            continuation.resume(returning: outcome)
            return true
        }
    }

    private let firstBundle = "com.example.NotificationFixture"
    private let secondBundle = "com.example.OtherNotificationFixture"

    private func item(_ id: UUID, bundle: String? = nil, body: String = "Retained body") -> ShellServiceValue {
        .object([
            "id": .text(id.uuidString.lowercased()), "bundle": .text(bundle ?? firstBundle),
            "body": .text(body), "actions": .array([])
        ])
    }

    private func listen(_ controller: ShellNotificationsController, expected: ShellNotificationsData) async {
        let loaded = expectation(description: "notification snapshot loaded")
        var published = false
        controller.onChange = { value in
            if value == expected, !published {
                published = true
                loaded.fulfill()
            }
        }
        controller.setListening(true)
        await fulfillment(of: [loaded], timeout: 5)
        controller.onChange = nil
    }

    private func controller(_ gate: Gate) async -> ShellNotificationsController {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("uncreated/db")
        let controller = ShellNotificationsController(
            url: url,
            load: { await gate.read($0) },
            perform: { await gate.perform($0) },
            dismissAll: { await gate.dismissAll($0, progress: $1) },
            revision: { gate.storageRevision }
        )
        await listen(controller, expected: gate.snapshot)
        return controller
    }

    private func number(_ controller: ShellNotificationsController, _ key: String) -> Double? {
        controller.current.dismissAll?.fields?[key]?.number
    }

    private func state(_ controller: ShellNotificationsController) -> String? {
        controller.current.dismissAll?.fields?["state"]?.string
    }

    func testBatchCommandsAcceptOnlyTheirExactArgumentLists() {
        XCTAssertEqual(ShellAction("notifications dismiss-all"), .notifications(.dismissAll))
        XCTAssertEqual(ShellAction("notifications cancel-dismiss-all"), .notifications(.cancelDismissAll))
        for command in [
            "notifications dismiss-all extra", "notifications cancel-dismiss-all extra",
            "notifications dismiss-all \(firstBundle)", "notifications cancel-dismiss-all \(UUID().uuidString)"
        ] {
            XCTAssertNil(ShellAction(command), command)
        }
    }

    func testEmptyCompleteSnapshotFinishesWithoutStartingNativeBatch() async {
        let gate = Gate(snapshot: .init(state: "empty"))
        let controller = await controller(gate)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.perform(.dismissAll))
        XCTAssertEqual(state(controller), "completed")
        XCTAssertEqual(number(controller, "total"), 0)
        XCTAssertEqual(number(controller, "completed"), 0)
        XCTAssertEqual(number(controller, "failed"), 0)
        XCTAssertEqual(controller.current.dismissAll?.fields?["active"]?.boolean, false)
        XCTAssertEqual(controller.current.dismissAll?.fields?["outcome"]?.string, "dispatched")
        XCTAssertNil(controller.actionTask)
        XCTAssertFalse(controller.perform(.cancelDismissAll))
        XCTAssertTrue(gate.batches.isEmpty)
        XCTAssertTrue(gate.actions.isEmpty)
    }

    func testBatchFreezesAllAppsAndRowsWhileDatabaseRefreshRemainsAuthoritative() async throws {
        let first = UUID()
        let sibling = UUID()
        let other = UUID()
        let arrived = UUID()
        let initial = ShellNotificationsData(state: "ready", items: [
            item(first), item(other, bundle: secondBundle), item(sibling)
        ])
        let gate = Gate(snapshot: initial)
        let entered = expectation(description: "one native batch starts")
        gate.entered = { _ in entered.fulfill() }
        let controller = await controller(gate)
        defer { controller.setListening(false) }

        XCTAssertTrue(controller.perform(.dismissAll))
        let task = try XCTUnwrap(controller.actionTask)
        XCTAssertEqual(state(controller), "pending")
        XCTAssertEqual(number(controller, "total"), 3)
        XCTAssertEqual(controller.current.items, initial.items)
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(gate.batches, [[
            .init(bundle: firstBundle, id: first, peers: [first, sibling], operation: .dismiss),
            .init(bundle: secondBundle, id: other, peers: [other], operation: .dismiss),
            .init(bundle: firstBundle, id: sibling, peers: [first, sibling], operation: .dismiss)
        ]])
        XCTAssertTrue(gate.actions.isEmpty)

        gate.emit(0, .dispatched)
        let refreshed = ShellNotificationsData(state: "ready", items: [
            item(sibling, body: "Updated metadata"), item(other, bundle: secondBundle), item(arrived)
        ])
        gate.snapshot = refreshed
        let loaded = expectation(description: "database update retains batch progress")
        var published = false
        controller.onChange = { value in
            if value.items == refreshed.items, value.dismissAll?.fields?["completed"]?.number == 1, !published {
                published = true
                loaded.fulfill()
            }
        }
        controller.refresh()
        await fulfillment(of: [loaded], timeout: 5)
        controller.onChange = nil
        XCTAssertEqual(gate.batches.count, 1)
        XCTAssertFalse(gate.batches[0].contains { $0.id == arrived })
        gate.emit(0, .dispatched)
        gate.emit(0, .dispatched)
        XCTAssertTrue(gate.finish(0, .dispatched))
        await task.value
        XCTAssertEqual(state(controller), "completed")
        XCTAssertEqual(number(controller, "completed"), 3)
        XCTAssertEqual(number(controller, "failed"), 0)
        XCTAssertEqual(controller.current.items, refreshed.items)
        XCTAssertNil(controller.actionTask)
    }

    func testPartialFailureProgressAndOutcomeSurviveWireEncodingWithoutRemovingRows() async throws {
        let first = UUID()
        let second = UUID()
        let initial = ShellNotificationsData(state: "ready", items: [item(first), item(second)])
        let gate = Gate(snapshot: initial)
        let entered = expectation(description: "batch starts")
        gate.entered = { _ in entered.fulfill() }
        let controller = await controller(gate)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.perform(.dismissAll))
        let task = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [entered], timeout: 5)
        gate.emit(0, .dispatched)
        XCTAssertEqual(controller.current.dispatched, [first.uuidString.lowercased()])
        XCTAssertEqual(controller.current.items, initial.items)
        gate.emit(0, .notFound)
        XCTAssertEqual(number(controller, "completed"), 2)
        XCTAssertEqual(number(controller, "failed"), 1)
        XCTAssertTrue(gate.finish(0, .dispatched))
        await task.value

        XCTAssertEqual(state(controller), "partial")
        XCTAssertEqual(controller.current.dismissAll?.fields?["active"]?.boolean, false)
        XCTAssertEqual(controller.current.items, initial.items)
        var writer = ShellValueWriter()
        controller.current.write(into: &writer)
        let decoded = try ShellServiceValue.decode(writer.bytes)
        XCTAssertEqual(decoded.fields?["dismissAll"], controller.current.dismissAll)
        XCTAssertEqual(decoded.fields?["items"], .array(initial.items))
        XCTAssertEqual(decoded.fields?["dispatched"], .array([.text(first.uuidString.lowercased())]))
        XCTAssertEqual(decoded.fields?["kept"], .number(0))
        var empty = ShellValueWriter()
        ShellNotificationsData(state: "empty").write(into: &empty)
        XCTAssertEqual(try ShellServiceValue.decode(empty.bytes).fields?["dismissAll"], .null)
        XCTAssertEqual(try ShellServiceValue.decode(empty.bytes).fields?["dispatched"], .array([]))
        XCTAssertEqual(try ShellServiceValue.decode(empty.bytes).fields?["kept"], .number(0))
    }

    func testBatchAndIndividualActionsShareOneBusyGuard() async throws {
        let id = UUID()
        let gate = Gate(snapshot: .init(state: "ready", items: [item(id)]))
        let entered = expectation(description: "batch starts")
        gate.entered = { _ in entered.fulfill() }
        let controller = await controller(gate)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.perform(.dismissAll))
        let batchTask = try XCTUnwrap(controller.actionTask)
        XCTAssertFalse(controller.perform(.dismissAll))
        XCTAssertFalse(controller.perform(.dismiss(bundle: firstBundle, id: id)))
        XCTAssertFalse(controller.perform(.reply(bundle: firstBundle, id: id, text: "Reply")))
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(gate.batches.count, 1)
        XCTAssertTrue(gate.actions.isEmpty)
        gate.emit(0, .dispatched)
        XCTAssertTrue(gate.finish(0, .dispatched))
        await batchTask.value
        await controller.task?.value

        let actionEntered = expectation(description: "individual action starts")
        gate.actionEntered = { actionEntered.fulfill() }
        let arrived = UUID()
        gate.snapshot = .init(state: "ready", items: [item(id), item(arrived)])
        controller.refresh()
        await controller.task?.value
        XCTAssertTrue(controller.perform(.dismiss(bundle: firstBundle, id: arrived)))
        let actionTask = try XCTUnwrap(controller.actionTask)
        XCTAssertFalse(controller.perform(.dismissAll))
        XCTAssertFalse(controller.perform(.cancelDismissAll))
        await fulfillment(of: [actionEntered], timeout: 5)
        XCTAssertEqual(gate.batches.count, 1)
        XCTAssertEqual(gate.actions.count, 1)
        XCTAssertTrue(gate.finishAction(.dispatched))
        await actionTask.value
    }

    func testNativeFailureRetainsRowsAndPublishesItsFailureOutcome() async throws {
        let initial = ShellNotificationsData(state: "ready", items: [item(UUID())])
        let gate = Gate(snapshot: initial)
        let entered = expectation(description: "batch starts")
        gate.entered = { _ in entered.fulfill() }
        let controller = await controller(gate)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.perform(.dismissAll))
        let task = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(gate.finish(0, .denied))
        await task.value
        XCTAssertEqual(state(controller), "failed")
        XCTAssertEqual(controller.current.dismissAll?.fields?["outcome"]?.string, "denied")
        XCTAssertEqual(controller.current.dismissAll?.fields?["active"]?.boolean, false)
        XCTAssertEqual(number(controller, "completed"), 0)
        XCTAssertEqual(controller.current.items, initial.items)
        XCTAssertNil(controller.actionTask)
    }

    func testPanelCleanupFeedbackPreservesCompletedAndPartialItemResults() async throws {
        for hasFailedItem in [false, true] {
            let initial = ShellNotificationsData(state: "ready", items: [item(UUID()), item(UUID())])
            let gate = Gate(snapshot: initial)
            let entered = expectation(description: "batch starts before panel cleanup feedback")
            gate.entered = { _ in entered.fulfill() }
            let controller = await controller(gate)
            XCTAssertTrue(controller.perform(.dismissAll))
            let task = try XCTUnwrap(controller.actionTask)
            await fulfillment(of: [entered], timeout: 5)
            gate.emit(0, .dispatched)
            gate.emit(0, hasFailedItem ? .notFound : .dispatched)
            XCTAssertTrue(gate.finish(0, .dispatchedPanelOpen))
            await task.value
            XCTAssertEqual(state(controller), hasFailedItem ? "partial" : "completed")
            XCTAssertEqual(number(controller, "total"), 2)
            XCTAssertEqual(number(controller, "completed"), 2)
            XCTAssertEqual(number(controller, "failed"), hasFailedItem ? 1 : 0)
            XCTAssertEqual(controller.current.dismissAll?.fields?["outcome"]?.string, "dispatchedPanelOpen")
            XCTAssertEqual(controller.current.dismissAll?.fields?["active"]?.boolean, false)
            XCTAssertEqual(controller.current.items, initial.items)
            XCTAssertNil(controller.actionTask)
            controller.setListening(false)
        }
    }

    func testCancellationPreservesItsStateWhenPanelCleanupAlsoFails() async throws {
        let initial = ShellNotificationsData(state: "ready", items: [item(UUID()), item(UUID())])
        let gate = Gate(snapshot: initial)
        let entered = expectation(description: "batch starts before cancellation cleanup")
        gate.entered = { _ in entered.fulfill() }
        let controller = await controller(gate)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.perform(.dismissAll))
        let task = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [entered], timeout: 5)
        gate.emit(0, .dispatched)
        XCTAssertTrue(controller.perform(.cancelDismissAll))
        XCTAssertEqual(state(controller), "cancelling")
        XCTAssertTrue(gate.finish(0, .failedPanelOpen))
        await task.value
        XCTAssertEqual(state(controller), "cancelled")
        XCTAssertEqual(number(controller, "total"), 2)
        XCTAssertEqual(number(controller, "completed"), 1)
        XCTAssertEqual(number(controller, "failed"), 0)
        XCTAssertEqual(controller.current.dismissAll?.fields?["outcome"]?.string, "failedPanelOpen")
        XCTAssertEqual(controller.current.dismissAll?.fields?["active"]?.boolean, false)
        XCTAssertEqual(controller.current.items, initial.items)
        XCTAssertNil(controller.actionTask)
    }

    func testCancellingFromPendingPublicationPreventsNativeEffects() async throws {
        let gate = Gate(snapshot: .init(state: "ready", items: [item(UUID())]))
        let controller = await controller(gate)
        defer { controller.setListening(false) }
        var pendingTask: Task<Void, Never>?
        controller.onChange = { [weak controller] value in
            guard value.dismissAll?.fields?["state"]?.string == "pending", let controller else { return }
            pendingTask = controller.actionTask
            XCTAssertTrue(controller.perform(.cancelDismissAll))
            XCTAssertEqual(self.state(controller), "cancelling")
            XCTAssertNotNil(controller.actionTask)
            XCTAssertFalse(controller.perform(.dismissAll))
        }
        XCTAssertTrue(controller.perform(.dismissAll))
        let task = try XCTUnwrap(pendingTask)
        await task.value
        XCTAssertEqual(state(controller), "cancelled")
        XCTAssertNil(controller.actionTask)
        XCTAssertTrue(gate.batches.isEmpty)
        XCTAssertTrue(gate.actions.isEmpty)
        controller.onChange = nil
    }

    func testCancellationKeepsTheBatchBusyUntilNativeCleanupCompletes() async throws {
        let id = UUID()
        let gate = Gate(snapshot: .init(state: "ready", items: [item(id)]))
        let entered = expectation(description: "batch starts")
        gate.entered = { _ in entered.fulfill() }
        let controller = await controller(gate)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.perform(.dismissAll))
        let task = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(controller.perform(.cancelDismissAll))
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(state(controller), "cancelling")
        XCTAssertNotNil(controller.actionTask)
        XCTAssertFalse(controller.perform(.dismissAll))
        XCTAssertFalse(controller.perform(.dismiss(bundle: firstBundle, id: id)))
        XCTAssertEqual(controller.current.items, gate.snapshot.items)
        XCTAssertTrue(gate.finish(0, .cancelled))
        await task.value
        XCTAssertEqual(state(controller), "cancelled")
        XCTAssertEqual(controller.current.dismissAll?.fields?["active"]?.boolean, false)
        XCTAssertNil(controller.actionTask)
        XCTAssertFalse(controller.perform(.cancelDismissAll))
    }

    func testFinishedBatchSurvivesReadsUntilDatabaseConfirmsItsDispatchedRowsAreGone() async throws {
        let id = UUID()
        let initial = ShellNotificationsData(state: "ready", items: [item(id)])
        let gate = Gate(snapshot: initial)
        let entered = expectation(description: "batch starts")
        gate.entered = { _ in entered.fulfill() }
        let controller = await controller(gate)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.perform(.dismissAll))
        let task = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [entered], timeout: 5)
        gate.emit(0, .dispatched)
        XCTAssertTrue(gate.finish(0, .dispatched))
        await task.value
        await controller.task?.value
        let finished = controller.current.dismissAll
        XCTAssertEqual(state(controller), "completed")
        XCTAssertEqual(controller.current.dispatched, [id.uuidString.lowercased()])

        controller.refresh()
        await controller.task?.value
        XCTAssertEqual(controller.current.dismissAll, finished)
        XCTAssertEqual(controller.current.items, initial.items)
        XCTAssertEqual(controller.current.dispatched, [id.uuidString.lowercased()])
        XCTAssertEqual(controller.current.kept, 0)

        gate.snapshot = .init(state: "empty")
        gate.storageRevision = Gate.revision(1)
        controller.refresh(.filesystem)
        await controller.task?.value
        XCTAssertEqual(controller.current.items, [])
        XCTAssertEqual(controller.current.dispatched, [])
        XCTAssertNil(controller.current.dismissAll)
        XCTAssertEqual(controller.current.kept, 0)
    }

    func testMetadataOnlyIncompletenessStillConfirmsDispatchedMembersAreGone() async throws {
        let id = UUID()
        let gate = Gate(snapshot: .init(state: "ready", items: [item(id)]))
        let entered = expectation(description: "batch starts")
        gate.entered = { _ in entered.fulfill() }
        let controller = await controller(gate)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.perform(.dismissAll))
        let task = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [entered], timeout: 5)
        gate.emit(0, .dispatched)
        XCTAssertTrue(gate.finish(0, .dispatched))
        await task.value
        await controller.task?.value
        XCTAssertEqual(controller.current.dispatched, [id.uuidString.lowercased()])

        gate.snapshot = .init(
            state: "incomplete", complete: false, membershipComplete: true, metadataComplete: false,
            issues: [.init(scope: .metadata, reason: .encodingLimit)]
        )
        gate.storageRevision = Gate.revision(1)
        controller.refresh(.filesystem)
        await controller.task?.value
        XCTAssertFalse(controller.current.complete)
        XCTAssertTrue(controller.current.membershipComplete)
        XCTAssertTrue(controller.current.dispatched.isEmpty)
        XCTAssertNil(controller.current.dismissAll)
    }

    func testCompleteEmptyReadClearsZeroSuccessFailedAndCancelledBatchResults() async throws {
        for outcome in [ShellNotificationActionOutcome.denied, .cancelled] {
            let initial = ShellNotificationsData(state: "ready", items: [item(UUID())])
            let gate = Gate(snapshot: initial)
            let entered = expectation(description: "zero-success batch starts")
            gate.entered = { _ in entered.fulfill() }
            let controller = await controller(gate)
            XCTAssertTrue(controller.perform(.dismissAll))
            let task = try XCTUnwrap(controller.actionTask)
            await fulfillment(of: [entered], timeout: 5)
            if outcome == .cancelled { XCTAssertTrue(controller.perform(.cancelDismissAll)) }
            XCTAssertTrue(gate.finish(0, outcome))
            await task.value
            await controller.task?.value
            XCTAssertEqual(state(controller), outcome == .cancelled ? "cancelled" : "failed")
            XCTAssertEqual(number(controller, "completed"), 0)
            XCTAssertEqual(controller.current.dispatched, [])
            XCTAssertEqual(controller.current.items, initial.items)
            let terminal = controller.current.dismissAll

            gate.snapshot = .init(state: "incomplete", complete: false)
            controller.refresh(.filesystem)
            await controller.task?.value
            XCTAssertEqual(controller.current.dismissAll, terminal)
            XCTAssertEqual(controller.current.items, [])
            XCTAssertEqual(controller.current.kept, 0)

            gate.snapshot = .init(state: "empty")
            controller.refresh()
            await controller.task?.value
            XCTAssertNil(controller.current.dismissAll)
            XCTAssertEqual(controller.current.items, [])
            XCTAssertEqual(controller.current.dispatched, [])
            XCTAssertEqual(controller.current.kept, 0)
            XCTAssertEqual(gate.batches.count, 1)
            controller.setListening(false)
        }
    }

    func testCompleteEmptyReadPreservesActiveBatchAndKeptUntilNativeCleanup() async throws {
        let first = UUID()
        let initial = ShellNotificationsData(state: "ready", items: [item(first), item(UUID())])
        let gate = Gate(snapshot: initial)
        let entered = expectation(description: "batch starts before database becomes empty")
        gate.entered = { _ in entered.fulfill() }
        let controller = await controller(gate)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.perform(.dismissAll))
        let task = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [entered], timeout: 5)
        gate.emit(0, .dispatched)
        gate.storageRevision = Gate.revision(1)
        controller.refresh(.filesystem)
        await controller.task?.value
        XCTAssertEqual(controller.current.items, initial.items)
        XCTAssertEqual(controller.current.dispatched, [])
        XCTAssertEqual(controller.current.kept, 1)
        XCTAssertEqual(state(controller), "pending")

        gate.snapshot = .init(state: "empty")
        controller.refresh()
        await controller.task?.value
        XCTAssertEqual(controller.current.items, [])
        XCTAssertEqual(state(controller), "pending")
        XCTAssertEqual(number(controller, "completed"), 1)
        XCTAssertEqual(controller.current.dismissAll?.fields?["active"]?.boolean, true)
        XCTAssertEqual(controller.current.kept, 1)
        XCTAssertNotNil(controller.actionTask)

        XCTAssertTrue(controller.perform(.cancelDismissAll))
        controller.refresh()
        await controller.task?.value
        XCTAssertEqual(state(controller), "cancelling")
        XCTAssertEqual(controller.current.kept, 1)
        XCTAssertNotNil(controller.actionTask)
        XCTAssertTrue(gate.finish(0, .cancelled))
        await task.value
        await controller.task?.value
        XCTAssertNil(controller.current.dismissAll)
        XCTAssertEqual(controller.current.kept, 0)
        XCTAssertEqual(controller.current.items, [])
        XCTAssertNil(controller.actionTask)
    }

    func testNextClearAllExcludesDispatchedRowsAndReplacesThePreviousResult() async throws {
        let first = UUID()
        let second = UUID()
        let initial = ShellNotificationsData(state: "ready", items: [item(first), item(second)])
        let gate = Gate(snapshot: initial)
        let firstEntered = expectation(description: "first batch starts")
        let secondEntered = expectation(description: "remaining-row batch starts")
        gate.entered = { index in
            if index == 0 { firstEntered.fulfill() }
            else if index == 1 { secondEntered.fulfill() }
            else { XCTFail("Unexpected extra batch") }
        }
        let controller = await controller(gate)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.perform(.dismissAll))
        let firstTask = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [firstEntered], timeout: 5)
        gate.emit(0, .dispatched)
        gate.emit(0, .notFound)
        XCTAssertTrue(gate.finish(0, .dispatched))
        await firstTask.value
        await controller.task?.value
        XCTAssertEqual(state(controller), "partial")
        XCTAssertEqual(controller.current.dispatched, [first.uuidString.lowercased()])

        XCTAssertTrue(controller.perform(.dismissAll))
        let secondTask = try XCTUnwrap(controller.actionTask)
        XCTAssertEqual(state(controller), "pending")
        XCTAssertEqual(number(controller, "total"), 1)
        XCTAssertEqual(number(controller, "completed"), 0)
        XCTAssertEqual(number(controller, "failed"), 0)
        await fulfillment(of: [secondEntered], timeout: 5)
        XCTAssertEqual(gate.batches[1].map(\.id), [second])
        gate.emit(1, .dispatchedPanelOpen)
        XCTAssertTrue(gate.finish(1, .dispatchedPanelOpen))
        await secondTask.value
        await controller.task?.value
        XCTAssertEqual(state(controller), "completed")
        XCTAssertEqual(number(controller, "failed"), 0)
        XCTAssertEqual(Set(controller.current.dispatched), Set([first, second].map { $0.uuidString.lowercased() }))
        XCTAssertEqual(controller.current.items, initial.items)
        _ = controller.perform(.dismissAll)
        XCTAssertNil(controller.actionTask)
        XCTAssertEqual(gate.batches.count, 2)
        XCTAssertEqual(controller.current.items, initial.items)
    }

    func testCancelledBatchHidesOnlySuccessfulDispatchesAndRetriesTheRemainingRows() async throws {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let initial = ShellNotificationsData(state: "ready", items: [item(first), item(second), item(third)])
        let gate = Gate(snapshot: initial)
        let firstEntered = expectation(description: "first batch starts")
        let secondEntered = expectation(description: "retry batch starts")
        gate.entered = { index in
            if index == 0 { firstEntered.fulfill() }
            else if index == 1 { secondEntered.fulfill() }
            else { XCTFail("Unexpected extra batch") }
        }
        let controller = await controller(gate)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.perform(.dismissAll))
        let firstTask = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [firstEntered], timeout: 5)
        gate.emit(0, .dispatched)
        gate.emit(0, .notFound)
        XCTAssertTrue(controller.perform(.cancelDismissAll))
        XCTAssertTrue(gate.finish(0, .cancelled))
        await firstTask.value
        await controller.task?.value
        XCTAssertEqual(state(controller), "cancelled")
        XCTAssertEqual(number(controller, "completed"), 2)
        XCTAssertEqual(number(controller, "failed"), 1)
        XCTAssertEqual(controller.current.dispatched, [first.uuidString.lowercased()])
        XCTAssertEqual(controller.current.items, initial.items)

        XCTAssertTrue(controller.perform(.dismissAll))
        let secondTask = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [secondEntered], timeout: 5)
        XCTAssertEqual(gate.batches[1].map(\.id), [second, third])
        XCTAssertTrue(controller.perform(.cancelDismissAll))
        XCTAssertTrue(gate.finish(1, .cancelled))
        await secondTask.value
        XCTAssertEqual(controller.current.dispatched, [first.uuidString.lowercased()])
        XCTAssertEqual(controller.current.items, initial.items)
    }

    func testRetainedRowsReappearOnlyAfterAChangedStablePostDispatchFilesystemRead() async throws {
        let id = UUID()
        let initial = ShellNotificationsData(state: "ready", items: [item(id)])
        let gate = Gate(snapshot: initial)
        let entered = expectation(description: "batch starts")
        gate.entered = { _ in entered.fulfill() }
        let controller = await controller(gate)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.perform(.dismissAll))
        let task = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [entered], timeout: 5)
        gate.emit(0, .dispatched)
        XCTAssertTrue(gate.finish(0, .dispatched))
        await task.value
        await controller.task?.value

        controller.refresh(.filesystem)
        await controller.task?.value
        XCTAssertEqual(controller.current.dispatched, [id.uuidString.lowercased()])
        gate.storageRevision = .init(database: gate.storageRevision.database, wal: Gate.revision(1).database)
        controller.refresh()
        await controller.task?.value
        XCTAssertEqual(controller.current.dispatched, [id.uuidString.lowercased()])
        controller.refresh(.action)
        await controller.task?.value
        XCTAssertEqual(controller.current.dispatched, [id.uuidString.lowercased()])
        XCTAssertEqual(controller.current.kept, 0)

        controller.refresh(.filesystem)
        await controller.task?.value
        XCTAssertEqual(controller.current.items, initial.items)
        XCTAssertEqual(controller.current.dispatched, [])
        XCTAssertEqual(controller.current.kept, 1)
        XCTAssertNil(controller.current.dismissAll)
        controller.refresh()
        await controller.task?.value
        XCTAssertEqual(controller.current.kept, 1)

        let actionEntered = expectation(description: "restored row can be dismissed again")
        gate.actionEntered = { actionEntered.fulfill() }
        XCTAssertTrue(controller.perform(.dismiss(bundle: firstBundle, id: id)))
        let actionTask = try XCTUnwrap(controller.actionTask)
        XCTAssertEqual(controller.current.kept, 0)
        await fulfillment(of: [actionEntered], timeout: 5)
        XCTAssertTrue(gate.finishAction(.dispatched))
        await actionTask.value
        XCTAssertEqual(controller.current.dispatched, [id.uuidString.lowercased()])
        XCTAssertEqual(controller.current.items, initial.items)
    }

    func testIncompleteAndUnstableFilesystemReadsCannotRestoreDispatchedRows() async throws {
        let id = UUID()
        let initial = ShellNotificationsData(state: "ready", items: [item(id)])
        let gate = Gate(snapshot: initial)
        let entered = expectation(description: "batch starts")
        gate.entered = { _ in entered.fulfill() }
        let controller = await controller(gate)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.perform(.dismissAll))
        let task = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [entered], timeout: 5)
        gate.emit(0, .dispatched)
        XCTAssertTrue(gate.finish(0, .dispatched))
        await task.value
        await controller.task?.value

        gate.storageRevision = Gate.revision(1)
        gate.snapshot = .init(state: "incomplete", items: initial.items, complete: false)
        controller.refresh(.filesystem)
        await controller.task?.value
        XCTAssertEqual(controller.current.dispatched, [id.uuidString.lowercased()])
        XCTAssertEqual(controller.current.kept, 0)
        XCTAssertEqual(controller.current.items, initial.items)

        let readEntered = expectation(description: "filesystem read remains in flight")
        let index = gate.readCount
        gate.holdNextRead = true
        gate.readEntered = { _ in readEntered.fulfill() }
        controller.refresh(.filesystem)
        let readTask = try XCTUnwrap(controller.task)
        await fulfillment(of: [readEntered], timeout: 5)
        gate.storageRevision = Gate.revision(2)
        XCTAssertTrue(gate.finishRead(index, with: initial))
        await readTask.value
        XCTAssertEqual(controller.current.dispatched, [id.uuidString.lowercased()])
        XCTAssertEqual(controller.current.kept, 0)

        gate.snapshot = initial
        controller.refresh(.filesystem)
        await controller.task?.value
        XCTAssertEqual(controller.current.dispatched, [])
        XCTAssertEqual(controller.current.kept, 1)
        XCTAssertEqual(controller.current.items, initial.items)
        XCTAssertNil(controller.current.dismissAll)

        gate.snapshot = .init(state: "incomplete", complete: false)
        controller.refresh(.filesystem)
        await controller.task?.value
        XCTAssertEqual(controller.current.items, [])
        XCTAssertEqual(controller.current.kept, 1)
        gate.snapshot = .init(state: "empty")
        controller.refresh()
        await controller.task?.value
        XCTAssertEqual(controller.current.items, [])
        XCTAssertEqual(controller.current.kept, 0)
        XCTAssertNil(controller.current.dismissAll)
    }

    func testInflightManualReadCannotBorrowALaterFilesystemEvent() async throws {
        let id = UUID()
        let initial = ShellNotificationsData(state: "ready", items: [item(id)])
        let gate = Gate(snapshot: initial)
        let entered = expectation(description: "batch starts")
        gate.entered = { _ in entered.fulfill() }
        let controller = await controller(gate)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.perform(.dismissAll))
        let task = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [entered], timeout: 5)
        gate.emit(0, .dispatched)
        XCTAssertTrue(gate.finish(0, .dispatched))
        await task.value
        await controller.task?.value

        gate.storageRevision = Gate.revision(1)
        let firstReadEntered = expectation(description: "manual read starts")
        let coalescedReadEntered = expectation(description: "post-event read starts")
        let index = gate.readCount
        gate.holdNextRead = true
        gate.readEntered = { read in
            if read == index { firstReadEntered.fulfill() }
            else if read == index + 1 { coalescedReadEntered.fulfill() }
            else { XCTFail("Unexpected held read") }
        }
        controller.refresh()
        let firstReadTask = try XCTUnwrap(controller.task)
        await fulfillment(of: [firstReadEntered], timeout: 5)
        controller.refresh(.filesystem)
        gate.holdNextRead = true
        XCTAssertTrue(gate.finishRead(index, with: initial))
        await firstReadTask.value
        await fulfillment(of: [coalescedReadEntered], timeout: 5)
        XCTAssertEqual(controller.current.dispatched, [id.uuidString.lowercased()])
        XCTAssertEqual(controller.current.kept, 0)
        let coalescedReadTask = try XCTUnwrap(controller.task)
        XCTAssertTrue(gate.finishRead(index + 1, with: initial))
        await coalescedReadTask.value
        XCTAssertEqual(controller.current.dispatched, [])
        XCTAssertEqual(controller.current.kept, 1)
        XCTAssertNil(controller.current.dismissAll)
        XCTAssertEqual(controller.current.items, initial.items)
    }

    func testReadAndFilesystemEventBeforeDispatchCannotRestoreTheDispatchedRow() async throws {
        let id = UUID()
        let initial = ShellNotificationsData(state: "ready", items: [item(id)])
        let gate = Gate(snapshot: initial)
        let readEntered = expectation(description: "read starts before dispatch")
        let actionEntered = expectation(description: "batch starts while old read remains in flight")
        let controller = await controller(gate)
        defer { controller.setListening(false) }
        gate.storageRevision = Gate.revision(1)
        let index = gate.readCount
        gate.holdNextRead = true
        gate.readEntered = { _ in readEntered.fulfill() }
        controller.refresh(.filesystem)
        let readTask = try XCTUnwrap(controller.task)
        await fulfillment(of: [readEntered], timeout: 5)
        gate.entered = { _ in actionEntered.fulfill() }
        XCTAssertTrue(controller.perform(.dismissAll))
        let actionTask = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [actionEntered], timeout: 5)
        gate.emit(0, .dispatched)
        XCTAssertTrue(gate.finish(0, .dispatched))
        await actionTask.value
        gate.storageRevision = Gate.revision(2)
        XCTAssertTrue(gate.finishRead(index, with: initial))
        await readTask.value
        await controller.task?.value
        XCTAssertEqual(controller.current.dispatched, [id.uuidString.lowercased()])
        XCTAssertEqual(controller.current.kept, 0)
        XCTAssertEqual(controller.current.items, initial.items)
        XCTAssertEqual(state(controller), "completed")
    }

    func testHistoryClosingMidBatchPreservesSuccessfulDispatchesAndReportsItsOutcome() async throws {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let initial = ShellNotificationsData(state: "ready", items: [item(first), item(second), item(third)])
        let gate = Gate(snapshot: initial)
        let entered = expectation(description: "batch starts before history closes")
        gate.entered = { _ in entered.fulfill() }
        let controller = await controller(gate)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.perform(.dismissAll))
        let task = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [entered], timeout: 5)
        gate.emit(0, .dispatched)
        gate.emit(0, .historyClosed)
        XCTAssertTrue(gate.finish(0, .historyClosed))
        await task.value
        await controller.task?.value
        XCTAssertEqual(state(controller), "failed")
        XCTAssertEqual(number(controller, "total"), 3)
        XCTAssertEqual(number(controller, "completed"), 2)
        XCTAssertEqual(number(controller, "failed"), 1)
        XCTAssertEqual(controller.current.dismissAll?.fields?["outcome"]?.string, "historyClosed")
        XCTAssertEqual(controller.current.dismissAll?.fields?["active"]?.boolean, false)
        XCTAssertEqual(controller.current.dispatched, [first.uuidString.lowercased()])
        XCTAssertEqual(controller.current.kept, 0)
        XCTAssertEqual(controller.current.items, initial.items)
    }

    func testIncompleteAndAmbiguousSnapshotsNeverReachNativeBatch() async {
        let id = UUID()
        let snapshots: [ShellNotificationsData] = [
            .init(state: "incomplete", items: [item(id)], complete: false),
            .init(state: "loading", items: [item(id)]),
            .init(state: "ready", items: [item(id), item(id)]),
            .init(state: "ready", items: [item(id), item(id, bundle: secondBundle)]),
            .init(state: "ready", items: [.object(["id": .text("not-a-guid"), "bundle": .text(firstBundle)])]),
            .init(state: "ready", items: [.object(["id": .text(id.uuidString), "bundle": .text("file:///tmp/App")])])
        ]
        for snapshot in snapshots {
            let gate = Gate(snapshot: snapshot)
            let controller = await controller(gate)
            XCTAssertFalse(controller.perform(.dismissAll))
            XCTAssertEqual(state(controller), "failed")
            XCTAssertNil(controller.actionTask)
            XCTAssertEqual(controller.current.items, snapshot.items)
            XCTAssertTrue(gate.batches.isEmpty)
            XCTAssertTrue(gate.actions.isEmpty)
            controller.setListening(false)
        }
    }

    func testStoppedBatchProgressAndCompletionCannotReplaceRestartedBatch() async throws {
        let oldID = UUID()
        let newID = UUID()
        let gate = Gate(snapshot: .init(state: "ready", items: [item(oldID)]))
        let oldEntered = expectation(description: "old batch starts")
        let newEntered = expectation(description: "new batch starts")
        gate.entered = { index in
            if index == 0 { oldEntered.fulfill() }
            else if index == 1 { newEntered.fulfill() }
            else { XCTFail("Unexpected additional batch") }
        }
        let controller = await controller(gate)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.perform(.dismissAll))
        let oldTask = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [oldEntered], timeout: 5)
        controller.setListening(false)
        XCTAssertFalse(controller.perform(.dismissAll))
        gate.snapshot = .init(state: "ready", items: [item(newID)])
        await listen(controller, expected: gate.snapshot)
        XCTAssertTrue(controller.perform(.dismissAll))
        let newTask = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [newEntered], timeout: 5)

        gate.emit(0, .failed)
        XCTAssertEqual(number(controller, "completed"), 0)
        XCTAssertEqual(number(controller, "failed"), 0)
        XCTAssertTrue(gate.finish(0, .dispatched))
        await oldTask.value
        XCTAssertEqual(state(controller), "pending")
        XCTAssertEqual(controller.current.items, gate.snapshot.items)
        XCTAssertNotNil(controller.actionTask)
        gate.emit(1, .dispatched)
        XCTAssertTrue(gate.finish(1, .dispatched))
        await newTask.value
        XCTAssertEqual(state(controller), "completed")
        XCTAssertEqual(number(controller, "completed"), 1)
        XCTAssertNil(controller.actionTask)
    }
}
