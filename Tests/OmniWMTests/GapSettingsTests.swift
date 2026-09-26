// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

final class GapSettingsTests: XCTestCase {
    func testNormalizedTopStrutMeasuresFromPhysicalTop() {
        XCTAssertEqual(normalizedTopStrut(top: 46, menuBarInset: 33, reservedTopInset: 0), 13)
        XCTAssertEqual(normalizedTopStrut(top: 46, menuBarInset: 0, reservedTopInset: 0), 46)
        XCTAssertEqual(normalizedTopStrut(top: 46, menuBarInset: 24, reservedTopInset: 0), 22)
        XCTAssertEqual(normalizedTopStrut(top: 10, menuBarInset: 24, reservedTopInset: 0), 0)
        XCTAssertEqual(normalizedTopStrut(top: 46, menuBarInset: 33, reservedTopInset: 28), 41)
    }

    func testNormalizedTopStrutKeepsTopGapConsistentAcrossDisplays() {
        let frameMaxY: CGFloat = 1000
        let top: CGFloat = 46

        for inset: CGFloat in [0, 24, 33] {
            let visibleFrameMaxY = frameMaxY - inset
            let windowTop = visibleFrameMaxY - normalizedTopStrut(top: top, menuBarInset: inset, reservedTopInset: 0)
            XCTAssertEqual(frameMaxY - windowTop, top)
        }
    }

    func testNormalizedTopStrutNeverPlacesWindowAboveVisibleFrame() {
        for inset: CGFloat in [0, 24, 33, 50] {
            XCTAssertGreaterThanOrEqual(normalizedTopStrut(top: 8, menuBarInset: inset, reservedTopInset: 0), 0)
        }
    }

    func testMonitorGapSettingsDecodePartialLeavesOthersNil() throws {
        let json = Data(#"{"id":"\#(UUID().uuidString)","monitorName":"Built-in","outerGapTop":20}"#.utf8)
        let decoded = try JSONDecoder().decode(MonitorGapSettings.self, from: json)
        XCTAssertEqual(decoded.outerGapTop, 20)
        XCTAssertNil(decoded.innerGap)
        XCTAssertNil(decoded.outerGapLeft)
        XCTAssertNil(decoded.outerGapRight)
        XCTAssertNil(decoded.outerGapBottom)
        XCTAssertNil(decoded.fullscreenUsesOuterGaps)
    }

    func testMonitorGapSettingsRoundTrips() throws {
        let original = MonitorGapSettings(
            monitorName: "Built-in",
            monitorDisplayId: 7,
            innerGap: 6,
            outerGapTop: 20,
            outerGapBottom: 12,
            fullscreenUsesOuterGaps: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MonitorGapSettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMonitorSettingsStoreMatchesUUIDLessRowsByDisplayIdAndName() {
        let byId = MonitorGapSettings(monitorName: "Whatever", monitorDisplayId: 42, outerGapTop: 5)
        let byName = MonitorGapSettings(monitorName: "External", monitorDisplayId: nil, outerGapTop: 9)
        let overrides = [byId, byName]

        let idMonitor = makeMonitor(displayId: 42, name: "Whatever")
        XCTAssertEqual(MonitorSettingsStore.get(for: idMonitor, in: overrides)?.outerGapTop, 5)

        let reusedIdMonitor = makeMonitor(displayId: 42, name: "Renamed")
        XCTAssertNil(MonitorSettingsStore.get(for: reusedIdMonitor, in: overrides))

        let nameMonitor = makeMonitor(displayId: 99, name: "External")
        XCTAssertNil(MonitorSettingsStore.get(for: nameMonitor, in: overrides))

        let unknownMonitor = makeMonitor(displayId: 100, name: "Unknown")
        XCTAssertNil(MonitorSettingsStore.get(for: unknownMonitor, in: overrides))
    }

    @MainActor
    func testResolvedGapSettingsFallsBackToGlobalThenOverride() {
        let settings = makeSettingsStore()
        settings.gaps.outerGapLeft = 12
        settings.gaps.outerGapRight = 12
        settings.gaps.outerGapTop = 46
        settings.gaps.outerGapBottom = 12
        settings.gaps.size = 16
        settings.gaps.fullscreenUsesOuterGaps = true

        let monitor = makeMonitor(displayId: 1, name: "Built-in")

        let globalOnly = settings.gaps.resolved(for: monitor)
        XCTAssertEqual(globalOnly.innerGap, 16)
        XCTAssertEqual(globalOnly.outerGapTop, 46)
        XCTAssertEqual(globalOnly.outerGapLeft, 12)
        XCTAssertTrue(globalOnly.fullscreenUsesOuterGaps)

        settings.gaps.update(
            MonitorGapSettings(
                monitorName: "Built-in",
                monitorDisplayId: 1,
                innerGap: 6,
                outerGapTop: 20,
                fullscreenUsesOuterGaps: false
            ),
            for: monitor
        )

        let resolved = settings.gaps.resolved(for: monitor)
        XCTAssertEqual(resolved.innerGap, 6)
        XCTAssertEqual(resolved.outerGapTop, 20)
        XCTAssertEqual(resolved.outerGapLeft, 12)
        XCTAssertEqual(resolved.outerGapBottom, 12)
        XCTAssertFalse(resolved.fullscreenUsesOuterGaps)
    }

    @MainActor
    func testFullscreenOuterGapPolicyAppliesAndExports() {
        let settings = makeSettingsStore()
        var export = SettingsExport.defaults()
        export.gaps.fullscreenUsesOuterGaps = true

        settings.applyExport(export)

        XCTAssertTrue(settings.gaps.fullscreenUsesOuterGaps)
        XCTAssertTrue(settings.toExport().gaps.fullscreenUsesOuterGaps)
    }

    @MainActor
    func testResolvedInnerGapMatchesRuntimeBoundsAndPreservesExplicitZero() {
        let settings = makeSettingsStore()
        let monitor = makeMonitor(displayId: 1, name: "Built-in")

        settings.gaps.size = 100
        XCTAssertEqual(settings.gaps.resolved(for: monitor).innerGap, 64)

        settings.gaps.update(
            MonitorGapSettings(monitorName: monitor.name, monitorDisplayId: monitor.displayId, innerGap: -10),
            for: monitor
        )
        XCTAssertEqual(settings.gaps.resolved(for: monitor).innerGap, 0)

        settings.gaps.update(
            MonitorGapSettings(monitorName: monitor.name, monitorDisplayId: monitor.displayId, innerGap: 0),
            for: monitor
        )
        XCTAssertEqual(settings.gaps.settings(for: monitor)?.innerGap, 0)
    }

    @MainActor
    func testClearingFinalGapOverrideRemovesMonitorRecord() {
        let settings = makeSettingsStore()
        let monitor = makeMonitor(displayId: 1, name: "Built-in")
        var override = MonitorGapSettings(
            monitorName: monitor.name,
            monitorDisplayId: monitor.displayId,
            innerGap: 6,
            outerGapTop: 20
        )

        settings.gaps.update(override, for: monitor)
        override.innerGap = nil
        settings.gaps.update(override, for: monitor)
        XCTAssertNil(settings.gaps.settings(for: monitor)?.innerGap)
        XCTAssertEqual(settings.gaps.settings(for: monitor)?.outerGapTop, 20)

        override.outerGapTop = nil
        settings.gaps.update(override, for: monitor)
        XCTAssertNil(settings.gaps.settings(for: monitor))
        XCTAssertTrue(settings.toExport().monitorGapSettings.isEmpty)
    }

    @MainActor
    func testExplicitFalseFullscreenGapOverrideIsRetainedUntilReset() {
        let settings = makeSettingsStore()
        let monitor = makeMonitor(displayId: 1, name: "Built-in")
        var override = MonitorGapSettings(
            monitorName: monitor.name,
            monitorDisplayId: monitor.displayId,
            fullscreenUsesOuterGaps: false
        )

        settings.gaps.update(override, for: monitor)

        XCTAssertEqual(settings.gaps.settings(for: monitor)?.fullscreenUsesOuterGaps, false)
        XCTAssertEqual(settings.toExport().monitorGapSettings.count, 1)

        override.fullscreenUsesOuterGaps = nil
        settings.gaps.update(override, for: monitor)

        XCTAssertNil(settings.gaps.settings(for: monitor))
        XCTAssertTrue(settings.toExport().monitorGapSettings.isEmpty)
    }

    @MainActor
    func testApplyingExportDropsEmptyLegacyGapRecords() {
        let settings = makeSettingsStore()
        let monitor = makeMonitor(displayId: 1, name: "Built-in")
        var export = SettingsExport.defaults()
        export.monitorGapSettings = [
            MonitorGapSettings(monitorName: monitor.name, monitorDisplayId: monitor.displayId)
        ]

        settings.applyExport(export)

        XCTAssertNil(settings.gaps.settings(for: monitor))
        XCTAssertTrue(settings.toExport().monitorGapSettings.isEmpty)
    }

    @MainActor
    func testDwindleGeneralGapUsesDisplayOverrideWithoutChangingSpecificGapPrecedence() {
        let settings = makeSettingsStore()
        let monitor = makeMonitor(displayId: 1, name: "Built-in")
        settings.borders.enabled = true
        settings.borders.width = 8
        settings.gaps.size = 16
        settings.dwindle.useGlobalGaps = true
        settings.gaps.update(
            MonitorGapSettings(monitorName: monitor.name, monitorDisplayId: monitor.displayId, innerGap: 24),
            for: monitor
        )

        let generalResolved = settings.dwindle.resolved(for: monitor)
        XCTAssertEqual(generalResolved.innerGap, 24)

        let controller = WMController(settings: settings)
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.dwindleLayoutHandler.enableDwindleLayout()
        controller.dwindleLayoutHandler.withDwindleContext { engine, _ in
            XCTAssertEqual(engine.settings.innerGap, 24)
        }

        settings.dwindle.update(
            MonitorDwindleSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                useGlobalGaps: false,
                innerGap: 6
            ),
            for: monitor
        )
        XCTAssertEqual(settings.dwindle.resolved(for: monitor).innerGap, 6)
        XCTAssertEqual(controller.resolvedDwindleSettings(for: monitor).innerGap, 8)
        controller.dwindleLayoutHandler.withDwindleContext { engine, _ in
            XCTAssertEqual(engine.settings.innerGap, 8)
        }
    }

    @MainActor
    func testDwindleOwnInnerGapClampsToRuntimeBounds() {
        let settings = makeSettingsStore()
        let monitor = makeMonitor(displayId: 1, name: "Built-in")
        settings.dwindle.useGlobalGaps = false
        settings.gaps.size = 100
        XCTAssertEqual(settings.dwindle.resolved(for: monitor).innerGap, 64)

        for (override, expected) in [(100.0, 64.0), (-5.0, 0.0), (12.0, 12.0)] {
            settings.dwindle.update(
                MonitorDwindleSettings(
                    monitorName: monitor.name,
                    monitorDisplayId: monitor.displayId,
                    useGlobalGaps: false,
                    innerGap: override
                ),
                for: monitor
            )
            XCTAssertEqual(settings.dwindle.resolved(for: monitor).innerGap, CGFloat(expected))
        }

        settings.gaps.size = 16
        settings.dwindle.update(
            MonitorDwindleSettings(monitorName: monitor.name, monitorDisplayId: monitor.displayId, useGlobalGaps: true),
            for: monitor
        )
        XCTAssertEqual(settings.dwindle.resolved(for: monitor).innerGap, 16)
    }

    @MainActor
    func testDisplaysQueryProjectsOnlyRequestedResolvedGapSettings() throws {
        let settings = makeSettingsStore()
        let monitor = makeMonitor(displayId: 1, name: "Built-in")
        settings.gaps.fullscreenUsesOuterGaps = true
        settings.gaps.update(
            MonitorGapSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                innerGap: 6,
                fullscreenUsesOuterGaps: false
            ),
            for: monitor
        )
        let controller = WMController(settings: settings)
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let router = IPCQueryRouter(controller: controller, appVersion: nil, sessionToken: "gap-tests")

        XCTAssertTrue(IPCAutomationManifest.displayFieldCatalog.contains("inner-gap"))
        XCTAssertTrue(IPCAutomationManifest.displayFieldCatalog.contains("fullscreen-uses-outer-gaps"))
        let projected = try XCTUnwrap(
            router.displaysResult(
                IPCQueryRequest(
                    name: .displays,
                    fields: ["id", "inner-gap", "fullscreen-uses-outer-gaps"]
                )
            ).displays.first
        )
        XCTAssertEqual(projected.innerGap, 6)
        XCTAssertEqual(projected.fullscreenUsesOuterGaps, false)
        XCTAssertNotNil(projected.id)
        XCTAssertNil(projected.outerGapLeft)

        let omitted = try XCTUnwrap(
            router.displaysResult(IPCQueryRequest(name: .displays, fields: ["id"])).displays.first
        )
        XCTAssertNil(omitted.innerGap)
        XCTAssertNil(omitted.fullscreenUsesOuterGaps)
    }

    @MainActor
    func testNiriLayoutRoutesInnerGapByWorkspaceDisplay() throws {
        try assertLayoutRoutesInnerGapByWorkspaceDisplay(.niri)
    }

    @MainActor
    func testDwindleLayoutRoutesInnerGapByWorkspaceDisplay() throws {
        try assertLayoutRoutesInnerGapByWorkspaceDisplay(.dwindle)
    }

    @MainActor
    private func assertLayoutRoutesInnerGapByWorkspaceDisplay(_ layout: LayoutType) throws {
        let settings = makeSettingsStore()
        settings.borders.enabled = false
        let left = makeMonitor(displayId: 1, name: "Left", originX: 0)
        let right = makeMonitor(displayId: 2, name: "Right", originX: 1440)
        settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: left)),
                layoutType: layout
            ),
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: right)),
                layoutType: layout
            )
        ]
        settings.gaps.update(
            MonitorGapSettings(monitorName: left.name, monitorDisplayId: left.displayId, innerGap: 4),
            for: left
        )
        settings.gaps.update(
            MonitorGapSettings(monitorName: right.name, monitorDisplayId: right.displayId, innerGap: 24),
            for: right
        )
        let controller = WMController(settings: settings)
        controller.workspaceManager.applyMonitorConfigurationChange([left, right])
        controller.workspaceManager.applySettings()
        if layout == .niri {
            controller.niriLayoutHandler.enableNiriLayout()
            controller.syncMonitorsToNiriEngine()
        } else {
            controller.dwindleLayoutHandler.enableDwindleLayout()
        }
        let leftWorkspace = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        let rightWorkspace = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "2"))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(leftWorkspace, on: left.id))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(rightWorkspace, on: right.id))

        let leftTokens = [
            addWindow(pid: 101, windowId: 201, to: leftWorkspace, controller: controller),
            addWindow(pid: 102, windowId: 202, to: leftWorkspace, controller: controller)
        ]
        let rightTokens = [
            addWindow(pid: 103, windowId: 203, to: rightWorkspace, controller: controller),
            addWindow(pid: 104, windowId: 204, to: rightWorkspace, controller: controller)
        ]
        let plans = controller.workspaceManager.withBatchedLayoutBuild {
            if layout == .niri {
                controller.niriLayoutHandler.layoutWithNiriEngine(
                    activeWorkspaces: [leftWorkspace, rightWorkspace]
                )
            } else {
                controller.dwindleLayoutHandler.layoutWithDwindleEngine(
                    activeWorkspaces: [leftWorkspace, rightWorkspace]
                )
            }
        }
        let leftPlan = try XCTUnwrap(plans.first { $0.workspaceId == leftWorkspace })
        let rightPlan = try XCTUnwrap(plans.first { $0.workspaceId == rightWorkspace })
        let leftFrames = try leftTokens.map { token in
            try XCTUnwrap(leftPlan.diff.frameChanges.first { $0.token == token }?.frame)
        }
        let rightFrames = try rightTokens.map { token in
            try XCTUnwrap(rightPlan.diff.frameChanges.first { $0.token == token }?.frame)
        }

        XCTAssertEqual(separation(between: leftFrames[0], and: leftFrames[1]), 4, accuracy: 0.5)
        XCTAssertEqual(separation(between: rightFrames[0], and: rightFrames[1]), 24, accuracy: 0.5)
    }

    @MainActor
    func testTopGapIsMeasuredFromPhysicalTopAcrossDisplays() {
        let settings = makeSettingsStore()
        settings.borders.enabled = false
        settings.workspaceBar.enabled = false
        settings.gaps.outerGapLeft = 0
        settings.gaps.outerGapRight = 0
        settings.gaps.outerGapBottom = 0
        settings.gaps.outerGapTop = 50
        let builtIn = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 867),
            hasNotch: false,
            name: "Built-in"
        )
        let external = makeMonitor(displayId: 2, name: "External", originX: 1440)
        settings.gaps.update(
            MonitorGapSettings(monitorName: external.name, monitorDisplayId: external.displayId, outerGapTop: 41),
            for: external
        )
        let controller = WMController(settings: settings)

        let builtInFrame = controller.layoutRefreshController.buildMonitorSnapshot(for: builtIn).workingFrame
        let externalFrame = controller.layoutRefreshController.buildMonitorSnapshot(for: external).workingFrame

        XCTAssertEqual(builtIn.frame.maxY - builtInFrame.maxY, 50)
        XCTAssertEqual(builtIn.visibleFrame.maxY - builtInFrame.maxY, 17)
        XCTAssertEqual(external.frame.maxY - externalFrame.maxY, 41)
        XCTAssertEqual(builtInFrame, CGRect(x: 0, y: 0, width: 1440, height: 850))
        XCTAssertEqual(externalFrame, CGRect(x: 1440, y: 0, width: 1440, height: 859))
    }

    @MainActor
    func testLiveReloadOfDisplayTopGapOverrideMovesNextLayout() throws {
        let settings = makeSettingsStore()
        settings.borders.enabled = false
        settings.workspaceBar.enabled = false
        settings.gaps.size = 0
        settings.gaps.outerGapTop = 50
        let left = makeMonitor(displayId: 1, name: "Left", originX: 0)
        let right = makeMonitor(displayId: 2, name: "Right", originX: 1440)
        settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: left)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: right)),
                layoutType: .niri
            )
        ]
        let controller = WMController(settings: settings)
        controller.workspaceManager.applyMonitorConfigurationChange([left, right])
        controller.workspaceManager.applySettings()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.syncMonitorsToNiriEngine()
        controller.applyPersistedSettings(settings, startServices: false)
        controller.layoutRefreshController.resetState()
        let leftWorkspace = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        let rightWorkspace = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "2"))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(leftWorkspace, on: left.id))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(rightWorkspace, on: right.id))
        let leftToken = addWindow(pid: 105, windowId: 205, to: leftWorkspace, controller: controller)
        _ = addWindow(pid: 105, windowId: 206, to: leftWorkspace, controller: controller)
        let rightToken = addWindow(pid: 106, windowId: 207, to: rightWorkspace, controller: controller)
        _ = addWindow(pid: 106, windowId: 208, to: rightWorkspace, controller: controller)

        var frames = laidOutFrames(controller: controller, workspaces: [leftWorkspace, rightWorkspace])
        XCTAssertEqual(frames[leftToken]?.maxY, 850)
        XCTAssertEqual(frames[rightToken]?.maxY, 850)

        var export = settings.toExport()
        export.monitorGapSettings = [
            MonitorGapSettings(monitorName: right.name, monitorDisplayId: right.displayId, outerGapTop: 41)
        ]
        settings.applyExport(export)
        controller.layoutRefreshController.resetState()
        controller.applyPersistedSettings(settings, startServices: false)

        XCTAssertNotNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(settings.gaps.resolved(for: right).outerGapTop, 41)
        frames = laidOutFrames(controller: controller, workspaces: [leftWorkspace, rightWorkspace])
        XCTAssertEqual(frames[rightToken]?.maxY, 859)
        XCTAssertEqual(frames[leftToken]?.maxY ?? 850, 850)

        let projected = IPCQueryRouter(controller: controller, appVersion: nil, sessionToken: "gap-tests")
            .displaysResult(IPCQueryRequest(name: .displays, fields: ["id", "outer-gap-top"]))
            .displays
        XCTAssertEqual(projected.map { $0.outerGapTop }, [50, 41])
    }

    @MainActor
    private func laidOutFrames(
        controller: WMController,
        workspaces: [WorkspaceDescriptor.ID]
    ) -> [WindowToken: CGRect] {
        let plans = controller.workspaceManager.withBatchedLayoutBuild {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: Set(workspaces))
        }
        var frames: [WindowToken: CGRect] = [:]
        for change in plans.flatMap({ $0.diff.frameChanges }) {
            frames[change.token] = change.frame
        }
        return frames
    }

    @MainActor
    func testBorderClearanceFloorsRuntimeGapsWithoutMutatingStoredValues() throws {
        let settings = makeSettingsStore()
        let connectedDisplayIds = Set(NSScreen.screens.map(\.displayId))
        let displayId = try XCTUnwrap((1 ... CGDirectDisplayID.max).first { !connectedDisplayIds.contains($0) })
        let monitor = makeMonitor(displayId: displayId, name: "Built-in")
        settings.borders.enabled = true
        settings.borders.width = 5.2
        settings.gaps.size = 0
        settings.gaps.outerGapLeft = 0
        settings.gaps.outerGapRight = 0
        settings.gaps.outerGapTop = 0
        settings.gaps.outerGapBottom = 0
        settings.workspaceBar.enabled = false
        settings.gaps.update(
            MonitorGapSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                innerGap: 0
            ),
            for: monitor
        )
        settings.dwindle.update(
            MonitorDwindleSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                useGlobalGaps: false,
                innerGap: 0
            ),
            for: monitor
        )
        let controller = WMController(settings: settings)
        let frames = controller.layoutFrames(for: monitor, scale: 2)

        XCTAssertEqual(settings.gaps.resolved(for: monitor).innerGap, 0)
        XCTAssertEqual(settings.dwindle.resolved(for: monitor).innerGap, 0)
        XCTAssertEqual(controller.innerGap(for: monitor, scale: 2), 5.5)
        XCTAssertEqual(controller.resolvedDwindleSettings(for: monitor).innerGap, 5.5)
        XCTAssertEqual(frames.workingFrame, CGRect(x: 5.5, y: 5.5, width: 1429, height: 889))
        XCTAssertEqual(frames.borderSafeFillFrame, frames.workingFrame)
        XCTAssertEqual(frames.fullscreenLayoutFrame, monitor.visibleFrame)
    }

    @MainActor
    func testNiriInteractionGeometryUsesOneResolvedScaleForFrameAndGap() {
        let settings = makeSettingsStore()
        let monitor = makeMonitor(displayId: 1, name: "Built-in")
        settings.borders.enabled = true
        settings.borders.width = 5.2
        settings.gaps.size = 0
        settings.gaps.outerGapLeft = 0
        settings.gaps.outerGapRight = 0
        settings.gaps.outerGapTop = 0
        settings.gaps.outerGapBottom = 0
        settings.workspaceBar.enabled = false
        settings.gaps.update(
            MonitorGapSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                innerGap: 0
            ),
            for: monitor
        )
        let controller = WMController(settings: settings)

        let oneX = controller.niriInteractionGeometry(for: monitor, scale: 1)
        let twoX = controller.niriInteractionGeometry(for: monitor, scale: 2)

        XCTAssertEqual(oneX.scale, 1)
        XCTAssertEqual(oneX.innerGap, 6)
        XCTAssertEqual(oneX.workingFrame, CGRect(x: 6, y: 6, width: 1428, height: 888))
        XCTAssertEqual(twoX.scale, 2)
        XCTAssertEqual(twoX.innerGap, 5.5)
        XCTAssertEqual(twoX.workingFrame, CGRect(x: 5.5, y: 5.5, width: 1429, height: 889))
    }

    @MainActor
    func testDisabledBordersPreserveZeroGapGeometry() {
        let settings = makeSettingsStore()
        let monitor = makeMonitor(displayId: 1, name: "Built-in")
        settings.borders.enabled = false
        settings.gaps.size = 0
        settings.gaps.outerGapLeft = 0
        settings.gaps.outerGapRight = 0
        settings.gaps.outerGapTop = 0
        settings.gaps.outerGapBottom = 0
        settings.workspaceBar.enabled = false
        settings.gaps.update(
            MonitorGapSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                innerGap: 0
            ),
            for: monitor
        )
        let controller = WMController(settings: settings)
        let frames = controller.layoutFrames(for: monitor, scale: 2)

        XCTAssertEqual(controller.innerGap(for: monitor, scale: 2), 0)
        XCTAssertEqual(frames.workingFrame, monitor.visibleFrame)
        XCTAssertEqual(frames.borderSafeFillFrame, monitor.visibleFrame)
        XCTAssertEqual(frames.fullscreenLayoutFrame, monitor.visibleFrame)
    }

    @MainActor
    func testBorderClearanceFloorsTopAfterMenuBarNormalization() {
        let settings = makeSettingsStore()
        settings.borders.enabled = true
        settings.borders.width = 8
        settings.gaps.outerGapLeft = 0
        settings.gaps.outerGapRight = 0
        settings.gaps.outerGapTop = 46
        settings.gaps.outerGapBottom = 0
        settings.workspaceBar.enabled = false
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Built-in"
        )
        let controller = WMController(settings: settings)
        let frames = controller.layoutFrames(for: monitor, scale: 2)

        XCTAssertEqual(frames.workingFrame, CGRect(x: 8, y: 8, width: 1424, height: 844))
        XCTAssertEqual(frames.fullscreenLayoutFrame, monitor.visibleFrame)
    }

    func testDwindleApplyGapsEdgesAreFlush() {
        var settings = DwindleSettings()
        settings.innerGap = 8
        let tilingArea = CGRect(x: 0, y: 0, width: 1000, height: 1000)

        let fullEdge = DwindleGapCalculator.applyGaps(nodeRect: tilingArea, tilingArea: tilingArea, settings: settings)
        XCTAssertEqual(fullEdge, tilingArea)

        let leftHalf = CGRect(x: 0, y: 0, width: 500, height: 1000)
        let result = DwindleGapCalculator.applyGaps(nodeRect: leftHalf, tilingArea: tilingArea, settings: settings)
        XCTAssertEqual(result.minX, 0)
        XCTAssertEqual(result.width, 500 - settings.innerGap / 2)
        XCTAssertEqual(result.height, 1000)
    }

    @MainActor
    func testFullscreenLayoutFrameIgnoresOuterGapsButKeepsWorkspaceBarReserve() {
        let settings = makeSettingsStore()
        settings.gaps.outerGapLeft = 12
        settings.gaps.outerGapRight = 12
        settings.gaps.outerGapTop = 46
        settings.gaps.outerGapBottom = 14
        settings.workspaceBar.reserveLayoutSpace = true
        settings.workspaceBar.height = 24
        let controller = WMController(settings: settings)
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Built-in"
        )

        XCTAssertEqual(
            controller.insetWorkingFrame(for: monitor),
            CGRect(x: 12, y: 14, width: 1416, height: 816)
        )
        XCTAssertEqual(
            controller.fullscreenLayoutFrame(for: monitor),
            CGRect(x: 0, y: 0, width: 1440, height: 836)
        )
    }

    @MainActor
    func testEdgeBarReservationsApplyToTilingAndFullscreen() {
        let settings = makeSettingsStore()
        settings.gaps.outerGapLeft = 12
        settings.gaps.outerGapRight = 12
        settings.gaps.outerGapTop = 46
        settings.gaps.outerGapBottom = 14
        settings.workspaceBar.reserveLayoutSpace = true
        settings.workspaceBar.height = 24
        settings.borders.enabled = false
        let controller = WMController(settings: settings)
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 60, width: 1440, height: 800),
            hasNotch: false,
            name: "Built-in"
        )
        let cases: [(WorkspaceBarPosition, CGRect, CGRect)] = [
            (.bottom, CGRect(x: 12, y: 98, width: 1416, height: 756), CGRect(x: 0, y: 84, width: 1440, height: 776)),
            (.left, CGRect(x: 36, y: 74, width: 1392, height: 780), CGRect(x: 24, y: 60, width: 1416, height: 800)),
            (.right, CGRect(x: 12, y: 74, width: 1392, height: 780), CGRect(x: 0, y: 60, width: 1416, height: 800))
        ]
        for (position, working, fullscreen) in cases {
            settings.workspaceBar.position = position
            let frames = controller.layoutFrames(for: monitor, scale: 1)
            XCTAssertEqual(frames.workingFrame, working)
            XCTAssertEqual(frames.fullscreenLayoutFrame, fullscreen)
            XCTAssertEqual(frames.borderSafeFillFrame, fullscreen)
            settings.gaps.fullscreenUsesOuterGaps = true
            XCTAssertEqual(controller.fullscreenLayoutFrame(for: monitor), working)
            settings.gaps.fullscreenUsesOuterGaps = false
            settings.workspaceBar.reserveLayoutSpace = false
            XCTAssertEqual(controller.fullscreenLayoutFrame(for: monitor), monitor.visibleFrame)
            settings.workspaceBar.reserveLayoutSpace = true
        }
    }

    @MainActor
    func testFullscreenLayoutFrameUsesOuterGapsWhenPolicyEnabled() {
        let settings = makeSettingsStore()
        settings.gaps.outerGapLeft = 12
        settings.gaps.outerGapRight = 12
        settings.gaps.outerGapTop = 46
        settings.gaps.outerGapBottom = 14
        settings.workspaceBar.reserveLayoutSpace = true
        settings.workspaceBar.height = 24
        let controller = WMController(settings: settings)
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Built-in"
        )

        let workingFrame = CGRect(x: 12, y: 14, width: 1416, height: 816)
        XCTAssertEqual(controller.insetWorkingFrame(for: monitor), workingFrame)
        XCTAssertEqual(
            controller.fullscreenLayoutFrame(for: monitor),
            CGRect(x: 0, y: 0, width: 1440, height: 836)
        )

        settings.gaps.fullscreenUsesOuterGaps = true

        XCTAssertEqual(controller.insetWorkingFrame(for: monitor), workingFrame)
        XCTAssertEqual(controller.fullscreenLayoutFrame(for: monitor), workingFrame)

        let snapshot = controller.layoutRefreshController.buildMonitorSnapshot(for: monitor)
        XCTAssertEqual(snapshot.workingFrame, workingFrame)
        XCTAssertEqual(snapshot.fullscreenLayoutFrame, workingFrame)
    }

    @MainActor
    func testFullscreenOuterGapPolicyResolvesIndependentlyPerDisplay() {
        let settings = makeSettingsStore()
        settings.gaps.outerGapLeft = 12
        settings.gaps.outerGapRight = 12
        settings.gaps.outerGapTop = 12
        settings.gaps.outerGapBottom = 12
        settings.workspaceBar.enabled = false
        let left = makeMonitor(displayId: 1, name: "Left", originX: 0)
        let right = makeMonitor(displayId: 2, name: "Right", originX: 1440)
        settings.gaps.update(
            MonitorGapSettings(
                monitorName: right.name,
                monitorDisplayId: right.displayId,
                fullscreenUsesOuterGaps: true
            ),
            for: right
        )
        let controller = WMController(settings: settings)

        let leftSnapshot = controller.layoutRefreshController.buildMonitorSnapshot(for: left)
        let rightSnapshot = controller.layoutRefreshController.buildMonitorSnapshot(for: right)

        XCTAssertEqual(leftSnapshot.fullscreenLayoutFrame, left.visibleFrame)
        XCTAssertNotEqual(leftSnapshot.fullscreenLayoutFrame, leftSnapshot.workingFrame)
        XCTAssertEqual(rightSnapshot.fullscreenLayoutFrame, rightSnapshot.workingFrame)
        XCTAssertNotEqual(rightSnapshot.fullscreenLayoutFrame, right.visibleFrame)
    }

    private func makeMonitor(displayId: CGDirectDisplayID, name: String, originX: CGFloat = 0) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: originX, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: originX, y: 0, width: 1440, height: 900),
            hasNotch: false,
            name: name
        )
    }

    private func separation(between first: CGRect, and second: CGRect) -> CGFloat {
        max(
            max(first.minX, second.minX) - min(first.maxX, second.maxX),
            max(first.minY, second.minY) - min(first.maxY, second.maxY)
        )
    }

    @MainActor
    private func addWindow(
        pid: pid_t,
        windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> WindowToken {
        controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMGapTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
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
