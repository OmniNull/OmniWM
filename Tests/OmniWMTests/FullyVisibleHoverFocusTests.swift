// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class FullyVisibleHoverFocusTests: XCTestCase {
    private final class FocusRecorder {
        var tokens: [WindowToken] = []
        var appliedFrames: [Int: CGRect] = [:]
    }

    @MainActor private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let target: NiriWindow
        let recorder: FocusRecorder

        func hover(frame: CGRect, renderedFrame: CGRect? = nil, exactId: Bool) {
            target.frame = frame
            target.renderedFrame = renderedFrame ?? frame
            recorder.appliedFrames[target.token.windowId] = renderedFrame ?? frame
            controller.mouseEventHandler.dispatchMouseMoved(
                at: (target.renderedFrame ?? frame).intersection(monitor.frame).center,
                windowIdUnderPointer: exactId ? target.token.windowId : nil
            )
        }
    }

    func testRejectsPartialWindowsAtEveryEdgeThroughBothHoverRoutes() throws {
        let frames = [
            CGRect(x: -40, y: 100, width: 300, height: 200),
            CGRect(x: 800, y: 100, width: 300, height: 200),
            CGRect(x: 300, y: -40, width: 300, height: 200),
            CGRect(x: 300, y: 700, width: 300, height: 200)
        ]
        for exactId in [false, true] {
            for frame in frames {
                try withFixture { fixture in
                    let before = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
                    fixture.hover(frame: frame, exactId: exactId)
                    XCTAssertTrue(fixture.recorder.tokens.isEmpty)
                    XCTAssertNil(fixture.controller.mouseEventHandler.latestFocusFollowsMouseToken())
                    XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
                    XCTAssertEqual(
                        fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId), before
                    )
                }
            }
        }
    }

    func testFullyVisibleWindowsIncludingExactScreenBoundsStillFocus() throws {
        for exactId in [false, true] {
            for frame in [
                CGRect(x: 400, y: 100, width: 300, height: 200),
                CGRect(x: 0, y: 0, width: 1_000, height: 800)
            ] {
                try withFixture { fixture in
                    fixture.hover(frame: frame, exactId: exactId)
                    XCTAssertEqual(fixture.recorder.tokens, [fixture.target.token])
                    XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.origin, .focusFollowsMouse)
                    XCTAssertEqual(
                        fixture.controller.mouseEventHandler.latestFocusFollowsMouseToken(), fixture.target.token
                    )
                }
            }
        }
    }

    func testVisibilityUsesRenderedCoordinatesAfterViewportTranslation() throws {
        let visible = CGRect(x: 400, y: 100, width: 300, height: 200)
        let partial = CGRect(x: 800, y: 100, width: 300, height: 200)
        for exactId in [false, true] {
            for (canonical, rendered) in [(partial, visible), (visible, partial)] {
                try withFixture { fixture in
                    fixture.hover(frame: canonical, renderedFrame: rendered, exactId: exactId)
                    if rendered == visible {
                        XCTAssertEqual(fixture.recorder.tokens, [fixture.target.token])
                        XCTAssertEqual(
                            fixture.controller.mouseEventHandler.latestFocusFollowsMouseToken(), fixture.target.token
                        )
                    } else {
                        XCTAssertTrue(fixture.recorder.tokens.isEmpty)
                        XCTAssertNil(fixture.controller.mouseEventHandler.latestFocusFollowsMouseToken())
                    }
                }
            }
        }
    }

    func testFullyVisibleWindowBeforeFirstRenderedFrameStillFocuses() throws {
        for exactId in [false, true] {
            try withFixture { fixture in
                let frame = CGRect(x: 400, y: 100, width: 300, height: 200)
                fixture.target.frame = frame
                fixture.target.renderedFrame = nil
                fixture.recorder.appliedFrames[fixture.target.token.windowId] = frame
                fixture.controller.mouseEventHandler.dispatchMouseMoved(
                    at: frame.center, windowIdUnderPointer: exactId ? fixture.target.token.windowId : nil
                )
                XCTAssertEqual(fixture.recorder.tokens, [fixture.target.token])
                XCTAssertEqual(
                    fixture.controller.mouseEventHandler.latestFocusFollowsMouseToken(),
                    fixture.target.token
                )
            }
        }
    }

    func testDisablingSettingRestoresPartialWindowHoverImmediately() throws {
        for exactId in [false, true] {
            try withFixture { fixture in
                let frame = CGRect(x: 800, y: 100, width: 300, height: 200)
                fixture.hover(frame: frame, exactId: exactId)
                XCTAssertTrue(fixture.recorder.tokens.isEmpty)
                fixture.controller.settings.focus.followsMouseOnlyFullyVisible = false
                fixture.hover(frame: frame, exactId: exactId)
                XCTAssertEqual(fixture.recorder.tokens, [fixture.target.token])
            }
        }
    }

    func testUsesTargetWorkspaceMonitorWithNegativeOrigin() throws {
        let origin = CGPoint(x: -1_000, y: -800)
        for exactId in [false, true] {
            try withFixture(origin: origin) { fixture in
                let frame = CGRect(x: -600, y: -700, width: 300, height: 200)
                fixture.hover(frame: frame, exactId: exactId)
                XCTAssertEqual(fixture.recorder.tokens, [fixture.target.token])
            }
            try withFixture(origin: origin) { fixture in
                let frame = CGRect(x: -100, y: -700, width: 300, height: 200)
                fixture.hover(frame: frame, exactId: exactId)
                XCTAssertTrue(fixture.recorder.tokens.isEmpty)
            }
        }
    }

    func testProgrammaticFocusCanStillRevealPartialWindow() throws {
        try withFixture { fixture in
            fixture.hover(frame: CGRect(x: 800, y: 100, width: 300, height: 200), exactId: true)
            XCTAssertTrue(fixture.recorder.tokens.isEmpty)
            fixture.controller.focusWindow(fixture.target.token)
            XCTAssertEqual(fixture.recorder.tokens, [fixture.target.token])
            XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.origin, .keyboardOrProgrammatic)
        }
    }

    func testClickOnPartialWindowStillPassesThroughAndRecordsFocusIntent() throws {
        try withFixture { fixture in
            let frame = CGRect(x: 800, y: 100, width: 300, height: 200)
            fixture.hover(frame: frame, exactId: true)
            XCTAssertTrue(fixture.recorder.tokens.isEmpty)
            let consumed = fixture.controller.mouseEventHandler.dispatchMouseDown(
                at: frame.intersection(fixture.monitor.frame).center, modifiers: [],
                windowIdUnderPointer: fixture.target.token.windowId
            )
            XCTAssertFalse(consumed)
            XCTAssertTrue(fixture.controller.axEventHandler.hasRecentMouseFocusIntent(for: fixture.target.token))
        }
    }

    func testMissingGeometryDoesNotFocusAnExactWindowId() throws {
        try withFixture { fixture in
            fixture.target.frame = nil
            fixture.target.renderedFrame = nil
            fixture.controller.mouseEventHandler.dispatchMouseMoved(
                at: CGPoint(x: 500, y: 200), windowIdUnderPointer: fixture.target.token.windowId
            )
            XCTAssertTrue(fixture.recorder.tokens.isEmpty)
            XCTAssertNil(fixture.controller.mouseEventHandler.latestFocusFollowsMouseToken())
        }
    }

    func testDwindleHoverIsUnaffected() throws {
        for exactId in [false, true] {
            try withFixture { fixture in
                let controller = fixture.controller
                controller.settings.workspaces.configurations = controller.settings.workspaces.configurations.map {
                    $0.name == "1" ? $0.with(layoutType: .dwindle) : $0
                }
                let engine = DwindleLayoutEngine()
                engine.animationClock = controller.animationClock
                controller.dwindleEngine = engine
                _ = engine.addWindow(token: fixture.target.token, to: fixture.workspaceId, activeWindowFrame: nil)
                let frame = try XCTUnwrap(engine.calculateLayout(
                    for: fixture.workspaceId, screen: fixture.monitor.frame
                )[fixture.target.token])
                controller.mouseEventHandler.dispatchMouseMoved(
                    at: frame.center, windowIdUnderPointer: exactId ? fixture.target.token.windowId : nil
                )
                XCTAssertEqual(fixture.recorder.tokens, [fixture.target.token])
            }
        }
    }

    func testSettledNiriLayoutRejectsPartialAndParkedColumnsInBothOrientations() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            for fraction in [0.7, 1.0] {
                for exactId in [false, true] {
                    try withFixture { fixture in
                        let controller = fixture.controller
                        let engine = try XCTUnwrap(controller.niriEngine)
                        controller.settings.monitors.updateOrientationSettings(
                            MonitorOrientationSettings(
                                monitorName: fixture.monitor.name,
                                monitorDisplayId: fixture.monitor.displayId,
                                orientation: orientation
                            ),
                            for: fixture.monitor
                        )
                        let workingFrame = controller.niriWorkingFrame(for: fixture.monitor)
                        let span = orientation == .horizontal ? workingFrame.width : workingFrame.height
                        for column in engine.columns(in: fixture.workspaceId) {
                            column.width = .fixed(span * fraction)
                            column.cachedWidth = span * fraction
                            column.height = .fixed(span * fraction)
                            column.cachedHeight = span * fraction
                        }
                        let before = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
                        let gap = controller.innerGap(for: fixture.monitor)
                        _ = engine.calculateLayout(
                            state: before, workspaceId: fixture.workspaceId,
                            monitorFrame: workingFrame, screenFrame: fixture.monitor.frame,
                            gaps: (horizontal: gap, vertical: gap), orientation: orientation, isSettled: true
                        )
                        let canonical = try XCTUnwrap(fixture.target.frame)
                        let rendered = try XCTUnwrap(fixture.target.renderedFrame)
                        XCTAssertFalse(fixture.monitor.frame.contains(canonical))
                        XCTAssertFalse(rendered.intersection(fixture.monitor.frame).isEmpty)
                        fixture.hover(frame: canonical, renderedFrame: rendered, exactId: exactId)
                        XCTAssertTrue(fixture.recorder.tokens.isEmpty)
                        XCTAssertNotEqual(
                            controller.mouseEventHandler.latestFocusFollowsMouseToken(),
                            fixture.target.token
                        )
                        XCTAssertEqual(controller.workspaceManager.niriViewportState(for: fixture.workspaceId), before)
                    }
                }
            }
        }
    }

    func testTwoVisibleHalfSizeColumnsFocusAfterScrollingPastEarlierColumns() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            for exactId in [false, true] {
                try withFixture { fixture in
                    let controller = fixture.controller
                    let engine = try XCTUnwrap(controller.niriEngine)
                    let manager = controller.workspaceManager
                    controller.settings.monitors.updateOrientationSettings(
                        MonitorOrientationSettings(
                            monitorName: fixture.monitor.name, monitorDisplayId: fixture.monitor.displayId,
                            orientation: orientation
                        ),
                        for: fixture.monitor
                    )
                    var previous = fixture.target
                    var added: [NiriWindow] = []
                    for index in 0 ..< 2 {
                        let token = WindowToken(pid: pid_t(986_110 + index), windowId: 986_210 + index)
                        _ = WindowAdmissionTestSupport.track(token, in: fixture.workspaceId, controller: controller)
                        previous = engine.addWindow(
                            token: token, to: fixture.workspaceId, afterSelection: previous.id
                        )
                        added.append(previous)
                    }
                    let workingFrame = controller.niriWorkingFrame(for: fixture.monitor)
                    let gap = controller.innerGap(for: fixture.monitor)
                    let span = orientation == .horizontal ? workingFrame.width : workingFrame.height
                    let halfSpan = (span - 3 * gap) / 2
                    for column in engine.columns(in: fixture.workspaceId) {
                        column.width = .fixed(halfSpan)
                        column.cachedWidth = halfSpan
                        column.height = .fixed(halfSpan)
                        column.cachedHeight = halfSpan
                    }
                    let state = ViewportState(
                        activeColumnIndex: 2, viewOffset: -gap, selectedNodeId: added[0].id
                    )
                    manager.updateNiriViewportState(state, for: fixture.workspaceId)
                    XCTAssertTrue(manager.confirmManagedFocus(
                        added[0].token, in: fixture.workspaceId, activateWorkspaceOnMonitor: false
                    ))
                    _ = engine.calculateLayout(
                        state: state, workspaceId: fixture.workspaceId,
                        monitorFrame: workingFrame, screenFrame: fixture.monitor.frame,
                        gaps: (horizontal: gap, vertical: gap), orientation: orientation, isSettled: true
                    )
                    let target = added[1]
                    XCTAssertFalse(fixture.monitor.frame.contains(try XCTUnwrap(target.frame)))
                    XCTAssertTrue(fixture.monitor.frame.contains(try XCTUnwrap(added[0].renderedFrame)))
                    let rendered = try XCTUnwrap(target.renderedFrame)
                    XCTAssertTrue(fixture.monitor.frame.contains(rendered))
                    fixture.recorder.appliedFrames[target.token.windowId] = rendered
                    controller.mouseEventHandler.dispatchMouseMoved(
                        at: rendered.center, windowIdUnderPointer: exactId ? target.token.windowId : nil
                    )
                    XCTAssertEqual(fixture.recorder.tokens, [target.token])
                    XCTAssertEqual(controller.mouseEventHandler.latestFocusFollowsMouseToken(), target.token)
                }
            }
        }
    }

    func testPartiallyOffscreenFloatingWindowStillFocuses() throws {
        try withFixture { fixture in
            let token = WindowToken(pid: 986_103, windowId: 986_203)
            let manager = fixture.controller.workspaceManager
            _ = manager.addWindow(
                WindowAdmissionTestSupport.axRef(for: token), pid: token.pid, windowId: token.windowId,
                to: fixture.workspaceId, mode: .floating
            )
            let frame = CGRect(x: 800, y: 100, width: 300, height: 200)
            manager.updateFloatingGeometry(frame: frame, for: token)
            fixture.controller.mouseEventHandler.dispatchMouseMoved(
                at: frame.intersection(fixture.monitor.frame).center, windowIdUnderPointer: token.windowId
            )
            XCTAssertEqual(fixture.recorder.tokens, [token])
        }
    }

    func testAppliedPlacementWinsWhileNewLayoutIsAwaitingFrameWrite() throws {
        let visible = CGRect(x: 600, y: 100, width: 300, height: 200)
        let partial = CGRect(x: 800, y: 100, width: 300, height: 200)
        for exactId in [false, true] {
            for (applied, planned) in [(partial, visible), (visible, partial)] {
                try withFixture { fixture in
                    let controller = fixture.controller
                    fixture.target.frame = planned
                    fixture.target.renderedFrame = planned
                    fixture.recorder.appliedFrames[fixture.target.token.windowId] = applied
                    controller.axManager.confirmFrameWrite(for: fixture.target.token.windowId, frame: applied)
                    let entry = try XCTUnwrap(controller.workspaceManager.entry(for: fixture.target.token))
                    XCTAssertNotNil(controller.axManager.stageFrameWrite(for: .init(
                        pid: entry.pid, window: entry.axRef, frame: planned
                    )))
                    defer {
                        controller.axManager.cancelPendingFrameJobs(
                            [(pid: entry.pid, windowId: entry.windowId)], reason: "test"
                        )
                    }
                    controller.mouseEventHandler.dispatchMouseMoved(
                        at: CGPoint(x: 850, y: 200),
                        windowIdUnderPointer: exactId ? entry.windowId : nil
                    )
                    if applied == visible {
                        XCTAssertEqual(fixture.recorder.tokens, [fixture.target.token])
                        XCTAssertEqual(
                            controller.mouseEventHandler.latestFocusFollowsMouseToken(),
                            fixture.target.token
                        )
                    } else {
                        XCTAssertTrue(fixture.recorder.tokens.isEmpty)
                        XCTAssertNil(controller.mouseEventHandler.latestFocusFollowsMouseToken())
                    }
                }
            }
        }
    }

    func testFallbackHitTestingUsesAppliedPositionInsteadOfFutureLayoutPosition() throws {
        try withFixture { fixture in
            fixture.target.frame = CGRect(x: 800, y: 100, width: 300, height: 200)
            fixture.target.renderedFrame = fixture.target.frame
            fixture.recorder.appliedFrames[fixture.target.token.windowId] = CGRect(
                x: 400, y: 100, width: 300, height: 200
            )
            fixture.controller.mouseEventHandler.dispatchMouseMoved(at: CGPoint(x: 500, y: 200))
            XCTAssertEqual(fixture.recorder.tokens, [fixture.target.token])
            XCTAssertEqual(fixture.controller.mouseEventHandler.latestFocusFollowsMouseToken(), fixture.target.token)
        }
    }

    func testMissingAppliedBoundsDoesNotTrustLayoutOrCachedPlacement() throws {
        for exactId in [false, true] {
            try withFixture { fixture in
                let visible = CGRect(x: 400, y: 100, width: 300, height: 200)
                fixture.target.frame = visible
                fixture.target.renderedFrame = visible
                fixture.controller.axManager.confirmFrameWrite(for: fixture.target.token.windowId, frame: visible)
                fixture.controller.mouseEventHandler.dispatchMouseMoved(
                    at: visible.center, windowIdUnderPointer: exactId ? fixture.target.token.windowId : nil
                )
                XCTAssertTrue(fixture.recorder.tokens.isEmpty)
                XCTAssertNil(fixture.controller.mouseEventHandler.latestFocusFollowsMouseToken())
            }
        }
    }

    func testExactTargetThatHasMovedAwayFromPointerDoesNotFocus() throws {
        try withFixture { fixture in
            let oldFrame = CGRect(x: 400, y: 100, width: 300, height: 200)
            fixture.target.frame = oldFrame
            fixture.target.renderedFrame = oldFrame
            fixture.recorder.appliedFrames[fixture.target.token.windowId] = oldFrame.offsetBy(dx: 0, dy: 300)
            fixture.controller.mouseEventHandler.dispatchMouseMoved(
                at: oldFrame.center, windowIdUnderPointer: fixture.target.token.windowId
            )
            XCTAssertTrue(fixture.recorder.tokens.isEmpty)
            XCTAssertNil(fixture.controller.mouseEventHandler.latestFocusFollowsMouseToken())
        }
    }

    func testDefaultModeDoesNotQueryAppliedBounds() throws {
        try withFixture { fixture in
            fixture.controller.settings.focus.followsMouseOnlyFullyVisible = false
            var queries = 0
            fixture.controller.mouseEventHandler.nativeWindowFrameProvider = { _ in
                queries += 1
                return nil
            }
            fixture.hover(frame: CGRect(x: 400, y: 100, width: 300, height: 200), exactId: false)
            XCTAssertEqual(fixture.recorder.tokens, [fixture.target.token])
            XCTAssertEqual(queries, 0)
        }
    }

    func testHoveringTheFocusedExactWindowSkipsTheBoundsQuery() throws {
        try withFixture { fixture in
            let focused = try XCTUnwrap(fixture.controller.workspaceManager.nativeManagedFocusToken)
            var queries = 0
            fixture.controller.mouseEventHandler.nativeWindowFrameProvider = { _ in
                queries += 1
                return nil
            }
            fixture.controller.mouseEventHandler.dispatchMouseMoved(
                at: fixture.monitor.frame.center, windowIdUnderPointer: focused.windowId
            )
            XCTAssertEqual(queries, 0)
            XCTAssertTrue(fixture.recorder.tokens.isEmpty)
        }
    }

    private func withFixture(
        origin: CGPoint = .zero,
        _ body: (Fixture) throws -> Void
    ) throws {
        let recorder = FocusRecorder()
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "FullyVisibleHoverFocusTests",
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    recorder.tokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        defer { controller.layoutRefreshController.resetState() }
        controller.settings.focus.followsMouseOnlyFullyVisible = true
        controller.mouseEventHandler.nativeWindowFrameProvider = { recorder.appliedFrames[$0.windowId] }
        controller.settings.niri.centerFocusedColumn = .never
        controller.motionPolicy.animationsEnabled = false
        let frame = CGRect(origin: origin, size: CGSize(width: 1_000, height: 800))
        let monitor = Monitor(
            id: .init(displayId: 986_001), displayId: 986_001,
            frame: frame, visibleFrame: frame, hasNotch: false, name: "Hover Target"
        )
        let other = Monitor(
            id: .init(displayId: 986_002), displayId: 986_002,
            frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
            hasNotch: false, name: "Other Monitor"
        )
        controller.settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1", monitorAssignment: .specificDisplay(OutputId(from: monitor)), layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "2", monitorAssignment: .specificDisplay(OutputId(from: other)), layoutType: .niri
            )
        ]
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([other, monitor])
        manager.applySettings()
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        _ = manager.focusWorkspace(named: "1")
        controller.setFocusFollowsMouse(true)
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        var nodes: [NiriWindow] = []
        for index in 0 ..< 2 {
            let token = WindowToken(pid: pid_t(986_101 + index), windowId: 986_201 + index)
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
            nodes.append(engine.addWindow(token: token, to: workspaceId, afterSelection: nodes.last?.id))
        }
        manager.updateNiriViewportState(
            ViewportState(activeColumnIndex: 0, viewOffset: 0, selectedNodeId: nodes[0].id), for: workspaceId
        )
        XCTAssertTrue(manager.confirmManagedFocus(nodes[0].token, in: workspaceId, activateWorkspaceOnMonitor: false))
        controller.layoutRefreshController.resetState()
        controller.layoutRefreshController.layoutState.activeRefreshTask = Task { @MainActor in }
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout, reason: .layoutCommand, affectedWorkspaceIds: [workspaceId]
        )
        try body(Fixture(
            controller: controller, workspaceId: workspaceId, monitor: monitor,
            target: nodes[1], recorder: recorder
        ))
    }
}
