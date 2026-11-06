// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ShellNotificationsIntegrationTests: XCTestCase {
    private actor FeedReads {
        let entered: @Sendable (Int) -> Void
        private(set) var count = 0
        private var pending: [Int: CheckedContinuation<ShellNotificationsData, Never>] = [:]

        init(entered: @escaping @Sendable (Int) -> Void) {
            self.entered = entered
        }

        func read(_: URL) async -> ShellNotificationsData {
            let index = count
            count += 1
            return await withCheckedContinuation { continuation in
                pending[index] = continuation
                entered(index)
            }
        }

        func finish(_ index: Int, with value: ShellNotificationsData) -> Bool {
            guard let continuation = pending.removeValue(forKey: index) else { return false }
            continuation.resume(returning: value)
            return true
        }

        func finishAll() {
            let values = Array(pending.values)
            pending.removeAll()
            for value in values { value.resume(returning: ShellNotificationsData(state: "loading")) }
        }
    }

    private func snapshot(_ id: String) -> ShellNotificationsData {
        ShellNotificationsData(
            state: "ready",
            items: [.object(["id": .text(id), "body": .text("Synthetic body \(id)")])]
        )
    }

    func testNotificationAndMetadataChangesInvalidateOnlyNotificationReaders() {
        let initial = ShellWidgetData()
        var delivered = initial
        delivered.notifications = snapshot("first")
        XCTAssertEqual(delivered.changedKeys(from: initial), ShellDataKey.notifications.bit)
        XCTAssertEqual(delivered.changedKeys(from: delivered), 0)
        var metadataChanged = delivered
        metadataChanged.notifications = ShellNotificationsData(state: "ready", items: [.object([
            "id": .text("first"), "body": .text("Synthetic body first"),
            "metadata": .object(["futurePrivateField": .bytes([0, 255, 1])])
        ])])
        XCTAssertEqual(metadataChanged.changedKeys(from: delivered), ShellDataKey.notifications.bit)
        var removed = delivered
        removed.notifications = nil
        XCTAssertEqual(removed.changedKeys(from: delivered), ShellDataKey.notifications.bit)
    }

    func testNotificationWirePreservesBinaryMetadataAndExactTaggedIntegers() throws {
        let raw: ShellServiceValue = .bytes([0, 255, 195, 40, 0, 128])
        let large: ShellServiceValue = .object(["type": .text("integer"), "value": .text("18446744073709551615")])
        let item: ShellServiceValue = .object([
            "id": .text("synthetic-guid"), "body": .text("Complete ✓ 中文 العربية 👩🏽‍💻 e\u{301}\n"),
            "metadata": .object([
                "rawPayload": raw, "largeInteger": large,
                "nestedArchive": .object([
                    "uid": .object(["type": .text("uid"), "value": .number(7)]),
                    "values": .array([.bool(false), .null, raw])
                ])
            ])
        ])
        let app: ShellServiceValue = .object(["bundle": .text("fixture.notifications"), "categories": .array([])])
        let value = ShellNotificationsData(
            state: "incomplete",
            items: [item],
            apps: [app],
            complete: false,
            error: "Fixture limit"
        )
        var writer = ShellValueWriter()
        value.write(into: &writer)
        let decoded = try ShellServiceValue.decode(writer.bytes)
        XCTAssertEqual(decoded.fields?["state"]?.string, "incomplete")
        XCTAssertEqual(decoded.fields?["complete"], .bool(false))
        var expected = try XCTUnwrap(item.fields)
        expected["actionsSupported"] = .bool(expected["bundle"]?.string
            .map(ShellNotificationsCommand.validBundle) ?? false)
        XCTAssertEqual(decoded.fields?["items"], .array([.object(expected)]))
        XCTAssertEqual(decoded.fields?["apps"], .array([app]))
        XCTAssertEqual(decoded.fields?["error"]?.string, "Fixture limit")
        XCTAssertEqual(decoded.fields?["items"]?.values?.first?.fields?["metadata"]?.fields?["rawPayload"], raw)
        XCTAssertEqual(decoded.fields?["items"]?.values?.first?.fields?["metadata"]?.fields?["largeInteger"], large)
    }

    func testDeepMetadataReachesTheWidgetWithoutChangingOtherDataLimits() throws {
        let widget = try ShellRenderedWidget(name: "deep-notifications", source: """
        function render(ctx)
            local value = ctx.data.notifications.items[1].userInfo
            for _ = 1, 24 do value = value.child end
            return ui.text{ text = value }
        end
        """)
        var nested: ShellServiceValue = .text("deep metadata preserved")
        for _ in 0 ..< 24 { nested = .object(["child": nested]) }
        let value = ShellNotificationsData(state: "ready", items: [.object(["userInfo": nested])])
        var writer = ShellValueWriter()
        value.write(into: &writer)
        XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(widget.instance, "notifications", $0.baseAddress, $0.count)
        }, OMNI_OK)
        XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(widget.instance, "media", $0.baseAddress, $0.count)
        }, OMNI_ERR_INTERNAL)
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings(OMNI_VIEW_BAR).contains("deep metadata preserved"))
    }

    func testNotificationActionsAcceptSupportedCommandsAndRejectExtraArguments() {
        XCTAssertEqual(ShellAction("notifications refresh"), .notifications(.refresh))
        XCTAssertEqual(
            ShellAction("notifications open com.example.Fixture-App_1"),
            .notifications(.open(bundle: "com.example.Fixture-App_1"))
        )
        XCTAssertEqual(ShellAction("notifications settings"), .settings(.notifications))
        for invalid in [
            "notifications", "notifications refresh extra", "notifications settings extra",
            "notifications open", "notifications open com.example.App extra",
            "notifications open file:///Applications/Fixture.app", "notifications open ../Fixture",
            "notifications open " + String(repeating: "a", count: 256),
            "notifications dismiss synthetic-guid", "notifications reply synthetic-guid text"
        ] {
            XCTAssertNil(ShellAction(invalid), invalid)
        }
    }

    func testFeedStartsPreviouslyDeclaredDemandAndClearsItOnPauseAndDemandRemoval() async {
        let firstRead = expectation(description: "demand starts one read")
        let secondRead = expectation(description: "resume starts one fresh read")
        let firstPublished = expectation(description: "first notification snapshot reaches feed")
        let secondPublished = expectation(description: "resumed notification snapshot reaches feed")
        let reads = FeedReads(entered: { index in
            if index == 0 { firstRead.fulfill() }
            else if index == 1 { secondRead.fulfill() }
            else { XCTFail("Unexpected notification collector read") }
        })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("uncreated/db")
        let controller = ShellNotificationsController(url: url, load: { await reads.read($0) })
        let first = snapshot("first")
        let second = snapshot("resumed")
        var publications: [ShellWidgetData] = []
        var sawFirst = false
        var sawSecond = false
        let feed = ShellDataFeed(notifications: controller, deliver: { value in
            publications.append(value)
            if value.notifications == first, !sawFirst {
                sawFirst = true
                firstPublished.fulfill()
            } else if value.notifications == second, !sawSecond {
                sawSecond = true
                secondPublished.fulfill()
            }
        })
        let demand = ShellDataKey.notifications.bit
        feed.setDemand(demand, cadence: .of([(demand, nil)]))
        XCTAssertFalse(controller.isListening)
        XCTAssertNil(feed.current.notifications)
        let beforeStart = await reads.count
        XCTAssertEqual(beforeStart, 0)
        feed.start()
        feed.start()
        await fulfillment(of: [firstRead], timeout: failureBound)
        let completedFirst = await reads.finish(0, with: first)
        XCTAssertTrue(completedFirst)
        await fulfillment(of: [firstPublished], timeout: failureBound)
        XCTAssertEqual(feed.current.notifications, first)
        feed.setPaused(true)
        XCTAssertFalse(controller.isListening)
        XCTAssertNil(feed.current.notifications)
        XCTAssertEqual(controller.current, ShellNotificationsData(state: "loading"))
        feed.setPaused(false)
        await fulfillment(of: [secondRead], timeout: failureBound)
        let completedSecond = await reads.finish(1, with: second)
        XCTAssertTrue(completedSecond)
        await fulfillment(of: [secondPublished], timeout: failureBound)
        XCTAssertEqual(feed.current.notifications, second)
        feed.setDemand(0, cadence: .of([]))
        XCTAssertFalse(controller.isListening)
        XCTAssertNil(feed.current.notifications)
        XCTAssertNil(publications.last?.notifications)
        let count = await reads.count
        XCTAssertEqual(count, 2)
        feed.stop()
        await reads.finishAll()
    }
}
