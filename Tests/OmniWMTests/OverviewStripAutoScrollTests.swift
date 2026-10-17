// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class OverviewStripAutoScrollTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let overview: OverviewController
        let projection: OverviewViewportProjection
        let drag: OverviewDragSession
        let monitor: Monitor
        let workspaceId: WorkspaceDescriptor.ID
        let handle: WindowHandle
    }

    private struct OverviewStack {
        let overview: OverviewController
        let projection: OverviewViewportProjection
        let drag: OverviewDragSession
    }

    private func makeFixture(windowCount: Int = 4) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMOverviewStripAutoScrollTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        settings.animationsEnabled = false
        let displayId: CGDirectDisplayID = try XCTUnwrap(NSScreen.screens.first?.displayId)
        let frame = CGRect(x: 0, y: 0, width: 1280, height: 900)
        let monitor = Monitor(
            id: .init(displayId: displayId), displayId: displayId, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Strip Auto Scroll Monitor"
        )
        settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .niri
            )
        ]
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in }, focusSpecificWindow: { _, _, _ in }, raiseWindow: { _ in }
            )
        )
        let engine = NiriLayoutEngine()
        controller.niriEngine = engine
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitor])
        manager.applySettings()
        controller.niriLayoutHandler.syncMonitorsToNiriEngine()
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        XCTAssertTrue(manager.setActiveWorkspace(workspaceId, on: monitor.id))
        let handle = try populateNiriWindows(
            manager: manager, engine: engine, workspaceId: workspaceId, count: windowCount
        )
        let stack = createOverviewStack(controller: controller, monitor: monitor)
        return Fixture(
            controller: controller, overview: stack.overview, projection: stack.projection, drag: stack.drag,
            monitor: monitor, workspaceId: workspaceId, handle: handle
        )
    }

    private func populateNiriWindows(
        manager: WorkspaceManager,
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        count: Int
    ) throws -> WindowHandle {
        var firstHandle: WindowHandle?
        var lastNode: NiriWindow?
        let sizing = engine.initialContainerSizingState(for: 0.8)
        for index in 0 ..< count {
            let id = 92_110 + index
            let token = manager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid_t(id)), windowId: id),
                pid: pid_t(id), windowId: id, to: workspaceId, mode: .tiling
            )
            lastNode = manager.withEngineMutationScope {
                engine.addWindow(
                    token: token, to: workspaceId, afterSelection: lastNode?.id,
                    containerSizingState: sizing
                )
            }
            if firstHandle == nil {
                firstHandle = manager.handle(for: token)
            }
        }
        return try XCTUnwrap(firstHandle)
    }

    private func createOverviewStack(
        controller: WMController,
        monitor: Monitor
    ) -> OverviewStack {
        var environment = OverviewEnvironment()
        environment.windowTitle = { _ in "Strip Auto Scroll" }
        environment.windowFrame = { _ in CGRect(x: 100, y: 100, width: 600, height: 400) }
        let overview = OverviewController(
            wmController: controller, motionPolicy: controller.motionPolicy, environment: environment
        )
        overview.onAnimationComplete(state: .open)
        let facts = OverviewWindowFacts(wmController: controller, environment: environment)
        let snapshot = OverviewSnapshot(wmController: controller, facts: facts)
        snapshot.build()
        let projection = OverviewViewportProjection(wmController: controller, snapshot: snapshot, scale: 0.5)
        projection.activeInteractionMonitorId = monitor.id
        projection.rebuildProjectedLayouts()
        let actions = OverviewStructuralActions(wmController: controller, windowFacts: facts)
        let mutation = OverviewMutationSession(
            wmController: controller, projection: projection, windowFacts: facts, structuralActions: actions
        )
        let drag = OverviewDragSession(
            projection: projection, snapshot: snapshot,
            windowSession: OverviewWindowSession(
                projection: projection, ownedWindowRegistry: .shared, motionPolicy: controller.motionPolicy
            ),
            structuralActions: actions, mutationSession: mutation
        )
        mutation.connect(overview: overview)
        drag.connect(overview: overview)
        return OverviewStack(overview: overview, projection: projection, drag: drag)
    }

    func testDraggingThumbnailToRightBandProducesPositiveHorizontalPanAndScrollsStrip() throws {
        let fixture = try makeFixture(windowCount: 5)
        defer { fixture.drag.cancelDrag() }
        let layout = try XCTUnwrap(fixture.projection.layoutsByMonitor[fixture.monitor.id])
        let section = try XCTUnwrap(layout.workspaceSections.first { $0.workspaceId == fixture.workspaceId })
        XCTAssertGreaterThan(section.hiddenColumnsAfter, 0)

        fixture.drag.beginDrag(on: fixture.monitor.id, handle: fixture.handle, startPoint: .zero)
        let rightBandPoint = CGPoint(
            x: section.ribbonFrame.maxX - 10,
            y: section.ribbonFrame.midY - layout.scrollOffset
        )
        XCTAssertNotNil(layout.workspaceSection(at: rightBandPoint))
        fixture.drag.updateDrag(on: fixture.monitor.id, at: rightBandPoint)

        let autoScroll = try XCTUnwrap(
            Mirror(reflecting: fixture.drag).children.first(where: { $0.label == "autoScroll" })?.value
                as? OverviewDragAutoScroll
        )
        let horizontalPan = Mirror(reflecting: autoScroll).children
            .first(where: { $0.label == "horizontalVelocity" })?.value as? CGFloat ?? 0
        XCTAssertGreaterThan(horizontalPan, 0)

        autoScroll.advance(by: 1.0 / 60)

        let updatedLayout = try XCTUnwrap(fixture.projection.layoutsByMonitor[fixture.monitor.id])
        let pan = updatedLayout.stripPanByWorkspace[fixture.workspaceId] ?? 0
        XCTAssertNotEqual(pan, 0)
    }

    func testVerticalStripScrollsAlongItsOwnAxis() {
        let strip = CGRect(x: 0, y: 0, width: 300, height: 800)
        let nearBottom = CGPoint(x: 290, y: 790)
        let velocity = OverviewLayoutCalculator.dragStripAutoScrollVelocity(
            pointer: nearBottom, stripFrame: strip, orientation: .vertical
        )
        XCTAssertGreaterThan(velocity, 0)
        let midHeightNearRightEdge = CGPoint(x: 290, y: 400)
        XCTAssertEqual(
            OverviewLayoutCalculator.dragStripAutoScrollVelocity(
                pointer: midHeightNearRightEdge, stripFrame: strip, orientation: .vertical
            ),
            0
        )
    }
}
