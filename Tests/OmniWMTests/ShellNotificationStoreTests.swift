// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import SQLite3
import XCTest

final class ShellNotificationStoreTests: XCTestCase {
    private let fixtureBundle = "com.omniwm.NotificationRouteFixture"
    private let allowed = ShellNotificationPreferences.notificationsAllowed
    private let hidden = ShellNotificationPreferences.hiddenFromNotificationCenter

    func testAlertStyleDoesNotDetermineHistoryMembershipAndMissingMembersStillFail() throws {
        let base = try XCTUnwrap(PropertyListSerialization
            .propertyList(from: fixture("rich-base"), format: nil) as? [String: Any])
        try database { url, db in
            var members = Data()
            var expected: Set<String> = []
            for (index, style) in ["0", "1", "2", "99", "NULL"].enumerated() {
                let id = Data(repeating: UInt8(index + 1), count: 16)
                var root = base
                root["uuid"] = id
                let payload = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
                try insert(payload, uuid: id, into: db)
                try sql("UPDATE record SET style=\(style),presented=0 WHERE uuid=\(blob(id))", db)
                members.append(id)
                expected.insert(try XCTUnwrap(ShellNotificationMetadata.guid(id)))
            }
            try sql("INSERT INTO delivered VALUES(1,\(blob(members)))", db)
            let result = read(url)
            XCTAssertTrue(result.complete)
            XCTAssertEqual(Set(result.items.compactMap { $0.fields?["id"]?.string }), expected)

            members.append(Data(repeating: 9, count: 16))
            try sql("UPDATE delivered SET list=\(blob(members))", db)
            let incomplete = read(url)
            XCTAssertFalse(incomplete.membershipComplete)
            XCTAssertTrue(incomplete.issues.contains { $0.reason == .missingRecord })
            XCTAssertEqual(incomplete.items.count, expected.count)
        }
    }

    func testCurrentPreferencesControlHistoryIndependentlyOfArrivalStyle() throws {
        let payload = try fixture("rich-base")
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let guid = try XCTUnwrap(root["uuid"] as? Data)
        try database { url, db in
            try insert(payload, uuid: guid, into: db)
            try sql("INSERT INTO delivered VALUES(1,\(blob(guid)))", db)
            for style in [0, 1, 2] {
                try sql("UPDATE record SET style=\(style)", db)
                for (flags, visible) in [(allowed, true), (allowed | hidden, false), (.zero, false), (allowed, true)] {
                    try setPreferences([["bundle-id": fixtureBundle, "flags": flags]], for: url)
                    let result = read(url)
                    XCTAssertEqual(result.items.count, visible ? 1 : 0)
                    XCTAssertEqual(result.state, visible ? "ready" : "empty")
                    XCTAssertTrue(result.membershipComplete)
                    XCTAssertTrue(result.complete)
                    XCTAssertTrue(result.issues.isEmpty)
                }
            }
            try sql("UPDATE delivered SET list=\(blob(guid + Data(repeating: 9, count: 16)))", db)
            let incomplete = read(url)
            XCTAssertFalse(incomplete.membershipComplete)
            XCTAssertTrue(incomplete.issues.contains { $0.reason == .missingRecord })
        }
    }

    func testPreferenceMatchingIgnoresBundleCaseWithoutChangingPublishedIdentifiers() throws {
        let payload = try fixture("rich-base")
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let guid = try XCTUnwrap(root["uuid"] as? Data)
        for bundle in ["com.apple.ScriptEditor2", "net.whatsapp.WhatsApp"] {
            for (stored, preference) in [(bundle.lowercased(), bundle), (bundle, bundle.lowercased())] {
                try database { url, db in
                    try sql("UPDATE app SET identifier='\(stored)' WHERE app_id=1", db)
                    try insert(payload, uuid: guid, into: db)
                    try sql("INSERT INTO delivered VALUES(1,\(blob(guid)))", db)
                    for flags in [allowed | hidden, allowed] {
                        try setPreferences([["bundle-id": preference, "flags": flags]], for: url)
                        let result = read(url)
                        XCTAssertTrue(result.complete)
                        if flags & hidden != 0 {
                            XCTAssertTrue(result.items.isEmpty)
                        } else {
                            XCTAssertEqual(result.items.count, 1)
                            XCTAssertEqual(result.items.first?.fields?["bundle"]?.string, stored)
                        }
                        XCTAssertEqual(result.apps.first?.fields?["bundle"]?.string, stored)
                    }
                }
            }
        }
    }

    func testExcludedAppStillParticipatesInCrossAppDuplicateValidation() throws {
        let payload = try fixture("rich-base")
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let guid = try XCTUnwrap(root["uuid"] as? Data)
        let bundles = [fixtureBundle, "com.omniwm.OtherFixture"]
        for excluded in bundles {
            try database { url, db in
                try sql("INSERT INTO app(app_id,identifier) VALUES(2,'\(bundles[1])')", db)
                for app in [1, 2] {
                    try insert(payload, uuid: guid, into: db)
                    try sql("UPDATE record SET app_id=\(app) WHERE rec_id=last_insert_rowid()", db)
                    try sql("INSERT INTO delivered VALUES(\(app),\(blob(guid)))", db)
                }
                try setPreferences(
                    bundles.map { ["bundle-id": $0, "flags": $0 == excluded ? .zero : allowed] }, for: url
                )
                let result = read(url)
                XCTAssertEqual(result.items.count, 1)
                XCTAssertEqual(result.items.first?.fields?["bundle"]?.string, bundles.first { $0 != excluded })
                XCTAssertFalse(result.membershipComplete)
                XCTAssertFalse(result.canDismiss)
                XCTAssertTrue(result.issues.contains { $0.reason == .duplicateIdentifier })
            }
        }
    }

    func testUnreadablePreferencesLeaveTheSnapshotUnfiltered() throws {
        let payload = try fixture("rich-base")
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let guid = try XCTUnwrap(root["uuid"] as? Data)
        try database { url, db in
            try insert(payload, uuid: guid, into: db)
            try sql("INSERT INTO delivered VALUES(1,\(blob(guid)))", db)
            let hiddenFixture: [[String: Any]] = [["bundle-id": fixtureBundle, "flags": hidden]]
            try setPreferences(hiddenFixture, for: url)
            XCTAssertTrue(read(url).items.isEmpty)
            try FileManager.default.removeItem(at: preferencesURL(url))
            let missing = read(url)
            try Data([1, 2, 3]).write(to: preferencesURL(url))
            let malformed = read(url)
            let unsupportedPreferences: [String: Any] = [
                "version": ShellNotificationPreferences.supportedVersion + 1, "apps": hiddenFixture
            ]
            try PropertyListSerialization.data(fromPropertyList: unsupportedPreferences, format: .binary, options: 0)
                .write(to: preferencesURL(url))
            let unsupported = read(url)
            let readFailure = ShellNotificationStore.read(
                at: url, preferencesURL: url.deletingLastPathComponent(), isInstalled: { _ in false }
            )
            for result in [missing, malformed, unsupported, readFailure] {
                XCTAssertEqual(result.state, "ready")
                XCTAssertEqual(result.items.count, 1)
                XCTAssertTrue(result.complete)
                XCTAssertTrue(result.issues.isEmpty)
            }
        }
    }

    func testAppsWithoutSettingsAreListedOnlyWhenInstalled() throws {
        let payload = try fixture("rich-base")
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let guid = try XCTUnwrap(root["uuid"] as? Data)
        try database { url, db in
            try insert(payload, uuid: guid, into: db)
            try sql("INSERT INTO delivered VALUES(1,\(blob(guid)))", db)
            try setPreferences([], for: url)
            let removed = read(url)
            XCTAssertTrue(removed.items.isEmpty)
            XCTAssertEqual(removed.state, "empty")
            XCTAssertTrue(removed.complete)
            XCTAssertEqual(read(url, installed: [fixtureBundle]).items.count, 1)
            try sql(
                "UPDATE app SET identifier='\(ShellNotificationPreferences.permissionPromptSource)' WHERE app_id=1", db
            )
            XCTAssertEqual(read(url).items.count, 1)
            try sql("UPDATE delivered SET list=\(blob(guid + Data(repeating: 9, count: guid.count)))", db)
            try sql("UPDATE app SET identifier='\(fixtureBundle)' WHERE app_id=1", db)
            let incomplete = read(url)
            XCTAssertTrue(incomplete.items.isEmpty)
            XCTAssertFalse(incomplete.membershipComplete)
            XCTAssertTrue(incomplete.issues.contains { $0.reason == .missingRecord })
        }
    }

    func testSystemCenterSourcesAreNeverListedWhateverTheirSettings() throws {
        let payload = try fixture("rich-base")
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let guid = try XCTUnwrap(root["uuid"] as? Data)
        let source = ShellNotificationPreferences.systemCenterPrefix + "com.example.agent"
        let settings: [[[String: Any]]] = [[], [["bundle-id": source.uppercased(), "flags": allowed]]]
        try database { url, db in
            try sql("UPDATE app SET identifier='\(source)' WHERE app_id=1", db)
            try insert(payload, uuid: guid, into: db)
            try sql("INSERT INTO delivered VALUES(1,\(blob(guid)))", db)
            for apps in settings {
                try setPreferences(apps, for: url)
                let result = read(url, installed: [source])
                XCTAssertTrue(result.items.isEmpty)
                XCTAssertEqual(result.state, "empty")
                XCTAssertTrue(result.complete)
            }
        }
    }

    func testDuplicateIDsAcrossAlertStylesKeepOneItemInEitherRowOrder() throws {
        let payload = try fixture("rich-base")
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let guid = try XCTUnwrap(root["uuid"] as? Data)
        for styles in [[0, 1], [1, 0], [1, 1]] {
            try database { url, db in
                for style in styles {
                    try insert(payload, uuid: guid, into: db)
                    try sql("UPDATE record SET style=\(style) WHERE rec_id=last_insert_rowid()", db)
                }
                try sql("INSERT INTO delivered VALUES(1,\(blob(guid)))", db)
                let result = read(url)
                XCTAssertEqual(result.items.count, 1)
                XCTAssertEqual(result.items.first?.fields?["id"]?.string, ShellNotificationMetadata.guid(guid))
                XCTAssertFalse(result.membershipComplete)
                XCTAssertTrue(result.issues.contains { $0.reason == .duplicateIdentifier })
                XCTAssertFalse(result.issues.contains { $0.reason == .missingRecord })
            }
        }
    }

    func testRichRecordPreservesExactTextArchivesActionsAndBinaryMetadata() throws {
        let payload = try fixture("rich-base")
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let request = try XCTUnwrap(root["req"] as? [String: Any])
        let guid = try XCTUnwrap(root["uuid"] as? Data)
        try database { url, db in
            try insert(payload, uuid: guid, into: db)
            try sql("INSERT INTO delivered VALUES (1,\(blob(guid)))", db)
            let result = read(url)
            XCTAssertEqual(result.state, "ready")
            XCTAssertTrue(result.complete)
            let item = try XCTUnwrap(result.items.first?.fields)
            XCTAssertEqual(item["body"]?.string, request["body"] as? String)
            XCTAssertEqual(item["title"]?.string, request["titl"] as? String)
            XCTAssertEqual(item["id"]?.string, ShellNotificationMetadata.guid(guid))
            XCTAssertEqual(item["requestId"]?.string, "probe.rich.r1.base")
            XCTAssertEqual(item["attachments"]?.values?.count, 3)
            XCTAssertEqual(item["actions"]?.values?.count, 4)
            XCTAssertEqual(
                item["actions"]?.values?.first?.fields?["textInputButtonTitle"]?.string,
                "Send synthetic reply"
            )
            XCTAssertEqual(item["userInfo"]?.fields?["nested"]?.fields?["integer"], .number(424242))
            XCTAssertEqual(item["userInfo"]?.fields?["nested"]?.fields?["flag"], .bool(true))
            XCTAssertEqual(ShellNotificationMetadata.data(item["metadata"]?.fields?["rawPayload"]), payload)
            XCTAssertEqual(item["metadata"]?.fields?["columns"]?.fields?["uuid"]?.fields?["type"]?.string, "data")
            XCTAssertEqual(result.apps.first?.fields?["columns"]?.fields?["extra"]?.string, "preserved")
            var writer = ShellValueWriter()
            result.write(into: &writer)
            XCTAssertLessThan(writer.bytes.count, 4 << 20)
            XCTAssertNoThrow(try ShellServiceValue.decode(writer.bytes))
        }
    }

    func testCommunicationGraphIsResolvedWithoutClassInstantiation() throws {
        let decoded = try ShellNotificationMetadata.decode(fixture("rich-communication"))
        let context = ShellNotificationMetadata.unwrapped(decoded.value.fields?["req"]?.fields?["uncc"])
        XCTAssertTrue(decoded.complete)
        XCTAssertEqual(context.fields?["archivedClass"]?.string, "_UNNotificationCommunicationContext")
        XCTAssertEqual(context.fields?["sender"]?.fields?["handle"]?.string, "sender@example.invalid")
        XCTAssertEqual(
            context.fields?["recipients"]?.values?.first?.fields?["handle"]?.string,
            "recipient@example.invalid"
        )
        XCTAssertEqual(context.fields?["identifier"]?.string, "rich.conversation.r2")
    }

    func testPayloadGUIDWinsOverDifferentColumnUUIDAndReportsIncomplete() throws {
        let payload = try fixture("rich-base")
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let guid = try XCTUnwrap(root["uuid"] as? Data)
        try database { url, db in
            try insert(payload, uuid: Data(repeating: 7, count: 16), into: db)
            try sql("INSERT INTO delivered VALUES (1,\(blob(guid)))", db)
            let result = read(url)
            XCTAssertEqual(result.state, "incomplete")
            XCTAssertFalse(result.complete)
            XCTAssertEqual(result.items.first?.fields?["id"]?.string, ShellNotificationMetadata.guid(guid))
        }
    }

    func testMalformedNonmemberDoesNotEraseRetainedNotification() throws {
        let payload = try fixture("rich-base")
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let guid = try XCTUnwrap(root["uuid"] as? Data)
        try database { url, db in
            try insert(payload, uuid: guid, into: db)
            try insert(Data([1, 2, 3]), uuid: Data(repeating: 4, count: 16), into: db)
            try sql("INSERT INTO delivered VALUES (1,\(blob(guid)))", db)
            let result = read(url)
            XCTAssertEqual(result.state, "ready")
            XCTAssertTrue(result.complete)
            XCTAssertEqual(result.items.count, 1)
        }
    }

    func testNullEmptyMembershipMalformedAndMissingStorageAreDistinct() throws {
        try database { url, db in
            try sql("INSERT INTO delivered VALUES (1,NULL)", db)
            XCTAssertEqual(read(url).state, "empty")
            try sql("UPDATE delivered SET list=X'010203'", db)
            let malformed = read(url)
            XCTAssertEqual(malformed.state, "malformed")
            XCTAssertFalse(malformed.complete)
        }
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(read(missing).state, "unavailable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testMalformedRetainedRecordKeepsValidPartialItems() throws {
        let payload = try fixture("rich-base")
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let guid = try XCTUnwrap(root["uuid"] as? Data)
        let corrupt = Data(repeating: 3, count: 16)
        try database { url, db in
            try insert(payload, uuid: guid, into: db)
            try insert(Data([1, 2, 3]), uuid: corrupt, into: db)
            try sql("INSERT INTO delivered VALUES(1,\(blob(guid + corrupt)))", db)
            let result = read(url)
            XCTAssertEqual(result.state, "malformed")
            XCTAssertFalse(result.complete)
            XCTAssertEqual(result.items.count, 1)
        }
    }

    func testLargeIntegersDatesOpaqueBytesAndOrdinaryUIDKeysStayTyped() throws {
        let object: [String: Any] = [
            "integer": NSNumber(value: Int64.max),
            "date": Date(timeIntervalSince1970: 123),
            "opaque": Data([0, 255, 1]),
            "dictionary": ["OmniWMUID": 3],
            "cfDictionary": ["CF$UID": 4],
            "sentinel": ["OmniWMNotificationUID": 5]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        let decoded = try ShellNotificationMetadata.decode(data)
        XCTAssertEqual(decoded.value.fields?["integer"]?.fields?["value"]?.string, String(Int64.max))
        XCTAssertEqual(decoded.value.fields?["date"]?.fields?["unixSeconds"], .number(123))
        XCTAssertEqual(ShellNotificationMetadata.data(decoded.value.fields?["opaque"]), Data([0, 255, 1]))
        XCTAssertEqual(decoded.value.fields?["dictionary"]?.fields?["OmniWMUID"], .number(3))
        XCTAssertEqual(decoded.value.fields?["cfDictionary"]?.fields?["CF$UID"], .number(4))
        XCTAssertEqual(decoded.value.fields?["sentinel"]?.fields?["OmniWMNotificationUID"], .number(5))
    }

    func testNestedPropertyListsCannotResetDepthBudget() throws {
        var value = try PropertyListSerialization.data(
            fromPropertyList: ["leaf": "retained"],
            format: .binary,
            options: 0
        )
        for _ in 0 ..< 60 { value = try PropertyListSerialization.data(
            fromPropertyList: ["nested": value],
            format: .binary,
            options: 0
        ) }
        let decoded = try ShellNotificationMetadata.decode(value)
        XCTAssertFalse(decoded.complete)
        XCTAssertEqual(ShellNotificationMetadata.data(decoded.value.fields?["nested"])?.isEmpty, false)
    }

    func testTwentyLevelUserInfoRemainsStructuredInDatabaseSnapshot() throws {
        var root = try XCTUnwrap(PropertyListSerialization
            .propertyList(from: fixture("rich-base"), format: nil) as? [String: Any])
        var request = try XCTUnwrap(root["req"] as? [String: Any])
        var nested: [String: Any] = ["leaf": "deeply preserved"]
        for _ in 0 ..< 20 { nested = ["next": nested] }
        request["usda"] = try PropertyListSerialization.data(fromPropertyList: nested, format: .binary, options: 0)
        root["req"] = request
        let guid = try XCTUnwrap(root["uuid"] as? Data)
        let payload = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try database { url, db in
            try insert(payload, uuid: guid, into: db)
            try sql("INSERT INTO delivered VALUES(1,\(blob(guid)))", db)
            let result = read(url)
            XCTAssertTrue(result.complete)
            var value = result.items.first?.fields?["userInfo"]
            for _ in 0 ..< 20 { value = value?.fields?["next"] }
            XCTAssertEqual(value?.fields?["leaf"]?.string, "deeply preserved")
        }
    }

    func testUnsupportedTextShapeIsExplicitlyIncompleteWithRawValuePreserved() throws {
        var root = try XCTUnwrap(PropertyListSerialization
            .propertyList(from: fixture("rich-base"), format: nil) as? [String: Any])
        var request = try XCTUnwrap(root["req"] as? [String: Any])
        request["titl"] = ["unresolved localization", "argument"]
        root["req"] = request
        let guid = try XCTUnwrap(root["uuid"] as? Data)
        let payload = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try database { url, db in
            try insert(payload, uuid: guid, into: db)
            try sql("INSERT INTO delivered VALUES(1,\(blob(guid)))", db)
            let result = read(url)
            XCTAssertFalse(result.complete)
            XCTAssertEqual(result.state, "incomplete")
            XCTAssertEqual(result.items.first?.fields?["title"]?.string, "")
            XCTAssertEqual(
                result.items.first?.fields?["metadata"]?.fields?["payload"]?.fields?["req"]?.fields?["titl"]?.values?
                    .count,
                2
            )
        }
    }

    func testDataLikeUserDictionaryNeedsMatchingBinaryLengthTag() throws {
        let value: [String: Any] = ["type": "data", "bytes": "ordinary user text", "byteLength": 999]
        let bytes = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        let decoded = try ShellNotificationMetadata.decode(bytes)
        XCTAssertEqual(decoded.value.fields?["bytes"]?.string, "ordinary user text")
        XCTAssertNil(ShellNotificationMetadata.data(decoded.value))
    }

    private func fixture(_ name: String) throws -> Data {
        let root = try XCTUnwrap(Bundle.module.resourceURL)
        return try Data(contentsOf: root.appendingPathComponent("Fixtures/Notifications/\(name).bplist"))
    }

    private func read(_ url: URL, installed: Set<String> = []) -> ShellNotificationsData {
        ShellNotificationStore.read(at: url, preferencesURL: preferencesURL(url), isInstalled: installed.contains)
    }

    private func preferencesURL(_ database: URL) -> URL {
        database.deletingLastPathComponent().appendingPathComponent("preferences.plist")
    }

    private func setPreferences(_ apps: [[String: Any]], for database: URL) throws {
        try notificationPreferences(apps).write(to: preferencesURL(database), options: .atomic)
    }

    private func database(_ body: (URL, OpaquePointer) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db")
        try setPreferences([["bundle-id": fixtureBundle, "flags": allowed]], for: url)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        try sql(
            "CREATE TABLE app(app_id INTEGER PRIMARY KEY,identifier TEXT,badge INTEGER,extra TEXT); CREATE TABLE categories(app_id INTEGER PRIMARY KEY,categories BLOB); CREATE TABLE delivered(app_id INTEGER PRIMARY KEY,list BLOB); CREATE TABLE displayed(app_id INTEGER PRIMARY KEY,list BLOB); CREATE TABLE requests(app_id INTEGER PRIMARY KEY,list BLOB); CREATE TABLE record(rec_id INTEGER PRIMARY KEY,app_id INTEGER,uuid BLOB,data BLOB,request_date REAL,request_last_date REAL,delivered_date REAL,presented INTEGER,style INTEGER,snooze_fire_date REAL); INSERT INTO app VALUES(1,'\(fixtureBundle)',37,'preserved'); INSERT INTO displayed VALUES(1,NULL); INSERT INTO requests VALUES(1,NULL);",
            db
        )
        try sql("INSERT INTO categories VALUES(1,\(blob(try fixture("categories"))))", db)
        try body(url, db)
    }

    private func insert(_ payload: Data, uuid: Data, into database: OpaquePointer) throws {
        try sql(
            "INSERT INTO record(app_id,uuid,data,presented,style) VALUES(1,\(blob(uuid)),\(blob(payload)),0,1)",
            database
        )
    }

    private func blob(_ data: Data) -> String {
        "X'" + data.map { String(format: "%02x", $0) }.joined() + "'"
    }

    private func sql(_ text: String, _ database: OpaquePointer) throws {
        let status = sqlite3_exec(database, text, nil, nil, nil)
        guard status == SQLITE_OK else { throw NSError(domain: "ShellNotificationStoreTests", code: Int(status)) }
    }
}
