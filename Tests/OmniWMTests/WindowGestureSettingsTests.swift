// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WindowGestureSettingsTests: XCTestCase {
    func testEveryWindowGestureConflictRejectsSettingsWithoutNotifications() {
        for mode in [TrackpadGestureMode.windowMove, .windowResize] {
            for other in [
                TrackpadGestureMode.windowMove,
                .windowResize,
                .columnScroll,
                .workspaceSwitch(axis: .horizontal),
                .workspaceSwitch(axis: .vertical),
                .overview(.open)
            ]
                where mode != other
            {
                withSettings { settings in
                    settings.gestures.scrollEnabled = false
                    var original = settings.gestures.export()
                    enable(other, in: &original)
                    settings.gestures.apply(original)
                    var candidate = original
                    enable(mode, in: &candidate)
                    var changes = 0
                    var availability: [Bool] = []
                    settings.gestures.onChange = { changes += 1 }
                    settings.onTrackpadGestureAvailabilityChanged = { availability.append($0) }

                    let conflict = settings.updateGestureSettings(candidate, monitors: [])

                    XCTAssertNotNil(conflict, "\(mode) / \(other)")
                    XCTAssertEqual(conflict?.fingerCount, 4)
                    XCTAssertEqual(settings.gestures.export(), original)
                    XCTAssertEqual(changes, 0)
                    XCTAssertTrue(availability.isEmpty)
                }
            }
        }
    }

    func testFingerReassignmentRejectsConflictAndAcceptsUnusedCount() {
        withSettings { settings in
            settings.gestures.scrollEnabled = false
            settings.gestures.windowMoveEnabled = true
            settings.gestures.windowResizeEnabled = true
            var candidate = settings.gestures.export()
            candidate.windowMoveFingerCount = .three

            XCTAssertNotNil(settings.updateGestureSettings(candidate, monitors: []))
            XCTAssertEqual(settings.gestures.windowMoveFingerCount, .four)

            candidate.windowMoveFingerCount = .two
            XCTAssertNil(settings.updateGestureSettings(candidate, monitors: []))
            XCTAssertEqual(settings.gestures.windowMoveFingerCount, .two)
        }
    }

    func testDisableOnlyEditCanResolveMultipleConflictsIncrementally() {
        withSettings { settings in
            settings.gestures.windowMoveEnabled = true
            settings.gestures.windowMoveFingerCount = .three
            settings.gestures.windowResizeEnabled = true
            settings.gestures.overviewGestureEnabled = true
            settings.gestures.overviewGestureFingerCount = .three
            var candidate = settings.gestures.export()
            candidate.windowMoveEnabled = false

            XCTAssertNil(settings.updateGestureSettings(candidate, monitors: []))
            XCTAssertFalse(settings.gestures.windowMoveEnabled)
            XCTAssertNotNil(GestureSettingsValidation.conflict(
                gestures: settings.gestures.export(), orientationOverrides: [], monitors: []
            ))

            candidate.windowResizeEnabled = false
            XCTAssertNil(settings.updateGestureSettings(candidate, monitors: []))
            XCTAssertFalse(settings.gestures.windowResizeEnabled)
        }
    }

    func testAvailabilityTracksAllEnabledGesturesWithoutDuplicateNotifications() {
        withSettings { settings in
            settings.gestures.scrollEnabled = false
            var states: [Bool] = []
            settings.onTrackpadGestureAvailabilityChanged = { states.append($0) }

            settings.gestures.windowMoveEnabled = true
            settings.gestures.windowMoveEnabled = true
            settings.gestures.windowResizeEnabled = true
            settings.gestures.scrollEnabled = true
            settings.gestures.workspaceSwipeEnabled = true
            settings.gestures.overviewGestureEnabled = true
            settings.gestures.windowMoveEnabled = false
            settings.gestures.scrollEnabled = false
            settings.gestures.workspaceSwipeEnabled = false
            settings.gestures.overviewGestureEnabled = false
            XCTAssertTrue(settings.effectiveTrackpadGesturesEnabled)
            settings.gestures.windowResizeEnabled = false

            XCTAssertFalse(settings.effectiveTrackpadGesturesEnabled)
            XCTAssertEqual(states, [true, false])
        }
    }

    func testExportApplicationBatchesTransitionsAcrossWindowGestures() {
        withSettings { settings in
            var states: [Bool] = []
            settings.onTrackpadGestureAvailabilityChanged = { states.append($0) }
            var export = settings.toExport()
            export.gestures.scrollEnabled = false
            export.gestures.windowMoveEnabled = true
            settings.applyExport(export)
            XCTAssertTrue(states.isEmpty)

            export.gestures.windowMoveEnabled = false
            export.gestures.windowResizeEnabled = true
            settings.applyExport(export)
            XCTAssertTrue(states.isEmpty)

            export.gestures.windowResizeEnabled = false
            settings.applyExport(export)
            XCTAssertEqual(states, [false])
            settings.gestures.windowMoveEnabled = true
            XCTAssertEqual(states, [false, true])
        }
    }

    func testSensitivityNormalizesDirectAssignmentsAndImportedValues() {
        withSettings { settings in
            for (value, expected) in [
                (Double.nan, 1.0),
                (.infinity, 1.0),
                (-.infinity, 1.0),
                (0, 0.1),
                (6, 5.0),
                (2.3, 2.3)
            ] {
                settings.gestures.windowGestureSensitivity = value
                XCTAssertEqual(settings.gestures.windowGestureSensitivity, expected)
                var export = settings.toExport()
                export.gestures.windowGestureSensitivity = value
                settings.applyExport(export)
                XCTAssertEqual(settings.gestures.windowGestureSensitivity, expected)
                XCTAssertEqual(settings.toExport().gestures.windowGestureSensitivity, expected)
            }
        }
    }

    func testAbsentExportValuesApplyWindowDefaults() {
        withSettings { settings in
            var export = settings.toExport()
            export.gestures.windowMoveEnabled = nil
            export.gestures.windowMoveFingerCount = nil
            export.gestures.windowResizeEnabled = nil
            export.gestures.windowResizeFingerCount = nil
            export.gestures.windowGestureSensitivity = nil
            settings.gestures.windowMoveEnabled = true
            settings.gestures.windowResizeEnabled = true
            settings.gestures.windowMoveFingerCount = .two
            settings.gestures.windowResizeFingerCount = .four
            settings.gestures.windowGestureSensitivity = 4

            settings.applyExport(export)

            XCTAssertFalse(settings.gestures.windowMoveEnabled)
            XCTAssertFalse(settings.gestures.windowResizeEnabled)
            XCTAssertEqual(settings.gestures.windowMoveFingerCount, .four)
            XCTAssertEqual(settings.gestures.windowResizeFingerCount, .three)
            XCTAssertEqual(settings.gestures.windowGestureSensitivity, 1)
        }
    }

    private func enable(_ mode: TrackpadGestureMode, in gestures: inout SettingsExport.Gestures) {
        switch mode {
        case .windowMove:
            gestures.windowMoveEnabled = true
            gestures.windowMoveFingerCount = .four
        case .windowResize:
            gestures.windowResizeEnabled = true
            gestures.windowResizeFingerCount = .four
        case .columnScroll:
            gestures.scrollEnabled = true
            gestures.fingerCount = .four
        case let .workspaceSwitch(axis):
            gestures.workspaceSwipeEnabled = true
            gestures.workspaceSwipeFingerCount = .four
            gestures.workspaceSwipeAxis = axis
        case .overview:
            gestures.overviewGestureEnabled = true
            gestures.overviewGestureFingerCount = .four
        }
    }

    private func withSettings(_ body: (SettingsStore) -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false),
            autosaveEnabled: false
        )
        body(settings)
    }
}
