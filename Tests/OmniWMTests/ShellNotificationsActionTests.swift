// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellNotificationsActionTests: XCTestCase {
    private actor Gate {
        var snapshot: ShellNotificationsData
        let entered: @Sendable (Int) -> Void
        private(set) var requests: [ShellNotificationActionRequest] = []
        private(set) var batches: [[ShellNotificationActionRequest]] = []
        private var pending: [Int: CheckedContinuation<ShellNotificationActionOutcome, Never>] = [:]

        init(snapshot: ShellNotificationsData, entered: @escaping @Sendable (Int) -> Void = { _ in }) {
            self.snapshot = snapshot
            self.entered = entered
        }

        func read(_: URL) -> ShellNotificationsData {
            snapshot
        }

        func setSnapshot(_ snapshot: ShellNotificationsData) {
            self.snapshot = snapshot
        }

        func perform(_ request: ShellNotificationActionRequest) async -> ShellNotificationActionOutcome {
            let index = requests.count
            requests.append(request)
            return await withCheckedContinuation { continuation in
                pending[index] = continuation
                entered(index)
            }
        }

        func batch(_ requests: [ShellNotificationActionRequest]) -> ShellNotificationActionOutcome {
            batches.append(requests)
            return .failed
        }

        func finish(_ index: Int, with outcome: ShellNotificationActionOutcome) -> Bool {
            guard let continuation = pending.removeValue(forKey: index) else { return false }
            continuation.resume(returning: outcome)
            return true
        }
    }

    private let bundle = "com.example.NotificationFixture"

    private func item(
        _ id: UUID,
        actions: [ShellServiceValue] = [],
        body: String = "Retained body"
    ) -> ShellServiceValue {
        .object([
            "id": .text(id.uuidString.lowercased()), "bundle": .text(bundle),
            "body": .text(body), "actions": .array(actions)
        ])
    }

    private func listen(_ controller: ShellNotificationsController, expected: ShellNotificationsData) async {
        let ready = expectation(description: "notification snapshot loaded")
        var published = false
        controller.onChange = { value in
            if value == expected, !published {
                published = true
                ready.fulfill()
            }
        }
        controller.setListening(true)
        await fulfillment(of: [ready], timeout: failureBound)
        controller.onChange = nil
    }

    private func controller(_ gate: Gate, expected: ShellNotificationsData) async -> ShellNotificationsController {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("uncreated/db")
        let controller = ShellNotificationsController(
            url: url, load: { await gate.read($0) }, perform: { await gate.perform($0) },
            dismissAll: { requests, _ in await gate.batch(requests) }
        )
        await listen(controller, expected: expected)
        return controller
    }

    private func hex(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }

    func testActionCommandsPreserveUnicodeAndRejectMalformedTargetsAndPayloads() {
        let id = UUID()
        let text = "  Exact reply ✓ 中文 العربية 👩🏽‍💻 e\u{301}\nSecond line  "
        XCTAssertEqual(
            ShellAction("notifications reply \(bundle) \(id.uuidString) \(hex(text))"),
            .notifications(.reply(bundle: bundle, id: id, text: text))
        )
        XCTAssertEqual(
            ShellAction("notifications dismiss \(bundle) \(id.uuidString.lowercased())"),
            .notifications(.dismiss(bundle: bundle, id: id))
        )
        for invalid in [
            "notifications dismiss \(bundle) not-a-guid",
            "notifications dismiss \(bundle) {\(id.uuidString)}",
            "notifications dismiss \(bundle) \(id.uuidString) extra",
            "notifications dismiss file:///tmp/App \(id.uuidString)",
            "notifications dismiss \(String(repeating: "a", count: 256)) \(id.uuidString)",
            "notifications reply \(bundle) \(id.uuidString)",
            "notifications reply \(bundle) \(id.uuidString) 0",
            "notifications reply \(bundle) \(id.uuidString) gg",
            "notifications reply \(bundle) \(id.uuidString) ff",
            "notifications reply \(bundle) \(id.uuidString) 00",
            "notifications reply \(bundle) \(id.uuidString) 20",
            "notifications reply \(bundle) \(id.uuidString) \(hex("a")) extra",
            "notifications reply \(bundle) \(id.uuidString) \(hex(String(repeating: "a", count: 4097)))"
        ] {
            XCTAssertNil(ShellAction(invalid), invalid)
        }
        let maximum = String(repeating: "a", count: 4096)
        XCTAssertEqual(
            ShellAction("notifications reply \(bundle) \(id.uuidString) \(hex(maximum))"),
            .notifications(.reply(bundle: bundle, id: id, text: maximum))
        )
    }

    func testActionStatusSurvivesWireEncodingWithoutChangingRetainedItems() throws {
        let id = UUID()
        let retained = item(id)
        let status: ShellServiceValue = .object([
            "id": .text(id.uuidString.lowercased()), "bundle": .text(bundle),
            "kind": .text("reply"), "state": .text("dispatchedPanelOpen")
        ])
        let snapshot = ShellNotificationsData(state: "ready", items: [retained], action: status)
        var writer = ShellValueWriter()
        snapshot.write(into: &writer)
        let decoded = try ShellServiceValue.decode(writer.bytes)
        XCTAssertEqual(decoded.fields?["action"], status)
        var expected = try XCTUnwrap(retained.fields)
        expected["actionsSupported"] = .bool(ShellNotificationsCommand.validBundle(bundle))
        XCTAssertEqual(decoded.fields?["items"], .array([.object(expected)]))
        var emptyWriter = ShellValueWriter()
        ShellNotificationsData(state: "empty").write(into: &emptyWriter)
        XCTAssertEqual(try ShellServiceValue.decode(emptyWriter.bytes).fields?["action"], .null)
    }

    func testDismissKeepsDatabaseMembershipSerializesActionsAndPreservesStatusAcrossReads() async throws {
        let id = UUID()
        let sibling = UUID()
        let initial = ShellNotificationsData(state: "ready", items: [item(id), item(sibling)])
        let entered = expectation(description: "one action begins")
        let gate = Gate(snapshot: initial, entered: { _ in entered.fulfill() })
        let controller = await controller(gate, expected: initial)
        defer { controller.setListening(false) }

        XCTAssertTrue(controller.perform(.dismiss(bundle: bundle, id: id)))
        let task = try XCTUnwrap(controller.actionTask)
        XCTAssertEqual(controller.current.items, initial.items)
        XCTAssertEqual(controller.current.action?.fields?["state"]?.string, "pending")
        XCTAssertFalse(controller.perform(.dismiss(bundle: bundle, id: sibling)))
        XCTAssertEqual(controller.current.action?.fields?["id"]?.string, id.uuidString.lowercased())
        await fulfillment(of: [entered], timeout: failureBound)
        let requests = await gate.requests
        XCTAssertEqual(requests, [.init(bundle: bundle, id: id, peers: [id, sibling], operation: .dismiss)])

        let refreshed = ShellNotificationsData(state: "ready", items: [item(id, body: "New metadata"), item(sibling)])
        await gate.setSnapshot(refreshed)
        let loaded = expectation(description: "database refresh preserves pending action")
        var published = false
        controller.onChange = { value in
            if value.items == refreshed.items, value.action?.fields?["state"]?.string == "pending", !published {
                published = true
                loaded.fulfill()
            }
        }
        controller.refresh()
        await fulfillment(of: [loaded], timeout: failureBound)
        let finished = await gate.finish(0, with: .dispatched)
        XCTAssertTrue(finished)
        await task.value
        XCTAssertEqual(controller.current.items, refreshed.items)
        XCTAssertEqual(controller.current.action?.fields?["state"]?.string, "dispatched")
        XCTAssertEqual(controller.current.dispatched, [id.uuidString.lowercased()])
        XCTAssertEqual(controller.current.kept, 0)
        XCTAssertFalse(controller.perform(.dismiss(bundle: bundle, id: id)))
        let dispatchedRequests = await gate.requests
        XCTAssertEqual(dispatchedRequests.count, 1)
        XCTAssertNil(controller.actionTask)
        controller.onChange = nil
    }

    func testReplyUsesUniqueTextActionLabelsAndSuppressesTheRowForBothSuccessOutcomes() async throws {
        for outcome in [ShellNotificationActionOutcome.dispatched, .dispatchedPanelOpen] {
            let id = UUID()
            let action: ShellServiceValue = .object([
                "title": .text("Reply ✓"), "textInputButtonTitle": .text("Send synthetic reply")
            ])
            let snapshot = ShellNotificationsData(state: "ready", items: [item(id, actions: [action])])
            let entered = expectation(description: "reply begins")
            let gate = Gate(snapshot: snapshot, entered: { _ in entered.fulfill() })
            let controller = await controller(gate, expected: snapshot)
            let text = "Reply with \n exact Unicode ✓ 中文"
            XCTAssertTrue(controller.perform(.reply(bundle: bundle, id: id, text: text)))
            let task = try XCTUnwrap(controller.actionTask)
            await fulfillment(of: [entered], timeout: failureBound)
            let requests = await gate.requests
            XCTAssertEqual(requests, [.init(
                bundle: bundle, id: id, peers: [id],
                operation: .reply(text: text, title: "Reply ✓", sendTitle: "Send synthetic reply")
            )])
            let finished = await gate.finish(0, with: outcome)
            XCTAssertTrue(finished)
            await task.value
            await controller.task?.value
            XCTAssertEqual(controller.current.items, snapshot.items)
            XCTAssertEqual(controller.current.action?.fields?["kind"]?.string, "reply")
            XCTAssertEqual(controller.current.action?.fields?["state"]?.string, outcome.rawValue)
            XCTAssertEqual(controller.current.dispatched, [id.uuidString.lowercased()])
            XCTAssertEqual(controller.current.kept, 0)
            XCTAssertFalse(controller.perform(.dismiss(bundle: bundle, id: id)))
            XCTAssertFalse(controller.perform(.reply(bundle: bundle, id: id, text: text)))
            XCTAssertFalse(controller.perform(.dismissAll))
            await controller.actionTask?.value
            let finalRequests = await gate.requests
            let batches = await gate.batches
            XCTAssertEqual(finalRequests.count, 1)
            XCTAssertTrue(batches.isEmpty)
            XCTAssertEqual(controller.current.items, snapshot.items)
            controller.setListening(false)
        }
    }

    func testDismissWithPanelCleanupFeedbackSuppressesTheRowWithoutChangingDatabaseMembership() async throws {
        let id = UUID()
        let snapshot = ShellNotificationsData(state: "ready", items: [item(id)])
        let entered = expectation(description: "dismiss begins")
        let gate = Gate(snapshot: snapshot, entered: { _ in entered.fulfill() })
        let controller = await controller(gate, expected: snapshot)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.perform(.dismiss(bundle: bundle, id: id)))
        let task = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [entered], timeout: failureBound)
        let finished = await gate.finish(0, with: .dispatchedPanelOpen)
        XCTAssertTrue(finished)
        await task.value
        await controller.task?.value
        XCTAssertEqual(controller.current.items, snapshot.items)
        XCTAssertEqual(controller.current.action?.fields?["state"]?.string, "dispatchedPanelOpen")
        XCTAssertEqual(controller.current.dispatched, [id.uuidString.lowercased()])
        XCTAssertFalse(controller.perform(.dismiss(bundle: bundle, id: id)))
        let requests = await gate.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testStaleIncompleteAndAmbiguousRequestsNeverReachNativeActions() async {
        let id = UUID()
        let textAction: ShellServiceValue = .object([
            "title": .text("Reply"), "textInputButtonTitle": .text("Send")
        ])
        let cases: [(ShellNotificationsData, ShellNotificationsCommand, String)] = [
            (.init(state: "ready", items: [item(id)]), .dismiss(bundle: bundle, id: UUID()), "notFound"),
            (.init(state: "ready", items: [item(id)]), .dismiss(bundle: "different.bundle", id: id), "notFound"),
            (.init(state: "ready", items: [item(id), item(id)]), .dismiss(bundle: bundle, id: id), "ambiguous"),
            (
                .init(state: "incomplete", items: [item(id)], complete: false),
                .dismiss(bundle: bundle, id: id),
                "unavailable"
            ),
            (.init(state: "ready", items: [item(id)]), .reply(bundle: bundle, id: id, text: "Reply"), "unsupported"),
            (
                .init(state: "ready", items: [item(id, actions: [textAction, textAction])]),
                .reply(bundle: bundle, id: id, text: "Reply"), "ambiguous"
            ),
            (
                .init(state: "ready", items: [item(id, actions: [textAction, .object(["title": .text("Reply")])])]),
                .reply(bundle: bundle, id: id, text: "Reply"), "ambiguous"
            )
        ]
        for (snapshot, command, outcome) in cases {
            let gate = Gate(snapshot: snapshot)
            let controller = await controller(gate, expected: snapshot)
            XCTAssertFalse(controller.perform(command))
            XCTAssertEqual(controller.current.action?.fields?["state"]?.string, outcome)
            XCTAssertEqual(controller.current.items, snapshot.items)
            XCTAssertNil(controller.actionTask)
            XCTAssertEqual(controller.current.dispatched, [])
            let requests = await gate.requests
            XCTAssertTrue(requests.isEmpty)
            controller.setListening(false)
        }
    }

    func testStoppingFromPendingPublicationCancelsBeforeNativeEffects() async throws {
        let id = UUID()
        let snapshot = ShellNotificationsData(state: "ready", items: [item(id)])
        let gate = Gate(snapshot: snapshot)
        let controller = await controller(gate, expected: snapshot)
        var pending: Task<Void, Never>?
        controller.onChange = { [weak controller] value in
            if value.action?.fields?["state"]?.string == "pending" {
                pending = controller?.actionTask
                controller?.setListening(false)
            }
        }
        XCTAssertTrue(controller.perform(.dismiss(bundle: bundle, id: id)))
        let task = try XCTUnwrap(pending)
        await task.value
        XCTAssertEqual(controller.current, ShellNotificationsData(state: "loading"))
        XCTAssertNil(controller.actionTask)
        let requests = await gate.requests
        XCTAssertTrue(requests.isEmpty)
        controller.onChange = nil
    }

    func testStoppedActionCompletionCannotReplaceRestartedPendingAction() async throws {
        let oldID = UUID()
        let newID = UUID()
        let old = ShellNotificationsData(state: "ready", items: [item(oldID)])
        let fresh = ShellNotificationsData(state: "ready", items: [item(newID)])
        let firstEntered = expectation(description: "old action entered")
        let secondEntered = expectation(description: "new action entered")
        let gate = Gate(snapshot: old, entered: { index in
            if index == 0 { firstEntered.fulfill() }
            else if index == 1 { secondEntered.fulfill() }
            else { XCTFail("Unexpected extra native action") }
        })
        let controller = await controller(gate, expected: old)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.perform(.dismiss(bundle: bundle, id: oldID)))
        let oldTask = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [firstEntered], timeout: failureBound)
        controller.setListening(false)
        XCTAssertEqual(controller.current, ShellNotificationsData(state: "loading"))
        XCTAssertFalse(controller.perform(.dismiss(bundle: bundle, id: oldID)))
        await gate.setSnapshot(fresh)
        await listen(controller, expected: fresh)
        XCTAssertTrue(controller.perform(.dismiss(bundle: bundle, id: newID)))
        let newTask = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [secondEntered], timeout: failureBound)
        let oldFinished = await gate.finish(0, with: .dispatched)
        XCTAssertTrue(oldFinished)
        await oldTask.value
        XCTAssertEqual(controller.current.items, fresh.items)
        XCTAssertEqual(controller.current.action?.fields?["id"]?.string, newID.uuidString.lowercased())
        XCTAssertEqual(controller.current.action?.fields?["state"]?.string, "pending")
        XCTAssertEqual(controller.current.dispatched, [])
        XCTAssertNotNil(controller.actionTask)
        let newFinished = await gate.finish(1, with: .failedPanelOpen)
        XCTAssertTrue(newFinished)
        await newTask.value
        XCTAssertEqual(controller.current.action?.fields?["state"]?.string, "failedPanelOpen")
        XCTAssertEqual(controller.current.dispatched, [])
        XCTAssertNil(controller.actionTask)
    }
}
