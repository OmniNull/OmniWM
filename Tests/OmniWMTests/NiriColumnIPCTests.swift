// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class NiriColumnIPCTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let engine: NiriLayoutEngine
        let windows: [NiriWindow]
        let unplacedToken: WindowToken
        let router: IPCQueryRouter
    }

    private let screen = CGRect(x: 0, y: 0, width: 1_600, height: 900)

    func testColumnIndicesNumberTheColumnsThatFocusColumnAddresses() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let monitor = Monitor(
            id: Monitor.ID(displayId: 8), displayId: 8, frame: screen, visibleFrame: screen,
            hasNotch: false, name: "Projection"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )
        let tokens = (1 ... 4).map { WindowToken(pid: 786, windowId: $0) }
        let windows = tokens.map { engine.addWindow(token: $0, to: workspaceId, afterSelection: nil) }
        let context = NiriInteractionContext(
            workspaceId: workspaceId, motion: .disabled, workingFrame: screen, gaps: 12, orientation: .horizontal
        )
        var state = ViewportState(selectedNodeId: windows[3].id)
        let tabbedColumn = try XCTUnwrap(engine.column(of: windows[2]))
        XCTAssertTrue(engine.consumeWindow(
            windows[3], into: tabbedColumn, enteringFrom: .right, context: context, state: &state
        ))
        XCTAssertTrue(engine.setColumnDisplay(
            .tabbed, for: tabbedColumn, in: workspaceId, motion: .disabled, orientation: .horizontal
        ))
        engine.setProjectionExclusions([tokens[1]], in: workspaceId)

        let summary = engine.columnSummary(in: workspaceId, state: state, geometry: nil)

        XCTAssertEqual(summary.columnIndexByToken, [tokens[0]: 1, tokens[2]: 2, tokens[3]: 2])
        XCTAssertNil(summary.viewport)
        for columnIndex in 1 ... 2 {
            let target = engine.focusColumn(
                columnIndex - 1, currentSelection: windows[0], context: context, state: &state
            ) as? NiriWindow
            XCTAssertEqual(target.flatMap { summary.columnIndexByToken[$0.token] }, columnIndex)
        }
    }

    func testViewportRelationsMatchSettledLayoutVisibility() throws {
        let engine = NiriLayoutEngine()
        engine.updateConfiguration(centerFocusedColumn: .never)
        let workspaceId = WorkspaceDescriptor.ID()
        let gap: CGFloat = 16
        let workingFrame = CGRect(x: 0, y: 0, width: 2_560, height: 1_440)
        let monitor = Monitor(
            id: Monitor.ID(displayId: 9), displayId: 9, frame: workingFrame, visibleFrame: workingFrame,
            hasNotch: false, name: "Viewport"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )
        let tokens = (1 ... 4).map { WindowToken(pid: 787, windowId: $0) }
        for token in tokens {
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        let columnSpan = (workingFrame.width - gap) * 0.5 - gap
        let fixture = RelationFixture(
            engine: engine,
            workspaceId: workspaceId,
            tokens: tokens,
            geometry: NiriSizingGeometry(workingFrame: workingFrame, gaps: gap, orientation: .horizontal)
        )
        let columns = engine.columns(in: workspaceId)
        for column in columns {
            column.width = .proportion(0.5)
            column.cachedWidth = columnSpan
        }

        let before = NiriColumnViewportRelation.before
        let shown = NiriColumnViewportRelation.intersecting
        let after = NiriColumnViewportRelation.after

        try assertRelations([shown, shown, after, after], active: 0, offset: -gap, fixture, [monitor])
        try assertRelations([before, before, shown, shown], active: 2, offset: -gap, fixture, [monitor])
        try assertRelations([shown, shown, shown, after], active: 1, offset: -644, fixture, [monitor])
        try assertRelations([before, shown, shown, after], active: 1, offset: -gap - 8, fixture, [monitor])

        columns[1].targetWidth = 600
        XCTAssertEqual(fixture.relations(active: 1, offset: -gap - 8), [before, shown, shown, shown])
        columns[1].targetWidth = nil

        for column in columns {
            column.cachedWidth = 0
        }
        XCTAssertEqual(fixture.relations(active: 2, offset: -gap), [before, before, shown, shown])
        for column in columns {
            column.cachedWidth = columnSpan
        }

        let neighbor = Monitor(
            id: Monitor.ID(displayId: 10), displayId: 10, frame: workingFrame.offsetBy(dx: workingFrame.width, dy: 0),
            visibleFrame: workingFrame.offsetBy(dx: workingFrame.width, dy: 0), hasNotch: false, name: "Neighbor"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor), (workspaceId: WorkspaceDescriptor.ID(), monitor: neighbor)],
            orientations: [monitor.id: .horizontal, neighbor.id: .horizontal]
        )
        try assertRelations([shown, shown, after, after], active: 1, offset: -644, fixture, [monitor, neighbor])
    }

    func testWorkspaceDataChannelsFollowWhatChanged() {
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 788, windowId: 1)
        func scene(columnIndex: Int, viewport: [NiriColumnViewportRelation]) -> DesiredSurfaceScene {
            var scene = DesiredSurfaceScene()
            scene.niriColumns = [
                workspaceId: NiriColumnSummary(columnIndexByToken: [token: columnIndex], viewport: viewport)
            ]
            return scene
        }
        func channels(to desired: DesiredSurfaceScene, from previous: DesiredSurfaceScene) -> [IPCSubscriptionChannel] {
            WMController.workspaceDataChannels(from: previous, to: desired)
        }
        let resting = scene(columnIndex: 1, viewport: [.intersecting, .after])

        XCTAssertEqual(channels(to: resting, from: resting), [])
        XCTAssertEqual(channels(to: scene(columnIndex: 1, viewport: [.before, .intersecting]), from: resting), [
            .layoutChanged
        ])
        XCTAssertEqual(channels(to: scene(columnIndex: 2, viewport: [.intersecting, .after]), from: resting), [
            .windowsChanged
        ])
        XCTAssertEqual(channels(to: scene(columnIndex: 2, viewport: [.before, .intersecting]), from: resting), [
            .windowsChanged,
            .layoutChanged
        ])
        XCTAssertEqual(channels(to: resting, from: .empty), [.windowsChanged, .layoutChanged])
    }

    func testQueriesReportColumnFieldsOnlyWhenRequested() throws {
        let fixture = try makeFixture()
        let tokens = fixture.windows.map(\.token)

        let selected = fixture.router.windowsResult(
            IPCQueryRequest(name: .windows, fields: ["window-id", "column-index"])
        ).windows
        let columnIndexByWindowId = Dictionary(
            uniqueKeysWithValues: selected.compactMap { window in window.windowId.map { ($0, window.columnIndex) } }
        )
        XCTAssertEqual(
            columnIndexByWindowId,
            [
                tokens[0].windowId: 1,
                tokens[1].windowId: 2,
                tokens[2].windowId: 3,
                fixture.unplacedToken.windowId: nil
            ]
        )
        let omitted = fixture.router.windowsResult(IPCQueryRequest(name: .windows, fields: ["window-id"]))
        XCTAssertTrue(omitted.windows.allSatisfy { $0.columnIndex == nil })
        XCTAssertFalse(String(decoding: try IPCWire.makeEncoder().encode(omitted), as: UTF8.self)
            .contains("columnIndex"))

        let workspaces = fixture.router.workspacesResult(
            IPCQueryRequest(name: .workspaces, fields: ["raw-name", "columns"])
        ).workspaces
        let columns = try XCTUnwrap(workspaces.first { $0.rawName == "86" }?.columns)
        XCTAssertEqual(columns.map(\.index), [1, 2, 3])
        XCTAssertEqual(columns.map(\.viewport), [.intersecting, .intersecting, .after])
        XCTAssertTrue(String(decoding: try IPCWire.makeEncoder().encode(columns[0]), as: UTF8.self)
            .contains("\"viewport\":\"intersecting\""))
        XCTAssertNil(fixture.router.workspacesResult(
            IPCQueryRequest(name: .workspaces, fields: ["raw-name"])
        ).workspaces.first?.columns)
        XCTAssertTrue(IPCAutomationManifest.windowFieldCatalog.contains("column-index"))
        XCTAssertTrue(IPCAutomationManifest.workspaceFieldCatalog.contains("columns"))
    }

    func testColumnChangesWithoutBarChangesDeliverCurrentPayloads() async throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager
        let bridge = IPCApplicationBridge(
            controller: fixture.controller,
            appVersion: "0.0.0-test",
            sessionToken: "session",
            authorizationToken: "token"
        )
        var windowEvents = await bridge.stream(for: .windowsChanged).makeAsyncIterator()
        var layoutEvents = await bridge.stream(for: .layoutChanged).makeAsyncIterator()
        fixture.controller.ipcApplicationBridge = bridge
        fixture.controller.hasStartedServices = true

        fixture.controller.surfaceReconciler.reconcileNow()
        let initialWindows = await windowEvents.next()
        let initialLayout = await layoutEvents.next()
        XCTAssertEqual(try columnIndex(of: fixture.windows[2].token, in: initialWindows), 3)
        XCTAssertEqual(try viewport(in: initialLayout), [.intersecting, .intersecting, .after])

        manager.withNiriViewportState(for: fixture.workspaceId) { $0.activeColumnIndex = 2 }
        fixture.controller.surfaceReconciler.reconcileNow()
        let scrolledLayout = await layoutEvents.next()
        XCTAssertEqual(try viewport(in: scrolledLayout), [.before, .before, .intersecting])

        let secondColumn = try XCTUnwrap(fixture.engine.column(of: fixture.windows[1]))
        manager.withEngineMutationScope {
            var state = manager.niriViewportState(for: fixture.workspaceId)
            XCTAssertTrue(fixture.engine.consumeWindow(
                fixture.windows[2], into: secondColumn, enteringFrom: .right,
                context: .init(
                    workspaceId: fixture.workspaceId, motion: .disabled, workingFrame: screen,
                    gaps: 12, orientation: .horizontal
                ),
                state: &state
            ))
        }
        fixture.controller.surfaceReconciler.reconcileNow()

        let renumberedWindows = await windowEvents.next()
        let renumberedLayout = await layoutEvents.next()
        XCTAssertEqual(try columnIndex(of: fixture.windows[2].token, in: renumberedWindows), 2)
        XCTAssertEqual(try viewport(in: renumberedLayout), [.before, .intersecting])
        await bridge.shutdown()
    }

    private struct RelationFixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let tokens: [WindowToken]
        let geometry: NiriSizingGeometry

        func state(active: Int, offset: CGFloat) -> ViewportState {
            var state = ViewportState(activeColumnIndex: active)
            state.jumpOffset(to: offset)
            return state
        }

        func relations(active: Int, offset: CGFloat) -> [NiriColumnViewportRelation]? {
            engine.columnSummary(
                in: workspaceId,
                state: state(active: active, offset: offset),
                geometry: geometry
            ).viewport
        }
    }

    private func assertRelations(
        _ expected: [NiriColumnViewportRelation],
        active: Int,
        offset: CGFloat,
        _ fixture: RelationFixture,
        _ monitors: [Monitor],
        line: UInt = #line
    ) throws {
        XCTAssertEqual(fixture.relations(active: active, offset: offset), expected, line: line)
        let frame = fixture.geometry.workingFrame
        let layout = fixture.engine.calculateLayoutWithVisibility(
            state: fixture.state(active: active, offset: offset),
            workspaceId: fixture.workspaceId,
            monitorFrame: frame,
            screenFrame: frame,
            gaps: (horizontal: fixture.geometry.gaps, vertical: fixture.geometry.gaps),
            orientation: fixture.geometry.orientation,
            hiddenPlacementMonitor: HiddenPlacementMonitorContext(monitors[0]),
            hiddenPlacementMonitors: monitors.map(HiddenPlacementMonitorContext.init),
            isSettled: true
        )
        let shown = try fixture.tokens.map { token in
            let tokenFrame = try XCTUnwrap(layout.frames[token], line: line)
            return layout.hiddenHandles[token] == nil && tokenFrame.intersection(frame).width > 1
        }
        XCTAssertEqual(shown, expected.map { $0 == .intersecting }, line: line)
    }

    private func columnIndex(of token: WindowToken, in event: IPCEventEnvelope?) throws -> Int? {
        let event = try XCTUnwrap(event)
        guard case let .windows(result) = event.result.payload else {
            XCTFail("unexpected payload \(event.result.payload)")
            return nil
        }
        return try XCTUnwrap(result.windows.first { $0.windowId == token.windowId }).columnIndex
    }

    private func viewport(in event: IPCEventEnvelope?) throws -> [IPCColumnViewport]? {
        let event = try XCTUnwrap(event)
        guard case let .workspaces(result) = event.result.payload else {
            XCTFail("unexpected payload \(event.result.payload)")
            return nil
        }
        return try XCTUnwrap(result.workspaces.first { $0.rawName == "86" }).columns?.map(\.viewport)
    }

    private func makeFixture() throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "NiriColumnIPCTests")
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([
            Monitor(
                id: .init(displayId: 1), displayId: 1, frame: screen, visibleFrame: screen,
                hasNotch: false, name: "Columns"
            )
        ])
        let workspaceId = try XCTUnwrap(WindowAdmissionTestSupport.workspace(
            named: "86", layoutType: .niri, controller: controller
        ))
        _ = manager.focusWorkspace(named: "86")
        let tokens = (1 ... 3).map { WindowToken(pid: 890_786, windowId: 786_000 + $0) }
        let unplacedToken = WindowToken(pid: 890_786, windowId: 786_009)
        for token in tokens + [unplacedToken] {
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        }
        let engine = NiriLayoutEngine()
        controller.niriEngine = engine
        let windows = manager.withEngineMutationScope {
            tokens.map { engine.addWindow(token: $0, to: workspaceId, afterSelection: nil) }
        }
        for column in engine.columns(in: workspaceId) {
            column.cachedWidth = 1_000
        }
        controller.layoutRefreshController.resetState()
        let router = IPCQueryRouter(controller: controller, appVersion: nil, sessionToken: "niri-column-tests")
        router.windowOrderedInProvider = { _ in true }
        return Fixture(
            controller: controller,
            workspaceId: workspaceId,
            engine: engine,
            windows: windows,
            unplacedToken: unplacedToken,
            router: router
        )
    }
}
