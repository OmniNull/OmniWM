// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriEdgeGapsTests: XCTestCase {
    private let workingFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testEdgeGapsSurroundColumnsByDefault() throws {
        let frames = try layoutTwoColumns(edgeGaps: nil)

        XCTAssertEqual(frames[1].maxX - frames[0].minX, workingFrame.width - 20)
        XCTAssertEqual(frames[0].minY, workingFrame.minY + 10)
        XCTAssertEqual(frames[0].maxY, workingFrame.maxY - 10)
    }

    func testDisabledEdgeGapsKeepInnerGapOnlyBetweenColumns() throws {
        let frames = try layoutTwoColumns(edgeGaps: false)

        XCTAssertEqual(frames[1].maxX - frames[0].minX, workingFrame.width)
        XCTAssertEqual(frames[0].minY, workingFrame.minY)
        XCTAssertEqual(frames[0].maxY, workingFrame.maxY)
        XCTAssertEqual(frames[1].minX - frames[0].maxX, 10)
    }

    func testDisabledEdgeGapsKeepInnerGapOnlyBetweenStackedWindows() throws {
        let settings = makeSettingsStore()
        settings.niri.edgeGaps = false
        let (controller, workspaceId) = try makeNiriController(settings: settings)
        let first = addWindow(pid: 101, windowId: 201, to: workspaceId, controller: controller)
        let second = addWindow(pid: 102, windowId: 202, to: workspaceId, controller: controller)
        try layout(workspaceId, controller: controller)
        let engine = try XCTUnwrap(controller.niriEngine)
        let firstNode = try XCTUnwrap(engine.findNode(for: first, in: workspaceId))
        let secondNode = try XCTUnwrap(engine.findNode(for: second, in: workspaceId))
        let firstColumn = try XCTUnwrap(engine.column(of: firstNode))
        controller.workspaceManager.withEngineMutationScope {
            var state = ViewportState()
            state.selectedNodeId = firstNode.id
            XCTAssertTrue(engine.consumeWindow(
                secondNode,
                into: firstColumn,
                enteringFrom: .down,
                context: .init(
                    workspaceId: workspaceId,
                    motion: .disabled,
                    workingFrame: workingFrame,
                    gaps: 10,
                    orientation: .horizontal
                ),
                state: &state
            ))
        }
        let frames = try layout(workspaceId, controller: controller, tokens: [first, second])
        let top = try XCTUnwrap(frames.max { $0.maxY < $1.maxY })
        let bottom = try XCTUnwrap(frames.min { $0.minY < $1.minY })

        XCTAssertEqual(top.maxY, workingFrame.maxY)
        XCTAssertEqual(bottom.minY, workingFrame.minY)
        XCTAssertEqual(top.minY - bottom.maxY, 10)
    }

    func testTogglingEdgeGapsResizesLaidOutColumns() throws {
        let settings = makeSettingsStore()
        let (controller, workspaceId) = try makeNiriController(settings: settings)
        let tokens = [
            addWindow(pid: 101, windowId: 201, to: workspaceId, controller: controller),
            addWindow(pid: 102, windowId: 202, to: workspaceId, controller: controller)
        ]
        try layout(workspaceId, controller: controller, tokens: tokens)

        settings.niri.edgeGaps = false
        controller.updateMonitorGapSettings()
        let frames = try layout(workspaceId, controller: controller, tokens: tokens).sorted { $0.minX < $1.minX }

        XCTAssertEqual(frames[1].maxX - frames[0].minX, workingFrame.width)
        XCTAssertEqual(frames[1].minX - frames[0].maxX, 10)
    }

    func testChangingGlobalInnerGapResizesLaidOutColumns() throws {
        let settings = makeSettingsStore()
        settings.niri.edgeGaps = false
        let (controller, workspaceId) = try makeNiriController(settings: settings)
        let tokens = [
            addWindow(pid: 101, windowId: 201, to: workspaceId, controller: controller),
            addWindow(pid: 102, windowId: 202, to: workspaceId, controller: controller)
        ]
        try layout(workspaceId, controller: controller, tokens: tokens)

        controller.setGapSize(20)
        let frames = try layout(workspaceId, controller: controller, tokens: tokens).sorted { $0.minX < $1.minX }

        XCTAssertEqual(frames[1].maxX - frames[0].minX, workingFrame.width)
        XCTAssertEqual(frames[1].minX - frames[0].maxX, 20)
    }

    func testDisabledEdgeGapsKeepCustomSingleWindowInsideWorkingFrame() throws {
        let settings = makeSettingsStore()
        settings.niri.edgeGaps = false
        settings.niri.singleWindowFit = SingleWindowFit(mode: .custom, width: 1920, height: 1080)
        let (controller, workspaceId) = try makeNiriController(settings: settings)
        let token = addWindow(pid: 101, windowId: 201, to: workspaceId, controller: controller)

        let frame = try XCTUnwrap(layout(workspaceId, controller: controller, tokens: [token]).first)

        XCTAssertEqual(frame, workingFrame)
    }

    func testDisabledEdgeGapsKeepMouseResizedColumnInsideWorkingFrame() throws {
        let settings = makeSettingsStore()
        settings.niri.edgeGaps = false
        let (controller, workspaceId) = try makeNiriController(settings: settings)
        let tokens = [
            addWindow(pid: 101, windowId: 201, to: workspaceId, controller: controller),
            addWindow(pid: 102, windowId: 202, to: workspaceId, controller: controller)
        ]
        try layout(workspaceId, controller: controller, tokens: tokens)
        let engine = try XCTUnwrap(controller.niriEngine)
        let node = try XCTUnwrap(engine.findNode(for: tokens[0], in: workspaceId))
        let geometry = controller.niriInteractionGeometry(for: makeMonitor())

        XCTAssertTrue(engine.interactiveResizeBegin(
            windowId: node.id,
            edges: .right,
            startLocation: .zero,
            in: workspaceId,
            orientation: .horizontal,
            viewOffset: controller.workspaceManager.niriViewportState(for: workspaceId).viewOffset
        ))
        XCTAssertTrue(engine.interactiveResizeUpdate(
            currentLocation: CGPoint(x: workingFrame.width * 2, y: 0),
            monitorFrame: geometry.workingFrame,
            gaps: LayoutGaps(horizontal: geometry.innerGap, vertical: geometry.innerGap)
        ))
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            engine.interactiveResizeEnd(
                motion: .disabled,
                state: &state,
                workingFrame: geometry.workingFrame,
                gaps: geometry.innerGap
            )
        }
        let frame = try XCTUnwrap(layout(workspaceId, controller: controller, tokens: [tokens[0]]).first)

        XCTAssertEqual(frame, workingFrame)
    }

    func testNiriInteractionGeometryMatchesLayoutFrame() {
        let settings = makeSettingsStore()
        configureGaps(settings)
        settings.niri.edgeGaps = false
        let controller = WMController(settings: settings)
        controller.setGapSize(10, publishChange: false)
        let monitor = makeMonitor()

        XCTAssertEqual(
            controller.niriInteractionGeometry(for: monitor, scale: 2).workingFrame,
            workingFrame.insetBy(dx: -10, dy: -10)
        )
        XCTAssertEqual(controller.insetWorkingFrame(for: monitor), workingFrame)
    }

    func testEdgeGapsDefaultsToEnabledWhenKeyIsMissingAndRoundTrips() throws {
        var export = SettingsExport.defaults()
        export.niri.edgeGaps = nil
        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))
        XCTAssertEqual(decoded, .defaults())

        let settings = makeSettingsStore()
        settings.niri.edgeGaps = false
        let reloaded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(settings.toExport()))
        XCTAssertEqual(reloaded.niri.edgeGaps, false)
    }

    private func layoutTwoColumns(edgeGaps: Bool?) throws -> [CGRect] {
        let settings = makeSettingsStore()
        if let edgeGaps {
            settings.niri.edgeGaps = edgeGaps
        }
        let (controller, workspaceId) = try makeNiriController(settings: settings)
        let tokens = [
            addWindow(pid: 101, windowId: 201, to: workspaceId, controller: controller),
            addWindow(pid: 102, windowId: 202, to: workspaceId, controller: controller)
        ]
        return try layout(workspaceId, controller: controller, tokens: tokens).sorted { $0.minX < $1.minX }
    }

    private func makeNiriController(settings: SettingsStore) throws -> (WMController, WorkspaceDescriptor.ID) {
        configureGaps(settings)
        let monitor = makeMonitor()
        settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .niri
            )
        ]
        let controller = WMController(settings: settings)
        controller.setGapSize(10, publishChange: false)
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.syncMonitorsToNiriEngine()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id))
        return (controller, workspaceId)
    }

    private func configureGaps(_ settings: SettingsStore) {
        settings.borders.enabled = false
        settings.workspaceBar.enabled = false
        settings.gaps.size = 10
        settings.gaps.outerGapLeft = 0
        settings.gaps.outerGapRight = 0
        settings.gaps.outerGapTop = 0
        settings.gaps.outerGapBottom = 0
    }

    @discardableResult
    private func layout(
        _ workspaceId: WorkspaceDescriptor.ID,
        controller: WMController,
        tokens: [WindowToken] = []
    ) throws -> [CGRect] {
        let plans = controller.workspaceManager.withBatchedLayoutBuild {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }
        let plan = try XCTUnwrap(plans.first { $0.workspaceId == workspaceId })
        return try tokens.map { token in
            try XCTUnwrap(plan.diff.frameChanges.first { $0.token == token }?.frame)
        }
    }

    private func makeMonitor() -> Monitor {
        Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: workingFrame,
            visibleFrame: workingFrame,
            hasNotch: false,
            name: "Main"
        )
    }

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

    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMNiriEdgeGapsTests-\(UUID().uuidString)", isDirectory: true)
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
