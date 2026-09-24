// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
@testable import OmniWM
import Synchronization
import TOML
import XCTest

final class ClipboardSettingsExportTests: XCTestCase {
    func testDefaultClipboardKeepsCanonicalTableShapeAndValues() throws {
        let defaults = SettingsExport.defaults()
        let data = try SettingsTOMLCodec.encode(defaults)
        let tree = try TOMLDecoder().decode([String: TOMLNode].self, from: data)

        XCTAssertEqual(tree["clipboard"], .table([
            "historyEnabled": .boolean(false),
            "maxItems": .integer(200),
            "maxItemBytes": .integer(8_388_608),
            "maxTotalBytes": .integer(67_108_864),
            "ignoredTypes": .array([])
        ]))
        XCTAssertEqual(try SettingsTOMLCodec.decode(data), defaults)
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

        let encoded = try SettingsTOMLCodec.encode(export)
        XCTAssertEqual(try SettingsTOMLCodec.decode(encoded), export)
    }

    func testMissingIgnoredTypesDecodesAsEmpty() throws {
        let data = try SettingsTOMLCodec.encode(.defaults())
        let source = String(decoding: data, as: UTF8.self)
        let previousSettings = source.components(separatedBy: "\n").filter {
            !$0.hasPrefix("ignoredTypes = ")
        }.joined(separator: "\n")
        let decoded = try SettingsTOMLCodec.decode(Data(previousSettings.utf8))
        XCTAssertEqual(decoded.clipboard.ignoredTypes, [])
    }

    func testExistingClipboardKeysRemainRequired() throws {
        let data = try SettingsTOMLCodec.encode(.defaults())
        let source = String(decoding: data, as: UTF8.self)
        for key in ["historyEnabled", "maxItems", "maxItemBytes", "maxTotalBytes"] {
            var lines = source.components(separatedBy: "\n")
            let header = try XCTUnwrap(lines.firstIndex(of: "[clipboard]"))
            let following = lines.indices.dropFirst(header + 1)
            let sectionEnd = following.first { lines[$0].hasPrefix("[") } ?? lines.endIndex
            let field = try XCTUnwrap(((header + 1) ..< sectionEnd).first {
                lines[$0].hasPrefix("\(key) = ")
            })
            lines.remove(at: field)

            XCTAssertThrowsError(try SettingsTOMLCodec.decode(Data(lines.joined(separator: "\n").utf8))) { error in
                guard case let DecodingError.keyNotFound(missingKey, context) = error else {
                    return XCTFail("Expected missing clipboard key, got \(error)")
                }
                XCTAssertEqual(missingKey.stringValue, key)
                XCTAssertEqual(context.codingPath.map(\.stringValue), ["clipboard"])
            }
        }
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
