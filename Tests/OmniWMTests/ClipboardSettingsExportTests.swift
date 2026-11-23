// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
@testable import OmniWM
import Synchronization
import XCTest

final class ClipboardSettingsExportTests: XCTestCase {
    func testDefaultClipboardKeepsCanonicalTableShapeAndValues() throws {
        let defaults = SettingsExport.defaults()
        let data = try SettingsLuauDocument.initialSource(defaults)
        let tree = try SettingsLuauFixture.fields(in: data)

        XCTAssertEqual(tree["clipboard"], .record([
            "historyEnabled": .boolean(false),
            "maxItems": .integer(200),
            "maxItemBytes": .integer(8_388_608),
            "maxTotalBytes": .integer(67_108_864),
            "ignoredTypes": .record([:])
        ]))
        XCTAssertEqual(try SettingsLuauFixture.decode(data), defaults)
    }

    func testClipboardRoundTripPreservesValuesWithoutAddingNormalization() throws {
        var export = SettingsExport.defaults()
        export.clipboard = SettingsExport.Clipboard(
            historyEnabled: true,
            maxItems: -1,
            maxItemBytes: 0,
            maxTotalBytes: 17,
            ignoredTypes: ["org.example.private", "org.example.other"]
        )

        let encoded = try SettingsLuauDocument.initialSource(export)
        XCTAssertEqual(try SettingsLuauFixture.decode(encoded), export)
    }

    func testMissingIgnoredTypesDecodesAsEmpty() throws {
        let data = try SettingsLuauDocument.initialSource(.defaults())
        let source = String(decoding: data, as: UTF8.self)
        let previousSettings = source.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("ignoredTypes = ")
        }.joined(separator: "\n")
        let decoded = try SettingsLuauFixture.decode(Data(previousSettings.utf8))
        XCTAssertEqual(decoded.clipboard.ignoredTypes, [])
    }

    func testExistingClipboardKeysRemainRequired() throws {
        try SettingsLuauFixture.assertRequiredFields(
            ["historyEnabled", "maxItems", "maxItemBytes", "maxTotalBytes"],
            in: "clipboard"
        )
    }

    @MainActor
    func testStoreKeepsScalarObservationAndRoundTripEquality() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false),
            autosaveEnabled: false
        )
        var desired = settings.toExport()
        desired.clipboard = SettingsExport.Clipboard(
            historyEnabled: true,
            maxItems: 37,
            maxItemBytes: 1_024,
            maxTotalBytes: 8_192,
            ignoredTypes: ["org.example.private"]
        )
        let changeObserved = Mutex(false)
        withObservationTracking {
            _ = settings.clipboard.maxItems
        } onChange: {
            changeObserved.withLock { $0 = true }
        }

        settings.applyExport(desired)

        XCTAssertTrue(changeObserved.withLock { $0 })
        XCTAssertTrue(settings.clipboard.historyEnabled)
        XCTAssertEqual(settings.clipboard.maxItems, 37)
        XCTAssertEqual(settings.clipboard.maxItemBytes, 1_024)
        XCTAssertEqual(settings.clipboard.maxTotalBytes, 8_192)
        XCTAssertEqual(settings.clipboard.ignoredTypes, ["org.example.private"])
        let actual = settings.toExport()
        XCTAssertEqual(actual, desired)
        desired.clipboard.maxItems += 1
        XCTAssertNotEqual(actual, desired)
    }
}
