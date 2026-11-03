// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import SQLite3
import XCTest

@MainActor
final class ShellNotificationCompletenessTests: XCTestCase {
    private let bundle = "com.example.NotificationCompleteness"

    func testWidgetSourcesMatchTheCommandGrammar() throws {
        let id = "00000000-0000-0000-0000-000000000001"
        for source in [
            "com.example.Valid", "A_1-b.c", "0", "", String(repeating: "a", count: 256),
            "_SYSTEM_CENTER_:com.apple.loginwindow", "has space", "mail.客户", "bad'quote", "bad;command"
        ] {
            let supported = ShellNotificationsCommand(words: ["dismiss", source, id]) != nil
            let value = ShellNotificationsData(state: "ready", items: [.object([
                "id": .text(id), "bundle": .text(source), "title": .text("Source fixture"),
                "actions": .array([.object(["title": .text("Reply"), "textInputButtonTitle": .text("Send")])])
            ])])
            let widget = try ShellRenderedWidget("notifications")
            widget.set("notifications") { value.write(into: &$0) }
            let commands = widget.renderPopout().map { widget.text.string($0.content.action) }
            XCTAssertEqual(commands.contains("notifications dismiss-all"), supported, source)
            XCTAssertEqual(commands.contains("notifications dismiss \(source) \(id)"), supported, source)
            XCTAssertEqual(commands.contains("notifications open \(source)"), supported, source)
            XCTAssertEqual(
                widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Reply", [])),
                supported,
                source
            )
            if !supported {
                XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(
                    "Some notification sources cannot be cleared. Clear supported notifications individually.", []
                )), source)
            }
        }
    }

    func testOptionalTableFailuresDoNotDisableDismissal() async throws {
        for table in ["categories", "displayed", "requests"] {
            let value = try snapshot(missingTable: table)
            XCTAssertTrue(value.membershipComplete, table)
            XCTAssertFalse(value.metadataComplete, table)
            XCTAssertEqual(value.items.count, 2, table)
            if value.membershipComplete { try await assertDismissals(value) }
        }
    }

    func testUnsupportedSourcesAndMissingDetailsHaveACombinedExplanation() throws {
        let id = "00000000-0000-0000-0000-000000000001"
        let value = ShellNotificationsData(state: "incomplete", items: [
            .object(["id": .text(id), "bundle": .text(bundle), "title": .text("Supported source")]),
            .object([
                "id": .text("00000000-0000-0000-0000-000000000002"),
                "bundle": .text("_SYSTEM_CENTER_:com.apple.loginwindow"), "title": .text("System source")
            ])
        ], complete: false, membershipComplete: true, metadataComplete: false)
        let widget = try ShellRenderedWidget("notifications")
        widget.set("notifications") { value.write(into: &$0) }
        let commands = widget.renderPopout().map { widget.text.string($0.content.action) }
        XCTAssertTrue(commands.contains("notifications dismiss \(bundle) \(id)"))
        XCTAssertFalse(commands.contains("notifications dismiss-all"))
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(
            "Some notification details could not be read. Some sources cannot be cleared. Clear supported notifications individually.",
            []
        )))
    }

    func testRequiredTableFailuresStillDisableDismissal() async throws {
        for table in ["delivered", "app", "record"] {
            let value = try snapshot(missingTable: table)
            XCTAssertEqual(value.state, "queryError", table)
            XCTAssertFalse(value.membershipComplete, table)
            XCTAssertFalse(value.metadataComplete, table)
            let controller = await controller(value)
            defer { controller.setListening(false) }
            XCTAssertFalse(controller.perform(.dismissAll), table)
        }
    }

    func testRecordScanStopsBeforeLateCandidatesAfterNonBlobHistory() throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let bytes = withUnsafeBytes(of: id.uuid) { Data($0) }
        let payload = try PropertyListSerialization.data(fromPropertyList: [
            "uuid": bytes, "req": ["titl": "Retained title"]
        ], format: .binary, options: 0)
        try sql("CREATE TABLE record(app_id INTEGER,uuid BLOB,data BLOB)", db)
        try sql("INSERT INTO record VALUES(1,\(blob(bytes)),\(blob(payload)))", db)
        try sql("""
        WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<\(ShellNotificationReadBudget.readRowLimit))
        INSERT INTO record SELECT 1,zeroblob(16),NULL FROM n
        """, db)
        try sql("INSERT INTO record VALUES(1,\(blob(Data(repeating: 7, count: 16))),\(blob(payload)))", db)
        var budget = ShellNotificationReadBudget()
        let rows = try ShellNotificationStore.rows(
            "SELECT * FROM record ORDER BY rowid", db, &budget,
            memberColumns: ["app_id", "uuid"], retained: [1: [id.uuidString.lowercased()]]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(budget.issues.contains(.init(scope: .membership, reason: .rowLimit)))
        XCTAssertFalse(budget.issues.contains(.init(scope: .membership, reason: .identifierMismatch)))
    }

    func testMetadataExhaustionCannotHideDuplicateCandidateIdentity() async throws {
        let value = try snapshot(exhaustMetadataReadBudget: true, duplicateCandidate: true)
        XCTAssertFalse(value.membershipComplete)
        XCTAssertTrue(value.issues.contains(.init(scope: .membership, reason: .identifierMismatch)))
        XCTAssertTrue(value.issues.contains(.init(scope: .membership, reason: .duplicateIdentifier)))
        let controller = await controller(value)
        defer { controller.setListening(false) }
        XCTAssertFalse(controller.perform(.dismissAll))
        XCTAssertFalse(try widgetCommands(value).contains("notifications dismiss-all"))
    }

    func testConflictingRetainedColumnCannotHideBehindConsistentRecords() async throws {
        let value = try snapshot(conflictingRetainedColumn: true)
        XCTAssertEqual(value.items.count, 2)
        XCTAssertFalse(value.membershipComplete)
        XCTAssertTrue(value.issues.contains(.init(scope: .membership, reason: .identifierMismatch)))
        let controller = await controller(value)
        defer { controller.setListening(false) }
        XCTAssertFalse(controller.perform(.dismissAll))
        XCTAssertFalse(try widgetCommands(value).contains("notifications dismiss-all"))
    }

    func testLargeOptionalPayloadDoesNotDiscardVerifiedMemberIdentity() async throws {
        let value = try snapshot(firstPayloadBytes: ShellNotificationReadBudget.valueByteLimit + 1)
        XCTAssertTrue(value.membershipComplete)
        XCTAssertFalse(value.metadataComplete)
        XCTAssertEqual(value.items.count, 2)
        XCTAssertTrue(value.issues.contains(.init(scope: .metadata, reason: .byteLimit)))
        if value.membershipComplete { try await assertDismissals(value) }
    }

    func testUncheckedRetainedPayloadIdentityStillBlocksClearing() async throws {
        let value = try snapshot(firstPayloadBytes: ShellNotificationReadBudget.readByteLimit + 1)
        XCTAssertFalse(value.membershipComplete)
        XCTAssertTrue(value.issues.contains(.init(scope: .membership, reason: .byteLimit)))
        let controller = await controller(value)
        defer { controller.setListening(false) }
        XCTAssertFalse(controller.perform(.dismissAll))
        XCTAssertFalse(try widgetCommands(value).contains("notifications dismiss-all"))
    }

    func testAppIdentityScanStopsBeforeLateRequiredAppAfterUnusedApps() throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        let requiredID = ShellNotificationReadBudget.readRowLimit + 2
        try sql("CREATE TABLE app(app_id INTEGER,identifier TEXT)", db)
        try sql("""
        WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<\(requiredID))
        INSERT INTO app SELECT x,'com.example.Fixture' FROM n
        """, db)
        var budget = ShellNotificationReadBudget()
        let rows = try ShellNotificationStore.rows(
            "SELECT * FROM app ORDER BY app_id", db, &budget,
            memberColumns: ["app_id", "identifier"], memberApps: [Int64(requiredID)]
        )
        XCTAssertEqual(rows.count, ShellNotificationReadBudget.readRowLimit)
        XCTAssertFalse(rows.contains { $0["app_id"]?.integer == Int64(requiredID) })
        XCTAssertTrue(budget.issues.contains(.init(scope: .membership, reason: .rowLimit)))
    }

    func testUnretainedPayloadCannotDegradeSnapshotMetadata() async throws {
        let value = try snapshot(historicalPayloadBytes: ShellNotificationReadBudget.valueByteLimit + 1)
        XCTAssertTrue(value.membershipComplete)
        XCTAssertTrue(value.metadataComplete)
        XCTAssertTrue(value.complete)
        XCTAssertEqual(value.items.count, 2)
        try await assertDismissals(value)
    }

    func testUncheckedCandidateIdentityStillBlocksClearing() async throws {
        let value = try snapshot(historicalPayloadBytes: ShellNotificationReadBudget.readByteLimit + 1)
        XCTAssertFalse(value.membershipComplete)
        XCTAssertTrue(value.metadataComplete)
        XCTAssertEqual(value.items.count, 2)
        XCTAssertTrue(value.issues.contains(.init(scope: .membership, reason: .byteLimit)))
        let controller = await controller(value)
        defer { controller.setListening(false) }
        XCTAssertFalse(controller.perform(.dismissAll))
    }

    func testSystemSourceIdentifierDoesNotDisableOtherApps() async throws {
        let value = try snapshot(systemMember: true)
        XCTAssertTrue(value.membershipComplete)
        XCTAssertEqual(value.items.count, 3)
        let controller = await controller(value, perform: { _ in .dispatched })
        defer { controller.setListening(false) }
        let member = try XCTUnwrap(value.items.first { $0.fields?["bundle"]?.string == bundle }?.fields)
        let id = try XCTUnwrap(member["id"]?.string.flatMap(UUID.init(uuidString:)))
        XCTAssertTrue(controller.perform(.dismiss(bundle: bundle, id: id)))
        await controller.actionTask?.value
        XCTAssertFalse(controller.perform(.dismissAll))
        XCTAssertNil(ShellNotificationsCommand(words: [
            "dismiss", "_SYSTEM_CENTER_:com.apple.loginwindow", id.uuidString
        ]))
        let commands = try widgetCommands(value)
        XCTAssertFalse(commands.contains("notifications dismiss-all"))
        XCTAssertEqual(commands.filter { $0.hasPrefix("notifications dismiss ") }.count, 2)
    }

    func testMalformedOptionalListsOnlyAffectMetadata() async throws {
        for table in ["displayed", "requests"] {
            let value = try snapshot(malformedList: table)
            XCTAssertTrue(value.membershipComplete)
            XCTAssertTrue(value.issues.contains(.init(scope: .metadata, reason: .invalidMetadata)))
            XCTAssertFalse(value.issues.contains(.init(scope: .metadata, reason: .invalidMembership)))
            try await assertDismissals(value)
        }
    }

    func testMalformedOptionalColumnsDoNotDropMembers() async throws {
        for table in ["app", "delivered", "record"] {
            let value = try snapshot(malformedColumn: table)
            XCTAssertTrue(value.membershipComplete)
            XCTAssertFalse(value.metadataComplete)
            XCTAssertEqual(value.items.count, 2)
            try await assertDismissals(value)
        }
    }

    func testUnusedAppMetadataLimitDoesNotDisableDismissal() async throws {
        let value = try snapshot(metadataBytes: 800_000)
        XCTAssertFalse(value.complete)
        XCTAssertEqual(value.items.count, 2)
        try await assertDismissals(value)
    }

    func testUnsupportedTitleDoesNotDisableDismissal() async throws {
        let value = try snapshot(unsupportedTitle: true)
        XCTAssertFalse(value.complete)
        XCTAssertEqual(value.items.count, 2)
        try await assertDismissals(value)
    }

    func testDeepOptionalMetadataDoesNotHideKnownMembers() async throws {
        let value = try snapshot(deepUserInfo: true)
        XCTAssertTrue(value.membershipComplete)
        XCTAssertFalse(value.metadataComplete)
        XCTAssertEqual(value.items.count, 2)
        XCTAssertTrue(value.issues.contains(.init(scope: .metadata, reason: .decodeLimit)))
        try await assertDismissals(value)
    }

    func testMissingRequestDetailsDoNotDisableKnownMembers() async throws {
        let value = try snapshot(missingRequest: true)
        XCTAssertTrue(value.membershipComplete)
        XCTAssertFalse(value.metadataComplete)
        XCTAssertEqual(value.items.count, 2)
        XCTAssertTrue(value.issues.contains(.init(scope: .metadata, reason: .invalidMetadata)))
        try await assertDismissals(value)
    }

    func testOptionalReadBudgetCannotConsumeMembershipBudget() async throws {
        let value = try snapshot(
            exhaustMetadataReadBudget: true, payloadBytes: ShellNotificationReadBudget.valueByteLimit / 16
        )
        XCTAssertTrue(value.membershipComplete)
        XCTAssertFalse(value.metadataComplete)
        XCTAssertEqual(value.items.count, 2)
        XCTAssertTrue(value.issues.contains(.init(scope: .metadata, reason: .byteLimit)))
        try await assertDismissals(value)
    }

    func testSnapshotBudgetPreservesAllMemberIdentitiesBeforeOptionalPayloads() async throws {
        let value = try snapshot(payloadBytes: 600_000)
        XCTAssertTrue(value.membershipComplete)
        XCTAssertFalse(value.metadataComplete)
        XCTAssertEqual(value.items.count, 2)
        XCTAssertTrue(value.issues.contains(.init(scope: .metadata, reason: .encodingLimit)))
        var writer = ShellValueWriter()
        value.write(into: &writer)
        XCTAssertLessThan(writer.bytes.count, 4 << 20)
        try await assertDismissals(value)
    }

    func testFlagsReachTheWidgetAndReasonsStayInDiagnostics() async throws {
        let value = try snapshot(unsupportedTitle: true)
        var writer = ShellValueWriter()
        value.write(into: &writer)
        let decoded = try ShellServiceValue.decode(writer.bytes)
        XCTAssertEqual(decoded.fields?["complete"], .bool(false))
        XCTAssertEqual(decoded.fields?["membershipComplete"], .bool(true))
        XCTAssertEqual(decoded.fields?["metadataComplete"], .bool(false))
        XCTAssertNil(decoded.fields?["issues"])
        let widget = try ShellRenderedWidget("notifications")
        widget.set("notifications") { value.write(into: &$0) }
        _ = widget.renderPopout()
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(
            "Some notification details could not be read. Notifications can still be cleared.", []
        )))
        let controller = await controller(value)
        defer { controller.setListening(false) }
        XCTAssertTrue(controller.diagnosticsSummary.contains("membershipComplete=true metadataComplete=false"))
        XCTAssertTrue(controller.diagnosticsSummary.contains("issues=metadata:unsupportedText"))
    }

    func testIdentifierMismatchAndDuplicateMembersRemainBlocked() async throws {
        for value in [try snapshot(mismatchedIdentifier: true), try snapshot(duplicateMember: true)] {
            XCTAssertFalse(value.membershipComplete)
            let controller = await controller(value)
            defer { controller.setListening(false) }
            XCTAssertFalse(controller.perform(.dismissAll))
            XCTAssertFalse(try widgetCommands(value).contains("notifications dismiss-all"))
        }
        XCTAssertTrue(try snapshot(mismatchedIdentifier: true).issues.contains(
            .init(scope: .membership, reason: .identifierMismatch)
        ))
        XCTAssertTrue(try snapshot(duplicateMember: true).issues.contains(
            .init(scope: .membership, reason: .duplicateIdentifier)
        ))
        let repeated = try snapshot(repeatedDeliveredMember: true)
        XCTAssertTrue(repeated.membershipComplete)
        XCTAssertEqual(repeated.items.count, 2)
        try await assertDismissals(repeated)
    }

    func testMetadataOnlyIncompletenessDoesNotEnableReplies() async throws {
        var target = try XCTUnwrap(snapshot(unsupportedTitle: true).items.first?.fields)
        target["actions"] = .array([.object([
            "title": .text("Reply"), "textInputButtonTitle": .text("Send")
        ])])
        let value = ShellNotificationsData(
            state: "incomplete", items: [.object(target)], complete: false,
            membershipComplete: true, metadataComplete: false
        )
        let ready = ShellNotificationsData(state: "ready", items: [.object(target)])
        for (snapshot, showsReply) in [(value, false), (ready, true)] {
            let widget = try ShellRenderedWidget("notifications")
            widget.set("notifications") { snapshot.write(into: &$0) }
            _ = widget.renderPopout()
            XCTAssertEqual(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Reply", [])), showsReply)
        }
        let controller = await controller(value)
        defer { controller.setListening(false) }
        let id = try XCTUnwrap(target["id"]?.string.flatMap(UUID.init(uuidString:)))
        XCTAssertFalse(controller.perform(.reply(bundle: bundle, id: id, text: "Test reply")))
        XCTAssertNil(controller.actionTask)
    }

    func testPendingActionOnAnotherPageHasAVisibleGlobalReason() throws {
        let items = (1 ... 9).map { index in
            ShellServiceValue.object([
                "id": .text("fixture-\(index)"), "bundle": .text(bundle), "title": .text("Fixture title"),
                "body": .text("Fixture body")
            ])
        }
        let value = ShellNotificationsData(state: "ready", items: items, action: .object([
            "id": .text("fixture-9"), "bundle": .text(bundle), "kind": .text("dismiss"), "state": .text("pending")
        ]))
        let widget = try ShellRenderedWidget("notifications")
        widget.set("notifications") { value.write(into: &$0) }
        let tree = widget.renderPopout()
        XCTAssertFalse(tree.contains { widget.text.string($0.content.action) == "notifications dismiss-all" })
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(
            "Another notification action is still in progress.", []
        )))
    }

    func testMissingMemberStillDisablesDismissal() async throws {
        let value = try snapshot(missingMember: true)
        XCTAssertFalse(value.complete)
        XCTAssertEqual(value.items.count, 2)
        let controller = await controller(value)
        defer { controller.setListening(false) }
        let id = try XCTUnwrap(value.items.first?.fields?["id"]?.string.flatMap(UUID.init(uuidString:)))
        XCTAssertFalse(controller.perform(.dismiss(bundle: bundle, id: id)))
        XCTAssertFalse(controller.perform(.dismissAll))
        let commands = try widgetCommands(value)
        XCTAssertFalse(commands.contains("notifications dismiss-all"))
        XCTAssertFalse(commands.contains { $0.hasPrefix("notifications dismiss ") })
        XCTAssertTrue(value.issues.contains(.init(scope: .membership, reason: .missingRecord)))
        let widget = try ShellRenderedWidget("notifications")
        widget.set("notifications") { value.write(into: &$0) }
        _ = widget.renderPopout()
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(
            "Some notification data could not be read. The list is incomplete.", []
        )))
    }

    private func assertDismissals(_ value: ShellNotificationsData) async throws {
        var singles: [ShellNotificationActionRequest] = []
        let single = await controller(value, perform: { request in
            singles.append(request)
            return .dispatched
        })
        defer { single.setListening(false) }
        let id = try XCTUnwrap(value.items.first?.fields?["id"]?.string.flatMap(UUID.init(uuidString:)))
        XCTAssertTrue(single.perform(.dismiss(bundle: bundle, id: id)))
        await single.actionTask?.value
        XCTAssertEqual(singles.map(\.id), [id])

        var batches: [[ShellNotificationActionRequest]] = []
        let batch = await controller(value, dismissAll: { requests, progress in
            batches.append(requests)
            for _ in requests { progress(.dispatched) }
            return .dispatched
        })
        defer { batch.setListening(false) }
        XCTAssertTrue(batch.perform(.dismissAll))
        await batch.actionTask?.value
        let ids = try value.items.map { try XCTUnwrap($0.fields?["id"]?.string.flatMap(UUID.init(uuidString:))) }
        XCTAssertEqual(batches.first?.map(\.id), ids)

        let commands = try widgetCommands(value)
        XCTAssertTrue(commands.contains("notifications dismiss-all"))
        XCTAssertEqual(commands.filter { $0.hasPrefix("notifications dismiss ") }.count, value.items.count)
    }

    private func controller(
        _ value: ShellNotificationsData,
        perform: ShellNotificationsController.ActionPerformer? = nil,
        dismissAll: ShellNotificationsController.DismissAllPerformer? = nil
    ) async -> ShellNotificationsController {
        let controller = ShellNotificationsController(
            url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathComponent("uncreated/db"),
            load: { _ in value },
            perform: perform ?? { _ in .failed },
            dismissAll: dismissAll ?? { _, _ in .failed },
            resolveName: { _ in nil }
        )
        controller.setListening(true)
        await controller.task?.value
        return controller
    }

    private func widgetCommands(_ value: ShellNotificationsData) throws -> [String] {
        let widget = try ShellRenderedWidget("notifications")
        widget.set("notifications") { value.write(into: &$0) }
        return widget.renderPopout().map { widget.text.string($0.content.action) }
    }

    private func snapshot(
        metadataBytes: Int = 0,
        metadataApps: Int = 1,
        exhaustMetadataReadBudget: Bool = false,
        payloadBytes: Int = 0,
        firstPayloadBytes: Int = 0,
        deepUserInfo: Bool = false,
        missingRequest: Bool = false,
        unsupportedTitle: Bool = false,
        missingMember: Bool = false,
        mismatchedIdentifier: Bool = false,
        duplicateMember: Bool = false,
        repeatedDeliveredMember: Bool = false,
        duplicateCandidate: Bool = false,
        conflictingRetainedColumn: Bool = false,
        historicalPayloadBytes: Int = 0,
        systemMember: Bool = false,
        malformedList: String? = nil,
        malformedColumn: String? = nil,
        missingTable: String? = nil
    ) throws -> ShellNotificationsData {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        try sql("""
        CREATE TABLE app(app_id INTEGER PRIMARY KEY,identifier TEXT);
        CREATE TABLE categories(app_id INTEGER PRIMARY KEY,categories BLOB);
        CREATE TABLE delivered(app_id INTEGER PRIMARY KEY,list BLOB);
        CREATE TABLE displayed(app_id INTEGER PRIMARY KEY,list BLOB);
        CREATE TABLE requests(app_id INTEGER PRIMARY KEY,list BLOB);
        CREATE TABLE record(app_id INTEGER,uuid BLOB,data BLOB);
        INSERT INTO app VALUES(1,'\(bundle)');
        """, db)
        for index in 2 ... (metadataApps + 1) {
            try sql("INSERT INTO app VALUES(\(index),'com.example.UnusedNotificationApp\(index)')", db)
            if metadataBytes > 0 {
                let data = try PropertyListSerialization.data(
                    fromPropertyList: [["id": "unused", "description": String(repeating: "x", count: metadataBytes)]],
                    format: .binary, options: 0
                )
                try sql("INSERT INTO categories VALUES(\(index),\(blob(data)))", db)
            }
        }
        if exhaustMetadataReadBudget {
            var remaining = ShellNotificationReadBudget.readByteLimit
                - "com.example.UnusedNotificationApp2".utf8.count
            var appID = 1
            while remaining > 0 {
                let count = min(remaining, ShellNotificationReadBudget.valueByteLimit / 32)
                try sql("INSERT INTO categories VALUES(\(appID),zeroblob(\(count)))", db)
                remaining -= count
                appID += 1
            }
            var tail = ShellNotificationReadBudget.valueByteLimit / 32
            while tail > 0 {
                try sql("INSERT INTO categories VALUES(\(appID),zeroblob(\(tail)))", db)
                appID += 1
                tail /= 2
            }
            try sql("ALTER TABLE record ADD COLUMN extra TEXT DEFAULT 'optional metadata'", db)
        }
        var membership = Data()
        for index in 1 ... (missingMember ? 3 : 2) {
            let id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)))
            let bytes = withUnsafeBytes(of: id.uuid) { Data($0) }
            membership.append(bytes)
            guard index <= 2 else { continue }
            let title: Any = unsupportedTitle && index == 1 ? ["localized title", "argument"] : "Fixture title"
            var request: [String: Any] = ["titl": title, "body": "Fixture body"]
            let detailBytes = index == 1 ? max(firstPayloadBytes, payloadBytes) : payloadBytes
            if detailBytes > 0 { request["usda"] = Data(repeating: 42, count: detailBytes) }
            if deepUserInfo, index == 1 {
                var details: [String: Any] = ["leaf": "Synthetic details"]
                for _ in 0 ..< 80 { details = ["next": details] }
                request["usda"] = details
            }
            var payload: [String: Any] = ["uuid": bytes, "date": 0.0, "req": request]
            if missingRequest, index == 1 { payload.removeValue(forKey: "req") }
            let data = try PropertyListSerialization.data(
                fromPropertyList: payload,
                format: .binary, options: 0
            )
            let columnID = mismatchedIdentifier && index == 1 ? Data(repeating: 7, count: 16) : bytes
            try sql("INSERT INTO record(app_id,uuid,data) VALUES(1,\(blob(columnID)),\(blob(data)))", db)
            if duplicateMember, index == 1 {
                try sql("INSERT INTO delivered VALUES(2,\(blob(bytes)))", db)
                try sql("INSERT INTO record(app_id,uuid,data) VALUES(2,\(blob(bytes)),\(blob(data)))", db)
            }
            if systemMember, index == 1 {
                let systemID = Data(repeating: 9, count: 16)
                var systemPayload = payload
                systemPayload["uuid"] = systemID
                let systemData = try PropertyListSerialization.data(
                    fromPropertyList: systemPayload, format: .binary, options: 0
                )
                try sql("UPDATE app SET identifier='_SYSTEM_CENTER_:com.apple.loginwindow' WHERE app_id=2", db)
                try sql("INSERT INTO delivered VALUES(2,\(blob(systemID)))", db)
                try sql("INSERT INTO record(app_id,uuid,data) VALUES(2,\(blob(systemID)),\(blob(systemData)))", db)
            }
        }
        if repeatedDeliveredMember { membership.append(Data(membership.prefix(16))) }
        try sql("INSERT INTO delivered VALUES(1,\(blob(membership)))", db)
        if duplicateCandidate || conflictingRetainedColumn || historicalPayloadBytes > 0 {
            let historicalID = Data(repeating: 7, count: 16)
            let columnID = conflictingRetainedColumn ? Data(membership.prefix(16)) : historicalID
            let rootID = duplicateCandidate ? Data(membership.prefix(16)) : historicalID
            let data = try PropertyListSerialization.data(fromPropertyList: [
                "uuid": Data(rootID),
                "req": ["titl": "Historical title", "usda": Data(repeating: 42, count: historicalPayloadBytes)]
            ], format: .binary, options: 0)
            try sql("INSERT INTO record(app_id,uuid,data) VALUES(1,\(blob(columnID)),\(blob(data)))", db)
        }
        if let table = malformedList { try sql("INSERT INTO \(table) VALUES(1,X'01')", db) }
        if let table = malformedColumn {
            try sql("ALTER TABLE \(table) ADD COLUMN extra TEXT", db)
            try sql("UPDATE \(table) SET extra=CAST(X'FF' AS TEXT)", db)
        }
        if let table = missingTable { try sql("DROP TABLE \(table)", db) }
        return ShellNotificationStore.read(at: url)
    }

    private func blob(_ data: Data) -> String {
        "X'" + data.map { String(format: "%02x", $0) }.joined() + "'"
    }

    private func sql(_ statement: String, _ db: OpaquePointer) throws {
        let result = sqlite3_exec(db, statement, nil, nil, nil)
        guard result == SQLITE_OK
        else { throw NSError(domain: "ShellNotificationCompletenessTests", code: Int(result)) }
    }
}
