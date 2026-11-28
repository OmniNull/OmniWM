// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class HiddenBarSettingsLuauTests: XCTestCase {
    func testRoundTripsAllHiddenBarFields() throws {
        let cases: [([String], Bool, Double)] = [(["com.example.a", "com.example.b"], false, 12), ([], true, 5)]
        for (bundleIDs, enabled, rehideInterval) in cases {
            var export = SettingsExport.defaults()
            export.hiddenBar.enabled = enabled
            export.hiddenBar.hiddenBundleIDs = bundleIDs
            export.hiddenBar.rehideIntervalSeconds = rehideInterval

            let decoded = try SettingsLuauFixture.decode(SettingsLuauDocument.initialSource(export))

            XCTAssertEqual(decoded.hiddenBar.enabled, enabled)
            XCTAssertEqual(decoded.hiddenBar.hiddenBundleIDs, bundleIDs)
            XCTAssertEqual(decoded.hiddenBar.rehideIntervalSeconds, rehideInterval)
        }
    }

    func testPopulatedBundleListSurvivesPreservingEncode() throws {
        var export = SettingsExport.defaults()
        export.hiddenBar.hiddenBundleIDs = ["com.keep.me"]
        var previousExport = export
        previousExport.hiddenBar.hiddenBundleIDs = ["com.old"]
        let previous = try SettingsLuauDocument.initialSource(previousExport)

        let rewritten = String(
            decoding: try SettingsLuauFixture.editing(previous, to: export),
            as: UTF8.self
        )
        XCTAssertTrue(rewritten.contains("com.keep.me"))
        XCTAssertFalse(rewritten.contains("com.old"))
        XCTAssertEqual(try SettingsLuauFixture.decode(Data(rewritten.utf8)).hiddenBar.hiddenBundleIDs, ["com.keep.me"])
    }

    @MainActor
    func testApplyExportNormalizesRehideIntervalFromLuau() throws {
        let settings = makeSettingsStore()
        let cases = [
            (literal: "1", expected: 2.0),
            (literal: "12", expected: 12.0),
            (literal: "31", expected: 30.0)
        ]

        for invalid in ["math.huge", "-math.huge", "(0 / 0)"] {
            XCTAssertThrowsError(try SettingsLuauFixture.decode(sourceWithRehideInterval(invalid)))
        }
        for testCase in cases {
            let export = try SettingsLuauFixture.decode(sourceWithRehideInterval(testCase.literal))
            settings.applyExport(export)

            XCTAssertEqual(
                settings.hiddenBar.rehideIntervalSeconds,
                testCase.expected,
                "Luau value: \(testCase.literal)"
            )
        }
    }

    @MainActor
    func testHiddenListEditsNormalizeAndReconcileOnlyAcceptedChanges() {
        let settings = makeSettingsStore()
        var reconciliations = 0

        HiddenBarSettingsEdits.setHidden(
            true,
            bundleID: "com.example.item",
            settings: settings
        ) {
            reconciliations += 1
        }
        XCTAssertEqual(settings.hiddenBar.hiddenBundleIDs, ["com.example.item"])
        XCTAssertEqual(reconciliations, 1)

        HiddenBarSettingsEdits.setHidden(
            true,
            bundleID: "com.apple.systemuiserver",
            settings: settings
        ) {
            reconciliations += 1
        }
        XCTAssertEqual(settings.hiddenBar.hiddenBundleIDs, ["com.example.item"])
        XCTAssertEqual(reconciliations, 1)
    }

    private func sourceWithRehideInterval(_ literal: String) throws -> Data {
        let source = String(decoding: try SettingsLuauDocument.initialSource(.defaults()), as: UTF8.self)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix("rehideIntervalSeconds = ")
            else { return String(line) }
            return "rehideIntervalSeconds = \(literal),"
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMHiddenBarSettingsTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }
}
