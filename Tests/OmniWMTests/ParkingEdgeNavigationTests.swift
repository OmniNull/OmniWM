// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class ParkingEdgeNavigationTests: XCTestCase {
    private final class FocusRecorder {
        var tokens: [WindowToken] = []
    }

    @MainActor private struct Fixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let monitors: [Monitor]
        let workspaceIds: [WorkspaceDescriptor.ID]
        let windows: [[NiriWindow]]
        let recorder: FocusRecorder

        func state(on index: Int = 0) -> ViewportState {
            controller.workspaceManager.niriViewportState(for: workspaceIds[index])
        }

        @discardableResult
        func advance(_ step: Int, on index: Int = 0) -> Bool {
            controller.niriLayoutHandler.focusAdjacentColumn(
                step: step,
                in: workspaceIds[index],
                on: monitors[index]
            )
        }
    }

    func testAdvancesExactlyOneColumnInEitherOrientation() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            try withFixture(orientation: orientation) { fixture in
                XCTAssertTrue(fixture.advance(1))
                XCTAssertEqual(fixture.state().activeColumnIndex, 1)
                XCTAssertEqual(fixture.state().selectedNodeId, fixture.windows[0][1].id)
                XCTAssertEqual(fixture.recorder.tokens, [fixture.windows[0][1].token])
                let request = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest)
                XCTAssertTrue(fixture.controller.intentLedger.defersRetryRaise(for: request))
                XCTAssertNotNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
            }
        }
    }

    func testDoesNotWrapAtEitherEdgeWithInfiniteLoopEnabled() throws {
        try withFixture { fixture in
            XCTAssertTrue(fixture.engine.effectiveInfiniteLoop(in: fixture.workspaceIds[0]))
            let initial = fixture.state()
            XCTAssertFalse(fixture.advance(-1))
            XCTAssertEqual(fixture.state(), initial)
            XCTAssertTrue(fixture.recorder.tokens.isEmpty)

            XCTAssertTrue(fixture.advance(1))
            XCTAssertTrue(fixture.advance(1))
            let final = fixture.state()
            XCTAssertFalse(fixture.advance(1))
            XCTAssertEqual(fixture.state(), final)
            XCTAssertEqual(fixture.recorder.tokens, fixture.windows[0].dropFirst().map(\.token))
        }
    }

    func testSkipsExcludedColumn() throws {
        try withFixture { fixture in
            fixture.controller.workspaceManager.setAppHidden(
                true, pid: fixture.windows[0][1].token.pid, source: .ax
            )

            XCTAssertTrue(fixture.advance(1))

            XCTAssertEqual(fixture.state().activeColumnIndex, 2)
            XCTAssertEqual(fixture.state().selectedNodeId, fixture.windows[0][2].id)
            XCTAssertEqual(fixture.recorder.tokens, [fixture.windows[0][2].token])
        }
    }

    func testUsesExplicitSecondMonitorWorkspace() throws {
        try withFixture { fixture in
            let firstState = fixture.state()

            XCTAssertTrue(fixture.advance(1, on: 1))

            XCTAssertEqual(fixture.state(), firstState)
            XCTAssertEqual(fixture.state(on: 1).selectedNodeId, fixture.windows[1][1].id)
            XCTAssertEqual(fixture.recorder.tokens, [fixture.windows[1][1].token])
        }
    }

    func testRejectsWrongMonitorAndInvalidSteps() throws {
        try withFixture { fixture in
            let initial = fixture.state()
            XCTAssertFalse(fixture.controller.niriLayoutHandler.focusAdjacentColumn(
                step: 1,
                in: fixture.workspaceIds[0],
                on: fixture.monitors[1]
            ))
            for step in [0, -2, 2] {
                XCTAssertFalse(fixture.advance(step))
            }
            XCTAssertEqual(fixture.state(), initial)
            XCTAssertTrue(fixture.recorder.tokens.isEmpty)
        }
    }

    func testMaskClickSelectsAdjacentNativeFullscreenPlaceholder() throws {
        try withFixture { fixture in
            let controller = fixture.controller
            let manager = controller.workspaceManager
            let workspaceId = fixture.workspaceIds[0]
            let target = fixture.windows[0][1]
            let initial = fixture.state()
            XCTAssertTrue(manager.requestNativeFullscreenEnter(target.token, in: workspaceId))
            XCTAssertTrue(manager.markNativeFullscreenSuspended(target.token, ownsNativeFocus: false))
            manager.updateNiriViewportState(initial, for: workspaceId)
            XCTAssertTrue(manager.showsNativeFullscreenPlaceholder(for: target.token))
            XCTAssertFalse(controller.isManagedWindowDisplayable(target.token))
            let mask = try XCTUnwrap(WorldView(controller: controller).parkingEdgeMasks().first {
                $0.key.monitorId == fixture.monitors[0].id && $0.key.side == .right
            })
            XCTAssertEqual(mask.navigation?.target, target.token)
            let edges = ParkingEdgeMaskManager(pointerLocation: { mask.frame.center })
            defer { edges.removeAll() }
            controller.surfaceReconciler.configureParkingEdgeCallbacks(edges)
            edges.apply([mask])
            let window = try XCTUnwrap(SurfaceCoordinator.shared.visibleSurfaceInfos().first {
                $0.id == "parking-edge-mask-987100-right"
            }?.window)
            let click = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: CGPoint(x: 0.5, y: 450), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            ))
            window.contentView?.mouseDown(with: click)
            XCTAssertEqual(fixture.state().selectedNodeId, target.id)
            XCTAssertEqual(manager.selectedManagedToken, target.token)
            XCTAssertTrue(fixture.recorder.tokens.isEmpty)
        }
    }

    func testSurfaceTargetsAreDerivedWithoutIPCSubscribersAndFollowOrientation() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            try withFixture(orientation: orientation) { fixture in
                fixture.controller.setFocusFollowsMouse(true)
                XCTAssertFalse(fixture.controller.hasWindowOrLayoutEventSubscribers)
                let masks = WorldView(controller: fixture.controller).parkingEdgeMasks()
                let side: ParkingEdgeMaskKey.Side = orientation == .horizontal ? .right : .top
                for index in fixture.monitors.indices {
                    let mask = try XCTUnwrap(masks.first {
                        $0.key.monitorId == fixture.monitors[index].id && $0.key.side == side
                    })
                    XCTAssertEqual(mask.navigation?.workspaceId, fixture.workspaceIds[index])
                    XCTAssertEqual(mask.navigation?.target, fixture.windows[index][1].token)
                    XCTAssertEqual(mask.navigation?.hoverEnabled, true)
                    let previous: ParkingEdgeMaskKey.Side = orientation == .horizontal ? .left : .bottom
                    XCTAssertNil(masks.first {
                        $0.key.monitorId == fixture.monitors[index].id && $0.key.side == previous
                    }?.navigation)
                }
            }
        }
    }

    private func withFixture(
        orientation: Monitor.Orientation = .horizontal,
        _ body: (Fixture) throws -> Void
    ) throws {
        let recorder = FocusRecorder()
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "ParkingEdgeNavigationTests",
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    recorder.tokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        defer { controller.layoutRefreshController.resetState() }
        controller.settings.niri.infiniteLoop = true
        controller.settings.niri.centerFocusedColumn = .never
        controller.motionPolicy.animationsEnabled = false
        let monitors = (0 ..< 2).map { index in
            let displayId = CGDirectDisplayID(987_100 + index)
            let frame = CGRect(x: CGFloat(index) * 1_600, y: 0, width: 1_600, height: 900)
            return Monitor(
                id: .init(displayId: displayId),
                displayId: displayId,
                frame: frame,
                visibleFrame: frame,
                hasNotch: false,
                name: "Edge Navigation \(index)"
            )
        }
        controller.settings.workspaces.configurations = monitors.enumerated().map { index, monitor in
            WorkspaceConfiguration(
                name: String(index + 1),
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .niri
            )
        }
        for monitor in monitors {
            controller.settings.monitors.updateOrientationSettings(
                MonitorOrientationSettings(
                    monitorName: monitor.name,
                    monitorDisplayId: monitor.displayId,
                    orientation: orientation
                ),
                for: monitor
            )
        }
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange(monitors)
        manager.applySettings()
        let workspaceIds = try monitors.indices.map { index in
            let id = try XCTUnwrap(manager.workspaceId(for: String(index + 1), createIfMissing: true))
            manager.assignWorkspaceToMonitor(id, monitorId: monitors[index].id)
            _ = manager.setActiveWorkspace(id, on: monitors[index].id)
            return id
        }
        _ = manager.focusWorkspace(id: workspaceIds[0])
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        var windows: [[NiriWindow]] = []
        for (workspaceIndex, workspaceId) in workspaceIds.enumerated() {
            var nodes: [NiriWindow] = []
            for index in 0 ..< 3 {
                let token = WindowToken(
                    pid: pid_t(987_200 + workspaceIndex * 10 + index),
                    windowId: 987_300 + workspaceIndex * 10 + index
                )
                _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
                nodes.append(engine.addWindow(token: token, to: workspaceId, afterSelection: nodes.last?.id))
            }
            for column in engine.columns(in: workspaceId) {
                column.width = .fixed(600)
                column.cachedWidth = 600
                column.height = .fixed(600)
                column.cachedHeight = 600
            }
            let state = ViewportState(
                activeColumnIndex: 0,
                viewOffset: -controller.innerGap(for: monitors[workspaceIndex]),
                selectedNodeId: nodes[0].id
            )
            manager.updateNiriViewportState(state, for: workspaceId)
            windows.append(nodes)
        }
        controller.layoutRefreshController.resetState()
        let blocker = Task { @MainActor in }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: Set(workspaceIds)
        )
        try body(Fixture(
            controller: controller,
            engine: engine,
            monitors: monitors,
            workspaceIds: workspaceIds,
            windows: windows,
            recorder: recorder
        ))
    }
}
