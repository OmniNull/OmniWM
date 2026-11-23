// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class OverviewGesturePersistenceTests: XCTestCase {
    @MainActor
    func testAbsentOverviewKeysUseDefaultsWithoutEnumeratingMonitors() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let data = Data("return { gestures = {} }".utf8)
        try data.write(to: fixture.fileURL)
        var monitorCalls = 0
        let persistence = SettingsFilePersistence(
            directory: fixture.directory,
            startWatching: false,
            deferSaves: false,
            monitorProvider: {
                monitorCalls += 1
                return []
            }
        )

        let outcome = persistence.loadOutcome()
        let export = try XCTUnwrap(outcome.export)

        XCTAssertEqual(export.gestures.overviewGestureEnabled, false)
        XCTAssertEqual(export.gestures.overviewGestureFingerCount, .four)
        XCTAssertNil(outcome.notice)
        XCTAssertEqual(monitorCalls, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), data)
        XCTAssertEqual(try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export)), export)
    }

    func testMalformedOverviewTypesAndFingerCountsRejectDecode() throws {
        for (key, replacement) in [
            ("overviewGestureEnabled", "\"true\""),
            ("overviewGestureEnabled", "1"),
            ("overviewGestureFingerCount", "\"four\""),
            ("overviewGestureFingerCount", "true"),
            ("overviewGestureFingerCount", "2"),
            ("overviewGestureFingerCount", "5")
        ] {
            let data = try canonicalData(replacing: [key: replacement])
            XCTAssertThrowsError(try SettingsTOMLCodec.decode(data), "\(key) = \(replacement)")
        }
    }

    @MainActor
    func testInitialLoadAndReloadRejectVerticalColumnAndWorkspaceConflictsWithoutChangingFile() throws {
        let vertical = makeMonitor(vertical: true)
        var workspaceConflict = overviewExport()
        workspaceConflict.gestures.scrollEnabled = false
        workspaceConflict.gestures.workspaceSwipeEnabled = true
        workspaceConflict.gestures.workspaceSwipeFingerCount = .four
        workspaceConflict.gestures.workspaceSwipeAxis = .vertical

        for (export, monitors) in [(overviewExport(), [vertical]), (workspaceConflict, [])] {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let data = try SettingsLuauDocument.initialSource(export)
            try data.write(to: fixture.fileURL)
            let persistence = makePersistence(in: fixture, monitors: monitors)

            let outcome = persistence.loadOutcome()

            XCTAssertNil(outcome.export)
            assertRejected(outcome.notice)
            XCTAssertEqual(try Data(contentsOf: fixture.fileURL), data)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), [
                SettingsFilePersistence.fileName
            ])
            XCTAssertTrue(persistence.settingsWritesBlocked)

            try SettingsLuauDocument.initialSource(.defaults()).write(to: fixture.fileURL, options: .atomic)
            XCTAssertEqual(persistence.loadOutcome().export, .defaults())
            try data.write(to: fixture.fileURL, options: .atomic)

            let reloaded = try XCTUnwrap(persistence.reloadOutcomeIfChanged())

            XCTAssertNil(reloaded.export)
            assertRejected(reloaded.notice)
            XCTAssertEqual(try Data(contentsOf: fixture.fileURL), data)
        }
    }

    @MainActor
    func testInitialLoadUsesCandidateMonitorOrientationOverride() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let monitor = makeMonitor(vertical: false)
        var export = overviewExport()
        export.monitorOrientationSettings = [
            MonitorOrientationSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                orientation: .vertical
            )
        ]
        let data = try SettingsLuauDocument.initialSource(export)
        try data.write(to: fixture.fileURL)
        let persistence = makePersistence(in: fixture, monitors: [monitor])

        let outcome = persistence.loadOutcome()

        XCTAssertNil(outcome.export)
        assertRejected(outcome.notice)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), data)
    }

    @MainActor
    func testInitialLoadAcceptsHorizontalColumnAndUpwardOverviewWithSameFingers() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let export = overviewExport()
        let data = try SettingsLuauDocument.initialSource(export)
        try data.write(to: fixture.fileURL)
        let persistence = makePersistence(in: fixture, monitors: [makeMonitor(vertical: false)])

        let outcome = persistence.loadOutcome()

        XCTAssertEqual(outcome.export, export)
        XCTAssertNil(outcome.notice)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), data)
    }

    @MainActor
    func testConflictingExternalReloadPreservesAllLiveValuesAndCallbacksThenAcceptsRepair() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var initial = SettingsExport.defaults()
        initial.gestures.scrollEnabled = false
        initial.gestures.workspaceSwipeEnabled = false
        initial.gaps.size = 17
        try SettingsLuauDocument.initialSource(initial).write(to: fixture.fileURL)
        let persistence = makePersistence(in: fixture, monitors: [makeMonitor(vertical: true)])
        let settings = SettingsStore(
            persistence: persistence,
            runtimeState: RuntimeStateStore(
                directory: fixture.root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: true
        )
        let liveBefore = settings.toExport()
        var availabilityChanges: [Bool] = []
        var ipcChanges: [Bool] = []
        var externalReloads = 0
        var noticeChanges = 0
        settings.onTrackpadGestureAvailabilityChanged = { availabilityChanges.append($0) }
        settings.onIPCEnabledChanged = { ipcChanges.append($0) }
        settings.onExternalSettingsReloaded = { externalReloads += 1 }
        settings.onConfigNoticeChanged = { noticeChanges += 1 }
        var candidate = overviewExport()
        candidate.gaps.size = 29
        candidate.ipcEnabled = !initial.ipcEnabled
        let rejectedData = try SettingsLuauDocument.initialSource(candidate)
        try rejectedData.write(to: fixture.fileURL, options: .atomic)

        persistence.handlePossibleSettingsFileChange()
        persistence.handlePossibleSettingsFileChange()

        XCTAssertEqual(settings.toExport(), liveBefore)
        assertRejected(settings.configNotice)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), rejectedData)
        XCTAssertTrue(availabilityChanges.isEmpty)
        XCTAssertTrue(ipcChanges.isEmpty)
        XCTAssertEqual(externalReloads, 0)
        XCTAssertEqual(noticeChanges, 1)

        candidate.gestures.fingerCount = .three
        let repairedData = try SettingsLuauDocument.initialSource(candidate)
        try repairedData.write(to: fixture.fileURL, options: .atomic)
        persistence.handlePossibleSettingsFileChange()

        XCTAssertEqual(settings.gaps.size, candidate.gaps.size)
        XCTAssertEqual(settings.ipcEnabled, candidate.ipcEnabled)
        XCTAssertTrue(settings.gestures.overviewGestureEnabled)
        XCTAssertEqual(settings.gestures.fingerCount, .three)
        XCTAssertNil(settings.configNotice)
        XCTAssertEqual(availabilityChanges, [true])
        XCTAssertEqual(ipcChanges, [candidate.ipcEnabled])
        XCTAssertEqual(externalReloads, 1)
        XCTAssertEqual(noticeChanges, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), repairedData)
    }

    private struct Fixture {
        let root: URL
        let directory: URL

        var fileURL: URL {
            directory.appendingPathComponent(SettingsFilePersistence.fileName)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMOverviewGesturePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Fixture(root: root, directory: directory)
    }

    @MainActor
    private func makePersistence(in fixture: Fixture, monitors: [Monitor]) -> SettingsFilePersistence {
        SettingsFilePersistence(
            directory: fixture.directory,
            startWatching: false,
            deferSaves: false,
            monitorProvider: { monitors }
        )
    }

    private func makeMonitor(vertical: Bool) -> Monitor {
        let frame = CGRect(x: 0, y: 0, width: vertical ? 900 : 1440, height: vertical ? 1440 : 900)
        return Monitor(
            id: .init(displayId: 42),
            displayId: 42,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Gesture Test Monitor"
        )
    }

    private func overviewExport() -> SettingsExport {
        var export = SettingsExport.defaults()
        export.gestures.scrollEnabled = true
        export.gestures.fingerCount = .four
        export.gestures.workspaceSwipeEnabled = false
        export.gestures.overviewGestureEnabled = true
        export.gestures.overviewGestureFingerCount = .four
        return export
    }

    private func canonicalData(
        removing keys: Set<String> = [],
        replacing replacements: [String: String] = [:]
    ) throws -> Data {
        let canonical = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let lines = canonical.components(separatedBy: "\n").compactMap { line -> String? in
            guard let key = line.components(separatedBy: " = ").first else { return line }
            if keys.contains(key) { return nil }
            if let replacement = replacements[key] { return "\(key) = \(replacement)" }
            return line
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    private func assertRejected(
        _ notice: SettingsConfigNotice?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let notice, case let .invalidRejected(reason) = notice else {
            return XCTFail("Expected conflicting gestures to reject the settings file", file: file, line: line)
        }
        XCTAssertFalse(reason.isEmpty, file: file, line: line)
    }
}
