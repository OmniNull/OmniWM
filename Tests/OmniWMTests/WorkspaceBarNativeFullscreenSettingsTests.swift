// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class WorkspaceBarNativeFullscreenSettingsTests: XCTestCase {
    private static let builtInUUID = "11111111-1111-4111-8111-111111111111"
    private static let externalUUID = "22222222-2222-4222-8222-222222222222"

    func testNativeFullscreenVisibilityValuesRoundTrip() throws {
        XCTAssertFalse(SettingsExport.defaults().workspaceBar.hideInNativeFullscreen)
        for (value, line) in [
            (false, "hideInNativeFullscreen = false"),
            (true, "hideInNativeFullscreen = true")
        ] {
            var export = SettingsExport.defaults()
            export.workspaceBar.hideInNativeFullscreen = value
            let data = try SettingsTOMLCodec.encode(export)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(line))
            let decoded = try SettingsTOMLCodec.decode(data)
            XCTAssertEqual(decoded.workspaceBar.hideInNativeFullscreen, value)
        }
    }

    func testMissingRequiredWorkspaceBarKeysRejectDecode() throws {
        let canonical = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        for (key, line) in [
            ("showLabels", "showLabels = true\n"),
            ("hideInNativeFullscreen", "hideInNativeFullscreen = false\n")
        ] {
            XCTAssertTrue(canonical.contains(line), key)
            let withoutKey = canonical.replacingOccurrences(of: line, with: "")
            XCTAssertThrowsError(try SettingsTOMLCodec.decode(Data(withoutKey.utf8))) { error in
                guard case let DecodingError.keyNotFound(actualKey, context) = error else {
                    return XCTFail("expected keyNotFound for \(key), got \(error)")
                }
                XCTAssertEqual(actualKey.stringValue, key)
                XCTAssertEqual(context.codingPath.map(\.stringValue), ["workspaceBar"])
            }
        }
    }

    @MainActor
    func testBarHidesOnlyOnTheDisplayShowingNativeFullscreen() {
        let settings = makeSettingsStore()
        settings.workspaceBar.enabled = true
        let controller = WMController(settings: settings)
        let builtIn = makeMonitor(displayId: 71_001, uuid: Self.builtInUUID, name: "Built-in", originX: 0)
        let external = makeMonitor(displayId: 71_002, uuid: Self.externalUUID, name: "External", originX: 1_440)
        controller.workspaceManager.applyMonitorConfigurationChange([builtIn, external])

        commitTopology(on: controller, fullscreenDisplayUUID: Self.builtInUUID)
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: builtIn))
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: external))

        settings.workspaceBar.hideInNativeFullscreen = true
        XCTAssertFalse(controller.isWorkspaceBarVisible(on: builtIn))
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: external))

        commitTopology(on: controller, fullscreenDisplayUUID: nil)
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: builtIn))
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: external))
    }

    @MainActor
    func testFillModeHidesOnlyTheFullscreenDisplayWithGlobalHideDisabled() {
        let settings = makeSettingsStore()
        settings.workspaceBar.enabled = true
        settings.workspaceBar.notchMode = .fillLeftOfNotch
        XCTAssertFalse(settings.workspaceBar.hideInNativeFullscreen)
        let controller = WMController(settings: settings)
        let builtIn = makeMonitor(displayId: 71_006, uuid: Self.builtInUUID, name: "Built-in", originX: 0)
        let external = makeMonitor(displayId: 71_007, uuid: Self.externalUUID, name: "External", originX: 1_440)
        controller.workspaceManager.applyMonitorConfigurationChange([builtIn, external])

        commitTopology(on: controller, fullscreenDisplayUUID: Self.builtInUUID)
        XCTAssertFalse(controller.isWorkspaceBarVisible(on: builtIn))
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: external))

        settings.workspaceBar.monitorOverrides = [
            MonitorBarSettings(monitorName: builtIn.name, monitorDisplayUUID: Self.builtInUUID, notchMode: .off)
        ]
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: builtIn))

        settings.workspaceBar.monitorOverrides = []
        commitTopology(on: controller, fullscreenDisplayUUID: nil)
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: builtIn))
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: external))
    }

    @MainActor
    func testNativeFullscreenHiddenBarKeepsReservedLayoutSpace() {
        let settings = makeSettingsStore()
        settings.workspaceBar.enabled = true
        settings.workspaceBar.reserveLayoutSpace = true
        settings.workspaceBar.height = 24
        settings.workspaceBar.position = .belowMenuBar
        settings.workspaceBar.hideInNativeFullscreen = true
        let controller = WMController(settings: settings)
        let builtIn = makeMonitor(displayId: 71_003, uuid: Self.builtInUUID, name: "Built-in", originX: 0)
        controller.workspaceManager.applyMonitorConfigurationChange([builtIn])

        commitTopology(on: controller, fullscreenDisplayUUID: nil)
        let reservedWorkingBefore = controller.insetWorkingFrame(for: builtIn)
        let reservedFullscreenBefore = controller.fullscreenLayoutFrame(for: builtIn)
        var reservedFullscreen = builtIn.visibleFrame
        reservedFullscreen.size.height -= CGFloat(settings.workspaceBar.height)
        let clearance = BorderConfig.layoutClearance(
            enabled: settings.borders.enabled, width: CGFloat(settings.borders.width),
            scale: controller.backingScaleFactor(for: builtIn)
        )
        XCTAssertEqual(reservedWorkingBefore, reservedFullscreen.insetBy(dx: clearance, dy: clearance))
        XCTAssertEqual(reservedFullscreenBefore, reservedFullscreen)

        commitTopology(on: controller, fullscreenDisplayUUID: Self.builtInUUID)
        XCTAssertFalse(controller.isWorkspaceBarVisible(on: builtIn))
        XCTAssertEqual(controller.insetWorkingFrame(for: builtIn), reservedWorkingBefore)
        XCTAssertEqual(controller.fullscreenLayoutFrame(for: builtIn), reservedFullscreenBefore)
    }

    @MainActor
    func testUnknownTopologyKeepsTheBarVisible() {
        let settings = makeSettingsStore()
        settings.workspaceBar.enabled = true
        settings.workspaceBar.hideInNativeFullscreen = true
        let controller = WMController(settings: settings)
        let builtIn = makeMonitor(displayId: 71_004, uuid: Self.builtInUUID, name: "Built-in", originX: 0)
        controller.workspaceManager.applyMonitorConfigurationChange([builtIn])

        XCTAssertFalse(controller.workspaceManager.spaceTopology.isPopulated)
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: builtIn))
    }

    @MainActor
    func testRawSkyLightDisplayIdentifiersStillHideTheBar() {
        for rawIdentifier in ["Main", "71005"] {
            let settings = makeSettingsStore()
            settings.workspaceBar.enabled = true
            settings.workspaceBar.hideInNativeFullscreen = true
            let controller = WMController(settings: settings)
            let builtIn = makeMonitor(displayId: 71_005, uuid: Self.builtInUUID, name: "Built-in", originX: 0)
            controller.workspaceManager.applyMonitorConfigurationChange([builtIn])

            controller.workspaceManager.commitSpaceTopology(
                SpaceTopology(
                    displays: [
                        .init(displayIdentifier: rawIdentifier, spaceIds: [1], currentSpaceId: 1)
                    ],
                    activeSpaceId: 1,
                    fullscreenSpaceIds: [1],
                    windowSpace: [:]
                )
            )

            XCTAssertEqual(
                controller.workspaceManager.spaceTopology.isDisplayShowingFullscreenSpace(on: builtIn),
                true,
                "raw identifier \(rawIdentifier) should canonicalize to the monitor UUID"
            )
            XCTAssertFalse(
                controller.isWorkspaceBarVisible(on: builtIn),
                "bar should hide for raw identifier \(rawIdentifier)"
            )
        }
    }

    @MainActor
    private func commitTopology(on controller: WMController, fullscreenDisplayUUID: String?) {
        let spaceIdsByUUID: [String: UInt64] = [Self.builtInUUID: 1, Self.externalUUID: 2]
        let displays = spaceIdsByUUID
            .sorted { $0.key < $1.key }
            .map {
                SpaceTopology.DisplaySpaces(
                    displayIdentifier: $0.key,
                    spaceIds: [$0.value],
                    currentSpaceId: $0.value
                )
            }
        controller.workspaceManager.commitSpaceTopology(
            SpaceTopology(
                displays: displays,
                activeSpaceId: 1,
                fullscreenSpaceIds: fullscreenDisplayUUID.flatMap { spaceIdsByUUID[$0] }.map { [$0] } ?? [],
                windowSpace: [:]
            )
        )
    }

    private func makeMonitor(
        displayId: CGDirectDisplayID,
        uuid: String,
        name: String,
        originX: CGFloat
    ) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: originX, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: originX, y: 0, width: 1_440, height: 860),
            hasNotch: false,
            name: name,
            displayUUID: uuid
        )
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMWorkspaceBarFullscreenTests-\(UUID().uuidString)", isDirectory: true)
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
