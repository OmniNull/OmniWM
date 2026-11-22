// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class WindowGesturePersistenceTests: XCTestCase {
    func testWindowGestureKeysAreAdditiveWithinCurrentSchema() throws {
        let canonical = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let data = Data(canonical.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("windowMove") && !$0.hasPrefix("windowResize")
                && !$0.hasPrefix("windowGestureSensitivity")
            }
            .joined(separator: "\n").utf8)

        let result = try SettingsTOMLCodec.decodeForLoad(data)

        XCTAssertEqual(SettingsTOMLCodec.currentSchemaVersion, 5)
        XCTAssertNil(result.migration)
        XCTAssertEqual(result.export.gestures.windowMoveEnabled, false)
        XCTAssertEqual(result.export.gestures.windowMoveFingerCount, .four)
        XCTAssertEqual(result.export.gestures.windowResizeEnabled, false)
        XCTAssertEqual(result.export.gestures.windowResizeFingerCount, .three)
        XCTAssertEqual(result.export.gestures.windowMoveSensitivity, 2)
        XCTAssertEqual(result.export.gestures.windowGestureSensitivity, 1)
        XCTAssertEqual(try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(result.export)), result.export)
    }

    func testEachOmittedWindowSpeedUsesItsOwnDefault() throws {
        let moveSpeed = 1.75
        let resizeSpeed = 3.25
        var export = SettingsExport.defaults()
        export.gestures.windowMoveSensitivity = moveSpeed
        export.gestures.windowGestureSensitivity = resizeSpeed
        let toml = String(decoding: try SettingsTOMLCodec.encode(export), as: UTF8.self)
        for (omitted, expectedMove, expectedResize) in [
            ("windowMoveSensitivity", 2.0, resizeSpeed), ("windowGestureSensitivity", moveSpeed, 1.0)
        ] {
            let remaining = toml.components(separatedBy: "\n").filter { !$0.hasPrefix("\(omitted) = ") }
            let data = Data(remaining.joined(separator: "\n").utf8)
            let result = try SettingsTOMLCodec.decodeForLoad(data)
            XCTAssertNil(result.migration)
            XCTAssertTrue(SettingsTOMLCodec.unknownKeyPaths(in: data).isEmpty)
            XCTAssertEqual(result.export.gestures.windowMoveSensitivity, expectedMove)
            XCTAssertEqual(result.export.gestures.windowGestureSensitivity, expectedResize)
        }
    }

    func testWindowGestureSettingsRoundTripEverySupportedFingerCount() throws {
        for count in GestureFingerCount.allCases {
            var export = SettingsExport.defaults()
            export.gestures.windowMoveEnabled = true
            export.gestures.windowMoveFingerCount = count
            export.gestures.windowResizeEnabled = true
            export.gestures.windowResizeFingerCount = count
            export.gestures.windowMoveSensitivity = 1.75
            export.gestures.windowGestureSensitivity = 2.5

            let encoded = try SettingsTOMLCodec.encode(export)
            XCTAssertEqual(try SettingsTOMLCodec.decode(encoded), export)
            XCTAssertTrue(SettingsTOMLCodec.unknownKeyPaths(in: encoded).isEmpty)
        }
    }

    func testDwindleGroupDragAcrossDisplaysDefaultsToGroupAndRoundTrips() throws {
        XCTAssertEqual(SettingsExport.defaults().gestures.dwindleGroupDragAcrossDisplays, .group)
        for mode in DwindleGroupDrag.allCases {
            var export = SettingsExport.defaults()
            export.gestures.dwindleGroupDragAcrossDisplays = mode
            let encoded = try SettingsTOMLCodec.encode(export)
            XCTAssertTrue(
                String(decoding: encoded, as: UTF8.self)
                    .contains("dwindleGroupDragAcrossDisplays = \"\(mode.rawValue)\"")
            )
            XCTAssertEqual(try SettingsTOMLCodec.decode(encoded), export)
            XCTAssertTrue(SettingsTOMLCodec.unknownKeyPaths(in: encoded).isEmpty)
        }

        let canonical = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let omitted = Data(canonical.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("dwindleGroupDragAcrossDisplays") }
            .joined(separator: "\n").utf8)
        let result = try SettingsTOMLCodec.decodeForLoad(omitted)
        XCTAssertNil(result.migration)
        XCTAssertEqual(result.export.gestures.dwindleGroupDragAcrossDisplays, .group)
        XCTAssertThrowsError(try SettingsTOMLCodec.decode(replacingDefault(
            "dwindleGroupDragAcrossDisplays",
            with: "\"tile\""
        )))
    }

    func testMalformedWindowGestureValuesRejectDecode() throws {
        for (key, values) in [
            ("windowMoveEnabled", ["1", "\"true\""]),
            ("windowResizeEnabled", ["1", "\"false\""]),
            ("windowMoveFingerCount", ["1", "5", "true", "\"four\""]),
            ("windowResizeFingerCount", ["1", "5", "false", "\"three\""]),
            ("windowMoveSensitivity", ["true", "\"fast\""]),
            ("windowGestureSensitivity", ["true", "\"fast\""])
        ] {
            for value in values {
                let data = try replacingDefault(key, with: value)
                XCTAssertThrowsError(try SettingsTOMLCodec.decode(data), "\(key) = \(value)")
            }
        }
    }

    @MainActor
    func testWindowOnlyLoadDoesNotEnumerateMonitors() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var export = SettingsExport.defaults()
        export.gestures.scrollEnabled = false
        export.gestures.windowMoveEnabled = true
        export.gestures.windowResizeEnabled = true
        let url = directory.appendingPathComponent(SettingsFilePersistence.fileName)
        let data = try SettingsTOMLCodec.encode(export)
        try data.write(to: url)
        var monitorCalls = 0
        let persistence = SettingsFilePersistence(
            directory: directory, startWatching: false, deferSaves: false,
            monitorProvider: {
                monitorCalls += 1
                return []
            }
        )

        XCTAssertEqual(persistence.loadOutcome().export, export)
        XCTAssertEqual(monitorCalls, 0)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    @MainActor
    func testConflictingWindowReloadPreservesLiveStateAndAcceptsRepair() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(SettingsFilePersistence.fileName)
        var initial = SettingsExport.defaults()
        initial.gestures.scrollEnabled = false
        try SettingsTOMLCodec.encode(initial).write(to: url)
        let persistence = SettingsFilePersistence(
            directory: directory, startWatching: false, deferSaves: false, monitorProvider: { [] }
        )
        let settings = SettingsStore(
            persistence: persistence,
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false),
            autosaveEnabled: true
        )
        let before = settings.toExport()
        var availability: [Bool] = []
        var externalReloads = 0
        settings.onTrackpadGestureAvailabilityChanged = { availability.append($0) }
        settings.onExternalSettingsReloaded = { externalReloads += 1 }
        var candidate = before
        candidate.gestures.windowMoveEnabled = true
        candidate.gestures.windowResizeEnabled = true
        candidate.gestures.windowResizeFingerCount = .four
        candidate.gestures.windowMoveSensitivity = 1.75
        candidate.gestures.windowGestureSensitivity = 3.25
        candidate.gaps.size = before.gaps.size + 5
        let rejectedData = try SettingsTOMLCodec.encode(candidate)
        try rejectedData.write(to: url, options: .atomic)

        persistence.handlePossibleSettingsFileChange()

        XCTAssertEqual(settings.toExport(), before)
        XCTAssertTrue(availability.isEmpty)
        XCTAssertEqual(externalReloads, 0)
        guard case .invalidRejected = settings.configNotice else {
            return XCTFail("Expected window gesture conflict to reject reload")
        }
        XCTAssertEqual(try Data(contentsOf: url), rejectedData)
        candidate.gestures.windowResizeFingerCount = .three
        let repairedData = try SettingsTOMLCodec.encode(candidate)
        try repairedData.write(to: url, options: .atomic)

        persistence.handlePossibleSettingsFileChange()

        XCTAssertEqual(settings.toExport(), candidate)
        XCTAssertEqual(availability, [true])
        XCTAssertEqual(externalReloads, 1)
        XCTAssertNil(settings.configNotice)
        XCTAssertEqual(try Data(contentsOf: url), repairedData)
    }

    private func replacingDefault(_ key: String, with value: String) throws -> Data {
        let canonical = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        return Data(canonical.components(separatedBy: "\n")
            .map { $0.hasPrefix("\(key) = ") ? "\(key) = \(value)" : $0 }
            .joined(separator: "\n").utf8)
    }
}
