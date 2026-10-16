// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class OverviewDragSessionRegressionTests: XCTestCase {
    private final class TickRecorder {
        var values: [(Monitor.ID, CGFloat)] = []
    }

    func testAutoScrollStartsFromSinglePointerUpdateAndRestartsAcrossDisplays() throws {
        let screens = NSScreen.screens
        XCTAssertFalse(screens.isEmpty)
        let autoScroll = OverviewDragAutoScroll()
        defer { autoScroll.stop() }
        let ticks = TickRecorder()
        autoScroll.onTick = { ticks.values.append(($0, $1)) }

        for screen in screens {
            let monitorId = Monitor.ID(displayId: try XCTUnwrap(screen.displayId))
            autoScroll.update(monitorId: monitorId, pointer: CGPoint(x: 100, y: 10), velocity: -720)
            autoScroll.advance(by: 1.0 / 60)
            XCTAssertEqual(ticks.values.last?.0, monitorId)
            XCTAssertEqual(try XCTUnwrap(ticks.values.last?.1), -12, accuracy: 0.0001)
        }
        XCTAssertEqual(ticks.values.count, screens.count)

        autoScroll.stop()
        autoScroll.advance(by: 1.0 / 60)
        XCTAssertEqual(ticks.values.count, screens.count)
        let monitorId = Monitor.ID(displayId: try XCTUnwrap(screens.first?.displayId))
        autoScroll.update(monitorId: monitorId, pointer: CGPoint(x: 100, y: 790), velocity: 360)
        autoScroll.advance(by: 1.0 / 60)
        XCTAssertEqual(try XCTUnwrap(ticks.values.last?.1), 6, accuracy: 0.0001)
        autoScroll.update(monitorId: monitorId, pointer: CGPoint(x: 100, y: 400), velocity: 0)
        autoScroll.advance(by: 1.0 / 60)
        XCTAssertEqual(ticks.values.count, screens.count + 1)
        XCTAssertNil(autoScroll.monitorId)
    }

    func testCrossMonitorBlankAreaClearsPreviousDropHighlight() throws {
        let fixture = try makeFixture()
        defer { fixture.drag.cancelDrag() }
        let firstLayout = try XCTUnwrap(fixture.projection.layoutsByMonitor[fixture.monitors[0].id])
        let section = try XCTUnwrap(firstLayout.workspaceSections.first { $0.workspaceId == fixture.workspaceIds[1] })
        let target = CGPoint(x: section.ribbonFrame.midX, y: section.ribbonFrame.midY - firstLayout.scrollOffset)
        fixture.drag.beginDrag(on: fixture.monitors[0].id, handle: fixture.handle, startPoint: .zero)
        fixture.drag.updateDrag(on: fixture.monitors[0].id, at: target)
        XCTAssertEqual(
            fixture.projection.layoutsByMonitor[fixture.monitors[0].id]?.dragTarget,
            .workspaceMove(workspaceId: fixture.workspaceIds[1])
        )

        let blankOnSecond = CGPoint(x: fixture.monitors[1].frame.minX + 10, y: fixture.monitors[1].frame.maxY - 1)
        fixture.drag.updateDrag(on: fixture.monitors[0].id, at: blankOnSecond)

        XCTAssertEqual(fixture.projection.activeInteractionMonitorId, fixture.monitors[1].id)
        XCTAssertTrue(fixture.projection.layoutsByMonitor.values.allSatisfy { $0.dragTarget == nil })
    }

    func testDropResolvesReleasePositionOnAnotherMonitor() async throws {
        let fixture = try makeFixture()
        let sourceMonitorId = fixture.monitors[0].id
        let targetMonitorId = fixture.monitors[1].id
        let targetLayout = try XCTUnwrap(fixture.projection.layoutsByMonitor[targetMonitorId])
        let section = try XCTUnwrap(targetLayout.workspaceSections.first { $0.workspaceId == fixture.workspaceIds[2] })
        let release = CGPoint(
            x: fixture.monitors[1].frame.minX + section.ribbonFrame.midX,
            y: fixture.monitors[1].frame.minY + section.ribbonFrame.midY - targetLayout.scrollOffset
        )
        fixture.drag.beginDrag(on: sourceMonitorId, handle: fixture.handle, startPoint: .zero)
        fixture.drag.updateDrag(on: sourceMonitorId, at: CGPoint(x: 10, y: fixture.monitors[0].frame.maxY - 1))
        fixture.drag.endDrag(on: sourceMonitorId, at: release)

        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: fixture.handle.id), fixture.workspaceIds[2])
        XCTAssertEqual(fixture.projection.activeInteractionMonitorId, targetMonitorId)
        XCTAssertFalse(fixture.drag.isActive)
        while let task = fixture.controller.layoutRefreshController.layoutState.activeRefreshTask { await task.value }
    }

    func testDropOutsideLastTargetDoesNotMoveWindow() throws {
        let fixture = try makeFixture()
        let monitor = fixture.monitors[0]
        let layout = try XCTUnwrap(fixture.projection.layoutsByMonitor[monitor.id])
        let section = try XCTUnwrap(layout.workspaceSections.first { $0.workspaceId == fixture.workspaceIds[1] })
        fixture.drag.beginDrag(on: monitor.id, handle: fixture.handle, startPoint: .zero)
        fixture.drag.updateDrag(
            on: monitor.id,
            at: CGPoint(x: section.ribbonFrame.midX, y: section.ribbonFrame.midY - layout.scrollOffset)
        )
        fixture.drag.endDrag(on: monitor.id, at: CGPoint(x: 10, y: monitor.frame.maxY - 1))

        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: fixture.handle.id), fixture.workspaceIds[0])
        XCTAssertTrue(fixture.projection.layoutsByMonitor.values.allSatisfy { $0.dragTarget == nil })
        XCTAssertFalse(fixture.drag.isActive)
    }

    func testDropOnNewWorkspaceCreatesAndMovesWithoutClosingOverview() async throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager
        let configurations = fixture.controller.settings.workspaces.configurations
        let targetMonitor = fixture.monitors[1]
        let target = try newWorkspacePoint(on: targetMonitor.id, fixture: fixture)
        fixture.drag.beginDrag(on: fixture.monitors[0].id, handle: fixture.handle, startPoint: .zero)

        fixture.drag.endDrag(
            on: fixture.monitors[0].id,
            at: fixture.projection.globalPoint(from: target, on: targetMonitor.id)
        )

        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "4"))
        XCTAssertEqual(manager.workspaces.count, fixture.workspaceIds.count + 1)
        XCTAssertEqual(manager.monitorId(for: workspaceId), targetMonitor.id)
        XCTAssertEqual(manager.workspace(for: fixture.handle.id), workspaceId)
        XCTAssertEqual(manager.activeVisibleWorkspaceMap()[targetMonitor.id], workspaceId)
        XCTAssertEqual(fixture.projection.selectedWindowHandle, fixture.handle)
        guard case .open = fixture.overview.state else { return XCTFail("Drop closed the overview") }
        XCTAssertFalse(fixture.drag.isActive)
        XCTAssertEqual(fixture.controller.settings.workspaces.configurations, configurations)
        while let task = fixture.controller.layoutRefreshController.layoutState.activeRefreshTask { await task.value }
        guard case .open = fixture.overview.state else { return XCTFail("Mutation completion closed the overview") }
        XCTAssertEqual(manager.workspace(for: fixture.handle.id), workspaceId)
    }

    func testCancelAndInvalidReleaseAfterNewWorkspaceHoverDoNotCreateWorkspace() throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager
        let before = manager.workspaces
        let monitor = fixture.monitors[0]
        let target = try newWorkspacePoint(on: monitor.id, fixture: fixture)

        for cancel in [true, false] {
            fixture.drag.beginDrag(on: monitor.id, handle: fixture.handle, startPoint: .zero)
            fixture.drag.updateDrag(on: monitor.id, at: target)
            XCTAssertEqual(
                fixture.projection.layoutsByMonitor[monitor.id]?.dragTarget,
                .newWorkspace(monitorId: monitor.id)
            )
            if cancel {
                fixture.drag.cancelDrag()
            } else {
                fixture.drag.endDrag(on: monitor.id, at: CGPoint(x: 10, y: monitor.frame.maxY - 1))
            }
            XCTAssertEqual(manager.workspaces, before)
            XCTAssertEqual(manager.workspace(for: fixture.handle.id), fixture.workspaceIds[0])
            XCTAssertTrue(fixture.projection.layoutsByMonitor.values.allSatisfy { $0.dragTarget == nil })
            XCTAssertFalse(fixture.drag.isActive)
            guard case .open = fixture.overview.state else { return XCTFail("Drag cancellation closed the overview") }
        }
    }

    func testFloatingDropRepositionsWithinWorkspaceAndAcrossMonitorsWithoutTiling() async throws {
        let original = CGRect(x: 100, y: 200, width: 500, height: 300)
        let fixture = try makeFixture(floatingFrame: original)
        let manager = fixture.controller.workspaceManager
        for (index, workspaceId) in [(0, fixture.workspaceIds[0]), (1, fixture.workspaceIds[2])] {
            let monitor = fixture.monitors[index]
            let layout = try XCTUnwrap(fixture.projection.layoutsByMonitor[monitor.id])
            let section = try XCTUnwrap(layout.workspaceSections.first { $0.workspaceId == workspaceId })
            let point = CGPoint(
                x: section.visibleFrame.midX + 30,
                y: section.visibleFrame.midY - layout.scrollOffset
            )
            let resolution = layout.resolveDrop(
                at: point, draggedHandle: fixture.handle,
                sourceWorkspaceId: try XCTUnwrap(manager.workspace(for: fixture.handle.id)),
                floatingSize: original.size, monitor: monitor
            )
            guard case let .floatingPlacement(_, expectedFrame, _) = resolution.target else {
                return XCTFail("Expected floating placement")
            }
            FrameApplyTrace.shared.beginCapture()
            defer { FrameApplyTrace.shared.endCapture() }
            fixture.drag.beginDrag(on: monitor.id, handle: fixture.handle, startPoint: .zero)
            fixture.drag.endDrag(on: monitor.id, at: point)

            XCTAssertEqual(manager.workspace(for: fixture.handle.id), workspaceId)
            XCTAssertEqual(manager.windowMode(for: fixture.handle.id), .floating)
            XCTAssertEqual(manager.floatingState(for: fixture.handle.id)?.lastFrame, expectedFrame)
            XCTAssertEqual(manager.floatingState(for: fixture.handle.id)?.referenceMonitorId, monitor.id)
            let placements = frameSubmissions(for: fixture.handle)
            XCTAssertEqual(placements.count, 1)
            XCTAssertTrue(try XCTUnwrap(placements.first).contains("target=\(TraceFormat.rect(expectedFrame))"))
            while let task = fixture.controller.layoutRefreshController.layoutState
                .activeRefreshTask { await task.value }
        }
    }

    func testFloatingCreationHoverAndInvalidReleaseDoNotWriteOrAllocate() throws {
        let original = CGRect(x: 100, y: 200, width: 500, height: 300)
        let fixture = try makeFixture(floatingFrame: original)
        let manager = fixture.controller.workspaceManager
        let before = manager.workspaces
        let monitor = fixture.monitors[0]
        let point = try newWorkspacePoint(on: monitor.id, fixture: fixture)
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }
        for cancel in [true, false] {
            fixture.drag.beginDrag(on: monitor.id, handle: fixture.handle, startPoint: .zero)
            fixture.drag.updateDrag(on: monitor.id, at: point)
            guard case .floatingPlacement(.newWorkspace(monitor.id), _, _) = fixture.projection
                .layoutsByMonitor[monitor.id]?.dragTarget else { return XCTFail("Expected creation preview") }
            if cancel {
                fixture.drag.cancelDrag()
            } else {
                fixture.drag.endDrag(on: monitor.id, at: CGPoint(x: 10, y: monitor.frame.maxY - 1))
            }
            XCTAssertEqual(manager.workspaces, before)
            XCTAssertEqual(manager.floatingState(for: fixture.handle.id)?.lastFrame, original)
            XCTAssertTrue(frameSubmissions(for: fixture.handle).isEmpty)
        }
    }

    func testFloatingCreationUsesReleasePlacementAndKeepsOverviewOpen() async throws {
        let original = CGRect(x: 100, y: 200, width: 500, height: 300)
        let fixture = try makeFixture(floatingFrame: original)
        let manager = fixture.controller.workspaceManager
        let monitor = fixture.monitors[1]
        let point = try newWorkspacePoint(on: monitor.id, fixture: fixture)
        fixture.drag.beginDrag(on: fixture.monitors[0].id, handle: fixture.handle, startPoint: .zero)
        fixture.drag.endDrag(
            on: fixture.monitors[0].id,
            at: fixture.projection.globalPoint(from: point, on: monitor.id)
        )
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "4"))
        XCTAssertEqual(manager.workspace(for: fixture.handle.id), workspaceId)
        XCTAssertEqual(manager.windowMode(for: fixture.handle.id), .floating)
        XCTAssertEqual(manager.floatingState(for: fixture.handle.id)?.lastFrame.size, original.size)
        XCTAssertEqual(manager.floatingState(for: fixture.handle.id)?.lastFrame.center, monitor.frame.center)
        XCTAssertEqual(manager.floatingState(for: fixture.handle.id)?.referenceMonitorId, monitor.id)
        guard case .open = fixture.overview.state else { return XCTFail("Drop closed overview") }
        while let task = fixture.controller.layoutRefreshController.layoutState.activeRefreshTask { await task.value }
    }

    func testParkedFloatingPlacementStoresGeometryWithoutDuplicatingRevealWrite() throws {
        let fixture = try makeFixture(floatingFrame: CGRect(x: 100, y: 200, width: 500, height: 300))
        let manager = fixture.controller.workspaceManager
        let hidden = HiddenState(
            proportionalPosition: .zero, referenceMonitorId: fixture.monitors[0].id, reason: .workspaceInactive
        )
        manager.setHiddenState(hidden, for: fixture.handle.id)
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }
        let target = CGRect(x: 700, y: 300, width: 500, height: 300)

        fixture.controller.placeFloatingWindow(fixture.handle, frame: target)

        XCTAssertEqual(manager.floatingState(for: fixture.handle.id)?.lastFrame, target)
        XCTAssertEqual(manager.resolvedFloatingFrame(for: fixture.handle.id), target)
        XCTAssertEqual(manager.hiddenState(for: fixture.handle.id), hidden)
        XCTAssertTrue(frameSubmissions(for: fixture.handle).isEmpty)
        let entry = try XCTUnwrap(manager.entry(for: fixture.handle))
        guard case let .asyncFrame(restoredFrame) = fixture.controller.layoutRefreshController
            .restoreWindowFromHiddenState(entry, monitor: fixture.monitors[0], hiddenState: hidden)
        else { return XCTFail("Parked placement did not use the existing floating reveal") }
        XCTAssertEqual(restoredFrame, target)
    }

    private func frameSubmissions(for handle: WindowHandle) -> [Substring] {
        FrameApplyTrace.shared.dump().split(separator: "\n").filter {
            $0.contains("win=\(handle.id.windowId) ") && $0.contains("event=outcome=skip/contextUnavailable")
        }
    }

    private func newWorkspacePoint(on monitorId: Monitor.ID, fixture: Fixture) throws -> CGPoint {
        let layout = try XCTUnwrap(fixture.projection.layoutsByMonitor[monitorId])
        let target = try XCTUnwrap(layout.newWorkspaceTarget)
        fixture.projection.adjustScrollOffset(
            by: target.frame.midY - layout.scrollOffset - fixture.projection.viewportFrame(for: monitorId).midY,
            on: monitorId
        )
        let visibleLayout = try XCTUnwrap(fixture.projection.layoutsByMonitor[monitorId])
        return CGPoint(x: target.frame.midX, y: target.frame.midY - visibleLayout.scrollOffset)
    }

    private struct Fixture {
        let controller: WMController
        let overview: OverviewController
        let projection: OverviewViewportProjection
        let drag: OverviewDragSession
        let monitors: [Monitor]
        let workspaceIds: [WorkspaceDescriptor.ID]
        let handle: WindowHandle
    }

    private func makeController() -> (WMController, [Monitor]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMOverviewDragRegression-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        settings.animationsEnabled = false
        let monitors = (0 ... 1).map { index in
            let displayId = CGDirectDisplayID(91_070 + index)
            let frame = CGRect(x: index * 1600, y: index * 200, width: 1600, height: 900)
            return Monitor(
                id: .init(displayId: displayId), displayId: displayId, frame: frame, visibleFrame: frame,
                hasNotch: false, name: "Drag Regression \(index)"
            )
        }
        settings.workspaces.configurations = (0 ... 2).map { index in
            WorkspaceConfiguration(
                name: String(index + 1),
                monitorAssignment: .specificDisplay(OutputId(from: monitors[index == 2 ? 1 : 0])),
                layoutType: .dwindle
            )
        }
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in }, focusSpecificWindow: { _, _, _ in }, raiseWindow: { _ in }
            )
        )
        controller.niriEngine = NiriLayoutEngine()
        controller.dwindleEngine = DwindleLayoutEngine()
        return (controller, monitors)
    }

    private func makeFixture(floatingFrame: CGRect? = nil) throws -> Fixture {
        let (controller, monitors) = makeController()
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange(monitors)
        manager.applySettings()
        let workspaceIds = try (1 ... 3).map { try XCTUnwrap(manager.workspaceId(named: String($0))) }
        XCTAssertTrue(manager.setActiveWorkspace(workspaceIds[0], on: monitors[0].id))
        XCTAssertTrue(manager.setActiveWorkspace(workspaceIds[2], on: monitors[1].id))
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(491_070), windowId: 70),
            pid: 491_070, windowId: 70, to: workspaceIds[0], mode: floatingFrame == nil ? .tiling : .floating
        )
        if let floatingFrame {
            manager.updateFloatingGeometry(frame: floatingFrame, for: token, referenceMonitor: monitors[0])
        } else {
            manager.withEngineMutationScope(in: workspaceIds[0]) {
                _ = controller.dwindleEngine?.addWindow(token: token, to: workspaceIds[0], activeWindowFrame: nil)
            }
        }
        let handle = try XCTUnwrap(manager.handle(for: token))
        var environment = OverviewEnvironment()
        environment.windowTitle = { _ in "Drag Regression" }
        environment.windowFrame = { _ in CGRect(x: 100, y: 200, width: 500, height: 300) }
        let overview = OverviewController(
            wmController: controller, motionPolicy: controller.motionPolicy, environment: environment
        )
        overview.onAnimationComplete(state: .open)
        let facts = OverviewWindowFacts(wmController: controller, environment: environment)
        let snapshot = OverviewSnapshot(wmController: controller, facts: facts)
        snapshot.build()
        let projection = OverviewViewportProjection(wmController: controller, snapshot: snapshot, scale: 0.5)
        projection.activeInteractionMonitorId = monitors[0].id
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
        return Fixture(
            controller: controller, overview: overview, projection: projection, drag: drag,
            monitors: monitors, workspaceIds: workspaceIds, handle: handle
        )
    }
}
