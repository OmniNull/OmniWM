// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class MonitorSetupPresentationTests: XCTestCase {
    func testMissingRuntimeStatusDefaultsToNotPresented() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"welcomePresented":true}"#.utf8)
            .write(to: root.appendingPathComponent(RuntimeStateStore.fileName))

        let runtimeState = RuntimeStateStore(directory: root, deferSaves: false)

        XCTAssertEqual(runtimeState.monitorSetupStatus, .notPresented)
    }

    func testRuntimeStatusRoundTripsDismissedAndCompleted() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = RuntimeStateStore(directory: root, deferSaves: false)

        writer.monitorSetupStatus = .dismissed
        XCTAssertEqual(
            RuntimeStateStore(directory: root, deferSaves: false).monitorSetupStatus,
            .dismissed
        )

        writer.monitorSetupStatus = .completed
        XCTAssertEqual(
            RuntimeStateStore(directory: root, deferSaves: false).monitorSetupStatus,
            .completed
        )
    }

    func testSettingsStorePersistsMonitorSetupStatus() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = makeSettingsStore(root: root)

        settings.monitorSetupStatus = .completed

        let reloaded = RuntimeStateStore(
            directory: root.appendingPathComponent("state", isDirectory: true),
            deferSaves: false
        )
        XCTAssertEqual(reloaded.monitorSetupStatus, .completed)
    }

    func testApplyMonitorSetupCommitsRoutingMouseWarpAndWorkspaces() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = makeSettingsStore(root: root)
        let displays = monitors(count: 2)
        let routing = MonitorRouting.seedLayout(from: displays)
        let workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main),
            WorkspaceConfiguration(name: "2", monitorAssignment: .secondary)
        ]
        settings.monitors.routingMode = .macOS
        settings.pointer.enabled = true

        settings.applyMonitorSetup(
            routingSettings: routing,
            monitors: displays,
            mouseWarpEnabled: false,
            workspaceConfigurations: workspaceConfigurations
        )

        XCTAssertEqual(settings.monitors.arrangements.map(\.monitors), [routing])
        XCTAssertEqual(settings.monitors.routingMode, .custom)
        XCTAssertFalse(settings.pointer.enabled)
        XCTAssertEqual(settings.workspaces.configurations, workspaceConfigurations)
    }

    func testApplyMonitorSetupCreatesExactSubsetWithoutChangingLargerArrangement() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = makeSettingsStore(root: root)
        let displays = monitors(count: 3)
        let fullRouting = MonitorRouting.seedLayout(from: displays)
        settings.applyMonitorSetup(
            routingSettings: fullRouting,
            monitors: displays,
            mouseWarpEnabled: true,
            workspaceConfigurations: []
        )
        let original = try XCTUnwrap(settings.monitors.arrangements.first)
        let connected = Array(displays.prefix(2))
        var subsetRouting = MonitorRouting.seedLayout(from: connected)
        subsetRouting[1].gridColumn = 0
        subsetRouting[1].gridRow = 1

        settings.applyMonitorSetup(
            routingSettings: subsetRouting,
            monitors: connected,
            mouseWarpEnabled: true,
            workspaceConfigurations: []
        )

        XCTAssertEqual(settings.monitors.arrangements.count, 2)
        XCTAssertEqual(settings.monitors.arrangements[0], original)
        XCTAssertEqual(settings.monitors.arrangements[1].monitors, subsetRouting)
        XCTAssertNotEqual(settings.monitors.arrangements[1].id, original.id)

        let subsetID = settings.monitors.arrangements[1].id
        let resetRouting = MonitorRouting.seedLayout(from: connected)
        settings.applyMonitorSetup(
            routingSettings: resetRouting,
            monitors: connected,
            mouseWarpEnabled: false,
            workspaceConfigurations: []
        )

        XCTAssertEqual(settings.monitors.arrangements.count, 2)
        XCTAssertEqual(settings.monitors.arrangements[0], original)
        XCTAssertEqual(settings.monitors.arrangements[1].id, subsetID)
        XCTAssertEqual(settings.monitors.arrangements[1].monitors, resetRouting)
        XCTAssertFalse(settings.pointer.enabled)
    }

    func testNavigationRequestIsConsumedOnceAndSelectsMonitors() {
        let navigation = SettingsNavigationModel()

        navigation.requestMonitorSetupPresentation()

        XCTAssertEqual(navigation.section, .monitors)
        XCTAssertTrue(navigation.hasPendingMonitorSetupPresentation)
        XCTAssertTrue(navigation.consumeMonitorSetupPresentationRequest())
        XCTAssertFalse(navigation.hasPendingMonitorSetupPresentation)
        XCTAssertFalse(navigation.consumeMonitorSetupPresentationRequest())
    }

    func testAutomaticPresentationPolicyMatrix() {
        var displays = monitors(count: 2)
        displays[1] = Monitor(
            id: .init(displayId: 2),
            displayId: 2,
            frame: CGRect(x: 0, y: 0, width: 1, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1, height: 900),
            hasNotch: false,
            name: "Display 2"
        )

        let cases: [(
            label: String,
            status: MonitorSetupStatus,
            displays: [Monitor],
            overlayFinished: Bool,
            expected: Bool
        )] = [
            ("overlay pending", .notPresented, monitors(count: 2), false, false),
            ("one display", .notPresented, monitors(count: 1), true, false),
            ("two displays", .notPresented, monitors(count: 2), true, true),
            ("transient width", .notPresented, displays, true, false),
            ("dismissed", .dismissed, monitors(count: 3), true, false),
            ("completed", .completed, monitors(count: 3), true, false)
        ]
        for row in cases {
            XCTAssertEqual(
                MonitorSetupPresentationPolicy.shouldAutomaticallyPresent(
                    status: row.status, monitors: row.displays, launchOverlayFinished: row.overlayFinished
                ),
                row.expected,
                row.label
            )
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMMonitorSetup-\(UUID().uuidString)", isDirectory: true)
    }

    private func monitors(count: Int) -> [Monitor] {
        (0 ..< count).map { index in
            let displayID = CGDirectDisplayID(index + 1)
            let x = CGFloat(index) * 1_000
            return Monitor(
                id: .init(displayId: displayID),
                displayId: displayID,
                frame: CGRect(x: x, y: 0, width: 1_000, height: 900),
                visibleFrame: CGRect(x: x, y: 0, width: 1_000, height: 900),
                hasNotch: false,
                name: "Display \(index + 1)"
            )
        }
    }

    private func makeSettingsStore(root: URL) -> SettingsStore {
        SettingsStore(
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
