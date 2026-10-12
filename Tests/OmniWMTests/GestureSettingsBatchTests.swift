// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class GestureSettingsBatchTests: XCTestCase {
    func testReplacingOnlyActiveGesturePublishesCompleteStateWithoutAvailabilityTransition() {
        for startsWithColumns in [true, false] {
            withSettings { settings in
                settings.gestures.scrollEnabled = startsWithColumns
                settings.gestures.windowMoveEnabled = !startsWithColumns
                settings.gestures.windowMoveFingerCount = .three
                var candidate = settings.gestures.export()
                candidate.scrollEnabled = !startsWithColumns
                candidate.windowMoveEnabled = startsWithColumns
                candidate.windowGestureSensitivity = 2.5
                var published: [SettingsExport.Gestures] = []
                var availability: [Bool] = []
                let originalOnChange = settings.gestures.onChange
                settings.gestures.onChange = {
                    published.append(settings.gestures.export())
                    originalOnChange?()
                }
                settings.onTrackpadGestureAvailabilityChanged = { availability.append($0) }

                XCTAssertNil(settings.updateGestureSettings(candidate, monitors: []))

                XCTAssertEqual(published, [candidate])
                XCTAssertTrue(availability.isEmpty)
                XCTAssertTrue(settings.effectiveTrackpadGesturesEnabled)
                settings.gestures.onChange = nil
            }
        }
    }

    func testAvailabilityCallbacksSeeFinalStateOnlyWhenAggregateChanges() {
        withSettings { settings in
            let gestures = settings.gestures
            var candidate = gestures.export()
            var availability: [Bool] = []
            var availabilitySnapshots: [SettingsExport.Gestures] = []
            var changes = 0
            let originalOnChange = gestures.onChange
            gestures.onChange = {
                changes += 1
                originalOnChange?()
            }
            settings.onTrackpadGestureAvailabilityChanged = {
                availability.append($0)
                availabilitySnapshots.append(gestures.export())
            }

            candidate.scrollEnabled = false
            candidate.windowGestureSensitivity = 2
            gestures.apply(candidate)
            let disabled = candidate

            candidate.windowResizeEnabled = true
            candidate.windowResizeFingerCount = .four
            candidate.windowGestureSensitivity = 3
            gestures.apply(candidate)
            let enabled = candidate

            candidate.windowResizeEnabled = false
            candidate.windowGestureSensitivity = 4
            gestures.apply(candidate)

            XCTAssertEqual(availability, [false, true, false])
            XCTAssertEqual(availabilitySnapshots, [disabled, enabled, candidate])
            XCTAssertEqual(changes, 3)
        }
    }

    func testNoOpAndEquivalentNormalizedApplicationsPublishNothing() {
        withSettings { settings in
            let gestures = settings.gestures
            var changes = 0
            var availability: [Bool] = []
            let originalOnChange = gestures.onChange
            gestures.onChange = {
                changes += 1
                originalOnChange?()
            }
            settings.onTrackpadGestureAvailabilityChanged = { availability.append($0) }

            gestures.apply(gestures.export())
            var equivalent = gestures.export()
            equivalent.overviewGestureEnabled = nil
            equivalent.overviewGestureFingerCount = nil
            equivalent.windowMoveEnabled = nil
            equivalent.windowMoveFingerCount = nil
            equivalent.windowResizeEnabled = nil
            equivalent.windowResizeFingerCount = nil
            equivalent.windowGestureSensitivity = .infinity
            equivalent.scrollSensitivity = .nan
            gestures.apply(equivalent)

            XCTAssertEqual(changes, 0)
            XCTAssertTrue(availability.isEmpty)
        }
    }

    func testRejectedAssignmentPublishesNothing() {
        withSettings { settings in
            let original = settings.gestures.export()
            var candidate = original
            candidate.windowMoveEnabled = true
            candidate.windowMoveFingerCount = GestureFingerCount(rawValue: candidate.fingerCount.rawValue)
            var changes = 0
            var availability: [Bool] = []
            let originalOnChange = settings.gestures.onChange
            settings.gestures.onChange = {
                changes += 1
                originalOnChange?()
            }
            settings.onTrackpadGestureAvailabilityChanged = { availability.append($0) }

            XCTAssertNotNil(settings.updateGestureSettings(candidate, monitors: []))

            XCTAssertEqual(settings.gestures.export(), original)
            XCTAssertEqual(changes, 0)
            XCTAssertTrue(availability.isEmpty)
        }
    }

    func testDirectEditsStillPublishImmediatelyAfterAnApplication() {
        withSettings { settings in
            let gestures = settings.gestures
            gestures.apply(gestures.export())
            var changes = 0
            var availability: [Bool] = []
            let originalOnChange = gestures.onChange
            gestures.onChange = {
                changes += 1
                originalOnChange?()
            }
            settings.onTrackpadGestureAvailabilityChanged = { availability.append($0) }

            gestures.scrollEnabled = false
            gestures.windowResizeFingerCount = .four
            gestures.windowResizeEnabled = true
            gestures.windowResizeEnabled = true

            XCTAssertEqual(changes, 3)
            XCTAssertEqual(availability, [false, true])
        }
    }

    func testWholeExportStillPublishesOneAggregateAvailabilityChange() {
        withSettings { settings in
            var export = settings.toExport()
            export.gestures.scrollEnabled = false
            export.gestures.windowMoveEnabled = true
            var availability: [Bool] = []
            settings.onTrackpadGestureAvailabilityChanged = { availability.append($0) }

            settings.applyExport(export)
            XCTAssertTrue(availability.isEmpty)

            export.gestures.windowMoveEnabled = false
            settings.applyExport(export)
            XCTAssertEqual(availability, [false])

            export.gestures.windowResizeEnabled = true
            settings.applyExport(export)
            XCTAssertEqual(availability, [false, true])
        }
    }

    func testOverviewSwitchChangesEffectiveAvailabilityWhileOtherGesturesRemainUsable() {
        withSettings { settings in
            settings.gestures.scrollEnabled = false
            settings.gestures.overviewGestureEnabled = true
            var availability: [Bool] = []
            settings.onTrackpadGestureAvailabilityChanged = { availability.append($0) }

            settings.overview.enabled = false
            XCTAssertFalse(settings.effectiveTrackpadGesturesEnabled)
            settings.gestures.windowMoveEnabled = true
            XCTAssertTrue(settings.effectiveTrackpadGesturesEnabled)
            settings.gestures.windowMoveEnabled = false
            XCTAssertFalse(settings.effectiveTrackpadGesturesEnabled)
            settings.overview.enabled = true

            XCTAssertTrue(settings.effectiveTrackpadGesturesEnabled)
            XCTAssertEqual(availability, [false, true, false, true])
        }
    }

    func testWholeExportBatchesOverviewAndGestureAvailability() {
        withSettings { settings in
            var export = settings.toExport()
            export.gestures.scrollEnabled = false
            export.gestures.overviewGestureEnabled = true
            export.overview.enabled = false
            var availability: [Bool] = []
            settings.onTrackpadGestureAvailabilityChanged = { availability.append($0) }

            settings.applyExport(export)

            XCTAssertFalse(settings.effectiveTrackpadGesturesEnabled)
            XCTAssertEqual(availability, [false])
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
