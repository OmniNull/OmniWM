// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class GestureAssignmentEditorTests: XCTestCase {
    func testFingerChoicesKeepColumnsAndOverviewOffTwoFingers() {
        for action in GestureAssignmentAction.allCases {
            XCTAssertEqual(
                action.supportedFingerCounts,
                action == .columns || action == .overview ? [3, 4] : [2, 3, 4]
            )
        }
    }

    func testDisabledGestureCanChangeFingersBeforeEnabling() {
        withSettings { settings in
            settings.gestures.overviewGestureEnabled = true
            let editor = GestureAssignmentEditor()
            XCTAssertNotNil(GestureAssignmentEditor.conflict(enabling: .move, settings: settings, monitors: []))

            editor.submit(.init(action: .move, change: .fingers(2)), settings: settings, monitors: [])

            XCTAssertEqual(settings.gestures.windowMoveFingerCount, .two)
            XCTAssertFalse(settings.gestures.windowMoveEnabled)
            XCTAssertNil(editor.proposal)
            XCTAssertNil(GestureAssignmentEditor.conflict(enabling: .move, settings: settings, monitors: []))

            editor.submit(.init(action: .move, change: .enabled(true)), settings: settings, monitors: [])
            XCTAssertTrue(settings.gestures.windowMoveEnabled)
            XCTAssertNil(editor.proposal)
        }
    }

    func testRejectedEditAndCancelLeaveSettingsAndCallbacksUntouched() {
        withSettings { settings in
            settings.gestures.overviewGestureEnabled = true
            let original = settings.gestures.export()
            var changes = 0
            settings.gestures.onChange = { changes += 1 }
            let editor = GestureAssignmentEditor()

            editor.submit(.init(action: .move, change: .enabled(true)), settings: settings, monitors: [])

            XCTAssertEqual(settings.gestures.export(), original)
            XCTAssertEqual(editor.proposal?.resolutions.map(\.disabledActions), [[.overview]])
            XCTAssertEqual(changes, 0)

            editor.cancel()
            XCTAssertNil(editor.proposal)
            XCTAssertEqual(settings.gestures.export(), original)
            XCTAssertEqual(changes, 0)
        }
    }

    func testMultipleBlockersAreAllIncludedAndMouseWheelConsequenceIsExplicit() {
        withSettings { settings in
            settings.gestures.workspaceSwipeEnabled = true
            settings.gestures.windowMoveFingerCount = .three
            let monitors = [makeMonitor(orientation: .horizontal)]
            let editor = GestureAssignmentEditor()
            let edit = GestureAssignmentEdit(action: .move, change: .enabled(true))

            editor.submit(edit, settings: settings, monitors: monitors)

            XCTAssertEqual(editor.proposal?.resolutions.count, 1)
            guard let resolution = editor.proposal?.resolutions.first else {
                return XCTFail("Expected a guided replacement")
            }
            XCTAssertEqual(resolution.disabledActions, [.columns, .workspaces])
            XCTAssertTrue(resolution.disablesMouseWheelScrolling)
            XCTAssertEqual(
                resolution.title(for: edit),
                "Turn off Scroll columns and Switch workspaces and enable Move windows"
            )
            editor.confirm(resolution, settings: settings, monitors: monitors)
            XCTAssertTrue(settings.gestures.windowMoveEnabled)
            XCTAssertFalse(settings.gestures.scrollEnabled)
            XCTAssertFalse(settings.gestures.workspaceSwipeEnabled)
            XCTAssertNil(editor.proposal)
        }
    }

    func testIndirectWorkspaceAxisConflictOffersBothMinimalChoices() {
        withSettings { settings in
            configureIndirectConflict(settings)
            let monitors = [makeMonitor(orientation: .horizontal)]
            let original = settings.gestures.export()
            let editor = GestureAssignmentEditor()

            editor.submit(.init(action: .columns, change: .enabled(true)), settings: settings, monitors: monitors)

            XCTAssertEqual(editor.proposal?.resolutions.map(\.disabledActions), [[.workspaces], [.overview]])
            XCTAssertEqual(settings.gestures.export(), original)
            guard let resolution = editor.proposal?.resolutions.first(where: { $0.disabledActions == [.overview] })
            else {
                return XCTFail("Expected the Overview replacement choice")
            }
            editor.confirm(resolution, settings: settings, monitors: monitors)
            XCTAssertTrue(settings.gestures.scrollEnabled)
            XCTAssertTrue(settings.gestures.workspaceSwipeEnabled)
            XCTAssertFalse(settings.gestures.overviewGestureEnabled)
            XCTAssertEqual(settings.gestures.workspaceSwipeAxis, .horizontal)
        }
    }

    func testHorizontalColumnAndOverviewSharingAppliesImmediately() {
        withSettings { settings in
            settings.gestures.fingerCount = .four
            let monitors = [makeMonitor(orientation: .horizontal)]
            let editor = GestureAssignmentEditor()

            XCTAssertNil(GestureAssignmentEditor.conflict(enabling: .overview, settings: settings, monitors: monitors))
            editor.submit(.init(action: .overview, change: .enabled(true)), settings: settings, monitors: monitors)

            XCTAssertTrue(settings.gestures.scrollEnabled)
            XCTAssertTrue(settings.gestures.overviewGestureEnabled)
            XCTAssertNil(editor.proposal)
        }
    }

    func testMonitorOverrideChangesAvailabilityAndMinimalResolution() {
        withSettings { settings in
            configureIndirectConflict(settings)
            let monitor = makeMonitor(orientation: .horizontal)
            settings.monitors.updateOrientationSettings(
                MonitorOrientationSettings(monitorName: monitor.name, orientation: .vertical),
                for: monitor
            )
            let editor = GestureAssignmentEditor()

            editor.submit(.init(action: .columns, change: .enabled(true)), settings: settings, monitors: [monitor])

            XCTAssertEqual(editor.proposal?.resolutions.map(\.disabledActions), [[.overview]])
            XCTAssertFalse(settings.gestures.scrollEnabled)
        }
    }

    func testConfirmedFingerEditPreservesRequestedValueAndUnrelatedFields() {
        withSettings { settings in
            settings.gestures.scrollEnabled = false
            settings.gestures.windowMoveEnabled = true
            settings.gestures.windowMoveFingerCount = .two
            settings.gestures.overviewGestureEnabled = true
            settings.gestures.windowGestureSensitivity = 2.4
            settings.gestures.invertDirection = true
            let original = settings.gestures.export()
            let editor = GestureAssignmentEditor()
            let edit = GestureAssignmentEdit(action: .move, change: .fingers(4))

            editor.submit(edit, settings: settings, monitors: [])

            XCTAssertEqual(settings.gestures.export(), original)
            XCTAssertEqual(editor.proposal?.edit, edit)
            guard let resolution = editor.proposal?.resolutions.first else {
                return XCTFail("Expected a finger reassignment proposal")
            }
            editor.confirm(resolution, settings: settings, monitors: [])
            var expected = original
            expected.windowMoveFingerCount = .four
            expected.overviewGestureEnabled = false
            XCTAssertEqual(settings.gestures.export(), expected)
        }
    }

    func testAxisEditUsesValidationAndRetainsOriginalUntilConfirmed() {
        withSettings { settings in
            settings.gestures.scrollEnabled = false
            settings.gestures.workspaceSwipeEnabled = true
            settings.gestures.workspaceSwipeFingerCount = .four
            settings.gestures.workspaceSwipeAxis = .horizontal
            settings.gestures.overviewGestureEnabled = true
            let editor = GestureAssignmentEditor()

            editor.submit(
                .init(action: .workspaces, change: .workspaceAxis(.vertical)),
                settings: settings,
                monitors: []
            )

            XCTAssertEqual(settings.gestures.workspaceSwipeAxis, .horizontal)
            XCTAssertEqual(editor.proposal?.resolutions.map(\.disabledActions), [[.overview]])
            guard let resolution = editor.proposal?.resolutions.first else {
                return XCTFail("Expected a direction proposal")
            }
            editor.confirm(resolution, settings: settings, monitors: [])
            XCTAssertEqual(settings.gestures.workspaceSwipeAxis, .vertical)
            XCTAssertFalse(settings.gestures.overviewGestureEnabled)
        }
    }

    func testStaleConfirmationRefreshesBeforeApplyingAndPreservesLatestSettings() {
        withSettings { settings in
            settings.gestures.overviewGestureEnabled = true
            let editor = GestureAssignmentEditor()
            editor.submit(.init(action: .move, change: .enabled(true)), settings: settings, monitors: [])
            guard let resolution = editor.proposal?.resolutions.first else {
                return XCTFail("Expected a replacement proposal")
            }
            settings.gestures.windowGestureSensitivity = 3.2
            settings.gestures.windowMoveFingerCount = .two

            editor.confirm(resolution, settings: settings, monitors: [])

            XCTAssertFalse(settings.gestures.windowMoveEnabled)
            XCTAssertTrue(settings.gestures.overviewGestureEnabled)
            XCTAssertEqual(editor.proposal?.refreshed, true)
            XCTAssertNil(editor.proposal?.conflict)
            XCTAssertEqual(editor.proposal?.resolutions.map(\.disabledActions), [[]])
            guard let refreshedResolution = editor.proposal?.resolutions.first else {
                return XCTFail("Expected an explicit apply choice")
            }
            editor.confirm(refreshedResolution, settings: settings, monitors: [])
            XCTAssertTrue(settings.gestures.windowMoveEnabled)
            XCTAssertTrue(settings.gestures.overviewGestureEnabled)
            XCTAssertEqual(settings.gestures.windowMoveFingerCount, .two)
            XCTAssertEqual(settings.gestures.windowGestureSensitivity, 3.2)
            XCTAssertNil(editor.proposal)
        }
    }

    func testChangedMonitorContextRequiresFreshConfirmation() {
        withSettings { settings in
            settings.gestures.fingerCount = .four
            let editor = GestureAssignmentEditor()
            editor.submit(
                .init(action: .overview, change: .enabled(true)),
                settings: settings,
                monitors: [makeMonitor(orientation: .vertical)]
            )
            guard let resolution = editor.proposal?.resolutions.first else {
                return XCTFail("Expected a replacement proposal")
            }

            editor.confirm(resolution, settings: settings, monitors: [makeMonitor(orientation: .horizontal)])

            XCTAssertFalse(settings.gestures.overviewGestureEnabled)
            XCTAssertTrue(settings.gestures.scrollEnabled)
            XCTAssertEqual(editor.proposal?.refreshed, true)
            XCTAssertEqual(editor.proposal?.resolutions.map(\.disabledActions), [[]])
        }
    }

    func testRefreshAfterOverrideChangeDoesNotApplyNowValidProposal() {
        withSettings { settings in
            settings.gestures.fingerCount = .four
            let monitor = makeMonitor(orientation: .vertical)
            let editor = GestureAssignmentEditor()
            editor.submit(.init(action: .overview, change: .enabled(true)), settings: settings, monitors: [monitor])
            editor.refresh(settings: settings, monitors: [monitor])
            XCTAssertEqual(editor.proposal?.refreshed, false)
            settings.monitors.updateOrientationSettings(
                MonitorOrientationSettings(monitorName: monitor.name, orientation: .horizontal),
                for: monitor
            )

            editor.refresh(settings: settings, monitors: [monitor])

            XCTAssertFalse(settings.gestures.overviewGestureEnabled)
            XCTAssertTrue(settings.gestures.scrollEnabled)
            XCTAssertEqual(editor.proposal?.refreshed, true)
            XCTAssertNil(editor.proposal?.conflict)
            XCTAssertEqual(editor.proposal?.resolutions.map(\.disabledActions), [[]])
        }
    }

    func testNewSubmissionReplacesPendingEditAndDisableOnlyRecoveryRemainsAvailable() {
        withSettings { settings in
            settings.gestures.windowMoveEnabled = true
            settings.gestures.windowMoveFingerCount = .three
            settings.gestures.overviewGestureEnabled = true
            settings.gestures.overviewGestureFingerCount = .three
            let monitors = [makeMonitor(orientation: .vertical)]
            let editor = GestureAssignmentEditor()
            editor.submit(.init(action: .resize, change: .enabled(true)), settings: settings, monitors: monitors)
            XCTAssertEqual(editor.proposal?.edit.action, .resize)

            editor.submit(.init(action: .move, change: .enabled(false)), settings: settings, monitors: monitors)

            XCTAssertFalse(settings.gestures.windowMoveEnabled)
            XCTAssertFalse(settings.gestures.windowResizeEnabled)
            XCTAssertNil(editor.proposal)
            XCTAssertNotNil(GestureSettingsValidation.conflict(
                gestures: settings.gestures.export(), orientationOverrides: [], monitors: monitors
            ))
        }
    }

    private func configureIndirectConflict(_ settings: SettingsStore) {
        settings.gestures.scrollEnabled = false
        settings.gestures.fingerCount = .four
        settings.gestures.workspaceSwipeEnabled = true
        settings.gestures.workspaceSwipeFingerCount = .four
        settings.gestures.workspaceSwipeAxis = .horizontal
        settings.gestures.overviewGestureEnabled = true
        settings.gestures.overviewGestureFingerCount = .four
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

    private func makeMonitor(orientation: Monitor.Orientation) -> Monitor {
        let frame = CGRect(
            x: 0, y: 0,
            width: orientation == .horizontal ? 1920 : 1080,
            height: orientation == .horizontal ? 1080 : 1920
        )
        return Monitor(
            id: .init(displayId: 1), displayId: 1, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Display"
        )
    }
}
