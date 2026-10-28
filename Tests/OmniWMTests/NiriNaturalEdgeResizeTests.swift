// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriNaturalEdgeResizeTests: NiriInteractionTestCase {
    @MainActor
    private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let tokens: [WindowToken]

        var handler: MouseEventHandler {
            controller.mouseEventHandler
        }

        var manager: WorkspaceManager {
            controller.workspaceManager
        }

        var engine: NiriLayoutEngine {
            controller.niriEngine!
        }

        var phase: MouseInputState.NativeTitleBarDragPhase? {
            handler.state.nativeTitleBarDrag?.phase
        }

        var widest: CGFloat {
            controller.insetWorkingFrame(for: monitor).width - 2 * controller.innerGap(for: monitor)
        }

        func node(_ token: WindowToken) throws -> NiriWindow {
            try XCTUnwrap(engine.findNode(for: token, in: workspaceId))
        }

        func column(_ token: WindowToken) throws -> NiriContainer {
            try XCTUnwrap(engine.findColumn(containing: node(token), in: workspaceId))
        }

        func frames() -> [WindowToken: CGRect] {
            let gap = controller.innerGap(for: monitor)
            return engine.calculateLayout(
                state: manager.niriViewportState(for: workspaceId),
                workspaceId: workspaceId,
                monitorFrame: controller.insetWorkingFrame(for: monitor),
                gaps: (horizontal: gap, vertical: gap),
                orientation: .horizontal
            )
        }

        func frame(_ token: WindowToken) throws -> CGRect {
            try XCTUnwrap(frames()[token])
        }

        func settledFrame(_ token: WindowToken) throws -> CGRect {
            try frame(token, after: 10)
        }

        func frame(_ token: WindowToken, after seconds: TimeInterval) throws -> CGRect {
            let gap = controller.innerGap(for: monitor)
            let later = (engine.animationClock?.now() ?? CACurrentMediaTime()) + seconds
            return try XCTUnwrap(engine.calculateLayoutWithVisibility(
                state: manager.niriViewportState(for: workspaceId),
                workspaceId: workspaceId,
                monitorFrame: controller.insetWorkingFrame(for: monitor),
                gaps: (horizontal: gap, vertical: gap),
                orientation: .horizontal,
                animationTime: later
            ).frames[token])
        }

        func confirmLayout() {
            for (token, frame) in frames() {
                controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame)
            }
        }

        func beginDrag(_ token: WindowToken) throws {
            handler.retireNativeTitleBarDragAtInputBoundary()
            handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            let start = try frame(token)
            handler.nativeWindowFrameProvider = { _ in start }
            XCTAssertFalse(handler.dispatchMouseDown(
                at: start.center,
                modifiers: [],
                windowIdUnderPointer: token.windowId
            ))
            handler.dispatchMouseDragged(at: CGPoint(x: start.center.x + 5, y: start.center.y))
            XCTAssertEqual(phase, .dragging)
        }

        func drag(_ token: WindowToken, to observed: CGRect) {
            handler.nativeWindowFrameProvider = { _ in observed }
            controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
        }

        func release(at observed: CGRect) {
            handler.nativeWindowFrameProvider = { _ in observed }
            handler.dispatchMouseUp(at: observed.center)
        }
    }

    func testDuringAnEdgeDragNothingElseMoves() throws {
        let fixture = try makeFixture(pid: 871_001)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let frames = fixture.frames()
        let resized = fixture.tokens[1]
        try fixture.beginDrag(resized)

        for delta: CGFloat in [60, 140, 90] {
            fixture.drag(resized, to: grown(try XCTUnwrap(frames[resized]), right: delta))

            XCTAssertEqual(fixture.phase, .dragging)
            XCTAssertEqual(fixture.frames(), frames, "\(delta)")
            XCTAssertNil(fixture.engine.interactiveResize)
        }
    }

    func testReleasingARightEdgeDragWidensTheColumnAndMovesTheNeighbour() throws {
        let fixture = try makeFixture(pid: 871_002)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (resized, right) = (fixture.tokens[1], fixture.tokens[2])
        let start = try fixture.frame(resized)
        let rightStart = try fixture.frame(right)
        try fixture.beginDrag(resized)
        fixture.drag(resized, to: grown(start, right: 100))

        fixture.release(at: grown(start, right: 100))

        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertNil(fixture.engine.interactiveResize)
        XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
        let frame = try fixture.frame(resized)
        XCTAssertEqual(frame.minX, start.minX, accuracy: 1)
        XCTAssertEqual(frame.width, start.width + 100, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(right).minX, rightStart.minX + 100, accuracy: 1)
    }

    func testOnReleaseTheNeighboursSlideAndTheDraggedWindowDoesnt() throws {
        let fixture = try makeFixture(pid: 871_016)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (resized, right) = (fixture.tokens[1], fixture.tokens[2])
        let start = try fixture.frame(resized)
        let rightStart = try fixture.frame(right)
        try fixture.beginDrag(resized)
        fixture.drag(resized, to: grown(start, right: 100))

        fixture.release(at: grown(start, right: 100))

        XCTAssertTrue(try fixture.node(right).hasMoveAnimationsRunning)
        XCTAssertEqual(try fixture.frame(right).minX, rightStart.minX, accuracy: 1)
        XCTAssertFalse(try fixture.node(resized).hasMoveAnimationsRunning)
        XCTAssertEqual(try fixture.frame(resized).width, start.width + 100, accuracy: 1)
    }

    func testAStackMateSlidesItsNearEdgeAndKeepsItsFarEdgePut() throws {
        let fixture = try makeFixture(stacked: true, pid: 871_017)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, lower) = try upperAndLower(fixture)
        let upperStart = try fixture.frame(upper)
        let lowerStart = try fixture.frame(lower)
        try fixture.beginDrag(lower)
        fixture.drag(lower, to: grown(lowerStart, top: 100))

        fixture.release(at: grown(lowerStart, top: 100))

        XCTAssertTrue(try fixture.node(upper).hasMoveAnimationsRunning)
        XCTAssertFalse(try fixture.node(lower).hasMoveAnimationsRunning)
        XCTAssertEqual(try fixture.frame(upper), upperStart)
        let midway = try fixture.frame(upper, after: 0.08)
        XCTAssertEqual(midway.maxY, upperStart.maxY, accuracy: 1)
        XCTAssertLessThan(midway.height, upperStart.height - 1)
        XCTAssertGreaterThan(midway.height, upperStart.height - 99)
        let settled = try fixture.settledFrame(upper)
        XCTAssertEqual(settled.maxY, upperStart.maxY, accuracy: 1)
        XCTAssertEqual(settled.height, upperStart.height - 100, accuracy: 1)
    }

    func testAStackMateDoesntSlideSideways() throws {
        let fixture = try makeFixture(stacked: true, pid: 871_019)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, lower) = try upperAndLower(fixture)
        let upperStart = try fixture.frame(upper)
        let lowerStart = try fixture.frame(lower)
        try fixture.beginDrag(lower)
        fixture.drag(lower, to: grown(lowerStart, left: 80))

        fixture.release(at: grown(lowerStart, left: 80))

        let frame = try fixture.frame(upper)
        XCTAssertEqual(frame.maxX, upperStart.maxX, accuracy: 1)
        XCTAssertEqual(frame.width, upperStart.width + 80, accuracy: 1)
    }

    func testWithoutNaturalWindowDragNothingSlides() throws {
        let fixture = try makeFixture(pid: 871_018)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        fixture.controller.settings.niri.naturalWindowDrag = false
        fixture.controller.settings.gestures.adoptNativeResize = true
        let (resized, right) = (fixture.tokens[1], fixture.tokens[2])
        let start = try fixture.frame(resized)
        try fixture.beginDrag(resized)
        fixture.drag(resized, to: grown(start, right: 100))

        fixture.release(at: grown(start, right: 100))

        XCTAssertFalse(try fixture.node(right).hasMoveAnimationsRunning)
    }

    func testReleasingALeftEdgeDragKeepsTheRightSidePut() throws {
        let fixture = try makeFixture(pid: 871_003)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (left, resized) = (fixture.tokens[0], fixture.tokens[1])
        let start = try fixture.frame(resized)
        let leftStart = try fixture.frame(left)
        try fixture.beginDrag(resized)
        fixture.drag(resized, to: grown(start, left: 80))

        fixture.release(at: grown(start, left: 80))

        let frame = try fixture.frame(resized)
        XCTAssertEqual(frame.maxX, start.maxX, accuracy: 1)
        XCTAssertEqual(frame.width, start.width + 80, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(left).maxX, leftStart.maxX - 80, accuracy: 1)
    }

    func testReleasingDoesntMoveTheView() throws {
        for (pid, edges) in [
            (pid_t(871_004), (left: CGFloat(0), right: CGFloat(250))),
            (871_005, (left: 250, right: 0))
        ] {
            let fixture = try makeFixture(pid: pid)
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let resized = fixture.tokens[1]
            let start = try fixture.frame(resized)
            let viewport = fixture.manager.niriViewportState(for: fixture.workspaceId)
            let grownFrame = grown(start, left: edges.left, right: edges.right)
            try fixture.beginDrag(resized)
            fixture.drag(resized, to: grownFrame)

            fixture.release(at: grownFrame)

            let settled = fixture.manager.niriViewportState(for: fixture.workspaceId)
            XCTAssertEqual(settled.activeColumnIndex, viewport.activeColumnIndex, "\(edges)")
            if edges.left == 0 {
                XCTAssertEqual(settled.viewOffset, viewport.viewOffset, accuracy: 0.5, "\(edges)")
            }
            XCTAssertEqual(try fixture.frame(resized).minX, grownFrame.minX, accuracy: 1, "\(edges)")
            XCTAssertEqual(try fixture.frame(resized).maxX, grownFrame.maxX, accuracy: 1, "\(edges)")
        }
    }

    func testReleasingAStackedWindowsTopEdgeMakesTheOtherGiveWay() throws {
        let fixture = try makeFixture(stacked: true, pid: 871_006)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, lower) = try upperAndLower(fixture)
        let upperStart = try fixture.frame(upper)
        let lowerStart = try fixture.frame(lower)
        try fixture.beginDrag(lower)
        fixture.drag(lower, to: grown(lowerStart, top: 100))

        fixture.release(at: grown(lowerStart, top: 100))

        XCTAssertEqual(try fixture.frame(lower).height, lowerStart.height + 100, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(upper).height, upperStart.height - 100, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(upper).maxY, upperStart.maxY, accuracy: 1)
    }

    func testReleasingAStackedWindowsBottomEdgeMakesTheOtherGiveWay() throws {
        let fixture = try makeFixture(stacked: true, pid: 871_007)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, lower) = try upperAndLower(fixture)
        let upperStart = try fixture.frame(upper)
        let lowerStart = try fixture.frame(lower)
        try fixture.beginDrag(upper)
        fixture.drag(upper, to: grown(upperStart, bottom: 100))

        fixture.release(at: grown(upperStart, bottom: 60))

        XCTAssertEqual(try fixture.frame(upper).height, upperStart.height + 60, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(lower).height, lowerStart.height - 60, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(lower).minY, lowerStart.minY, accuracy: 1)
    }

    func testALoneWindowKeepsTheReleasedHeight() throws {
        let fixture = try makeFixture(pid: 871_008)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let lone = fixture.tokens[1]
        let start = try fixture.frame(lone)
        let shorter = grown(start, top: -150)
        try fixture.beginDrag(lone)
        fixture.drag(lone, to: shorter)

        fixture.release(at: shorter)

        XCTAssertEqual(try fixture.frame(lone).height, start.height - 150, accuracy: 1)
        XCTAssertFalse(try fixture.node(lone).height.isAuto)
    }

    func testATabbedColumnsHeightIgnoresATopEdgeDrag() throws {
        let fixture = try makeFixture(stacked: true, pid: 871_009)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let shown = fixture.tokens[0]
        let column = try fixture.column(shown)
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { _ in
            fixture.engine.toggleColumnTabbed(
                column,
                in: fixture.workspaceId,
                motion: .disabled,
                orientation: .horizontal
            )
        }
        XCTAssertTrue(column.isTabbed)
        fixture.confirmLayout()
        let start = try fixture.frame(shown)
        try fixture.beginDrag(shown)
        fixture.drag(shown, to: grown(start, top: -150))

        fixture.release(at: grown(start, top: -150))

        XCTAssertEqual(try fixture.frame(shown), start)
    }

    func testACornerDragIsAdoptedBothWays() throws {
        let fixture = try makeFixture(stacked: true, pid: 871_010)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, lower) = try upperAndLower(fixture)
        let lowerStart = try fixture.frame(lower)
        let upperStart = try fixture.frame(upper)
        let corner = grown(lowerStart, right: 80, top: 100)
        try fixture.beginDrag(lower)
        fixture.drag(lower, to: corner)

        fixture.release(at: corner)

        let frame = try fixture.frame(lower)
        XCTAssertEqual(frame.width, lowerStart.width + 80, accuracy: 1)
        XCTAssertEqual(frame.height, lowerStart.height + 100, accuracy: 1)
        XCTAssertEqual(try fixture.frame(upper).width, upperStart.width + 80, accuracy: 1)
    }

    func testTheWidthStopsAtTheWidestColumn() throws {
        let fixture = try makeFixture(pid: 871_011)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let resized = fixture.tokens[1]
        let start = try fixture.frame(resized)
        try fixture.beginDrag(resized)
        fixture.drag(resized, to: grown(start, right: 5000))

        fixture.release(at: grown(start, right: 5000))

        XCTAssertEqual(try fixture.frame(resized).width, fixture.widest, accuracy: 1)
        XCTAssertEqual(fixture.phase, .awaitingCorrection)
    }

    func testATitleBarDragStaysALiveColumnMove() throws {
        let fixture = try makeFixture(pid: 871_012)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let moved = fixture.tokens[1]
        let start = try fixture.frame(moved)
        try fixture.beginDrag(moved)

        fixture.drag(moved, to: start.offsetBy(dx: 60, dy: 0))

        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertNil(fixture.engine.interactiveResize)
    }

    func testKeepNativeEdgeResizesAloneStillAdopts() throws {
        let fixture = try makeFixture(pid: 871_015)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        fixture.controller.settings.niri.naturalWindowDrag = false
        fixture.controller.settings.gestures.adoptNativeResize = true
        let resized = fixture.tokens[1]
        let start = try fixture.frame(resized)
        try fixture.beginDrag(resized)
        fixture.drag(resized, to: grown(start, right: 100))

        fixture.release(at: grown(start, right: 100))

        XCTAssertEqual(try fixture.column(resized).cachedWidth, start.width + 100, accuracy: 1)
    }

    func testWithTheSettingOffAnEdgeDragIsntAdopted() throws {
        let fixture = try makeFixture(pid: 871_013)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        fixture.controller.settings.niri.naturalWindowDrag = false
        let (resized, right) = (fixture.tokens[1], fixture.tokens[2])
        let start = try fixture.frame(resized)
        let rightStart = try fixture.frame(right)
        try fixture.beginDrag(resized)
        fixture.drag(resized, to: grown(start, right: 100))

        fixture.release(at: grown(start, right: 100))

        XCTAssertEqual(try fixture.frame(resized), start)
        XCTAssertEqual(try fixture.frame(right), rightStart)
    }

    private func upperAndLower(_ fixture: Fixture) throws -> (WindowToken, WindowToken) {
        let (first, second) = (fixture.tokens[0], fixture.tokens[1])
        return try fixture.frame(first).midY > fixture.frame(second).midY ? (first, second) : (second, first)
    }

    private func grown(
        _ frame: CGRect,
        left: CGFloat = 0,
        right: CGFloat = 0,
        bottom: CGFloat = 0,
        top: CGFloat = 0
    ) -> CGRect {
        CGRect(
            x: frame.minX - left,
            y: frame.minY - bottom,
            width: frame.width + left + right,
            height: frame.height + bottom + top
        )
    }

    private func blockRefreshes(_ fixture: Fixture) -> Task<Void, Never> {
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [fixture.workspaceId]
        )
        return blocker
    }

    private func unblockRefreshes(_ fixture: Fixture, blocker: Task<Void, Never>) {
        blocker.cancel()
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = nil
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = nil
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
    }

    private func makeFixture(stacked: Bool = false, pid: pid_t) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "NiriNaturalEdgeResizeTests")
        addTeardownBlock { @MainActor [controller] in
            controller.hasStartedServices = false
            controller.layoutRefreshController.resetState()
            controller.mouseEventHandler.cleanup()
            controller.surfaceReconciler.cleanup()
            controller.axManager.cleanup()
        }
        let monitor = Monitor(
            id: .init(displayId: 87_101),
            displayId: 87_101,
            frame: workingFrame,
            visibleFrame: workingFrame,
            hasNotch: false,
            name: "Niri Live Edge Resize"
        )
        controller.settings.niri.naturalWindowDrag = true
        controller.settings.gestures.adoptNativeResize = false
        controller.settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .niri
            )
        ]
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let tokens = (0 ..< 3).map { WindowToken(pid: pid, windowId: Int(pid) + 100 + $0) }
        for token in tokens {
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        }
        controller.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let first = engine.addWindow(token: tokens[0], to: workspaceId, afterSelection: nil)
        if stacked {
            controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
                engine.attachTransferredWindow(
                    NiriWindow(token: tokens[1]),
                    stackedWith: first,
                    after: true,
                    in: workspaceId,
                    state: &state
                )
            }
            _ = engine.addWindow(token: tokens[2], to: workspaceId, afterSelection: first.id)
        } else {
            let second = engine.addWindow(token: tokens[1], to: workspaceId, afterSelection: first.id)
            _ = engine.addWindow(token: tokens[2], to: workspaceId, afterSelection: second.id)
        }
        for column in engine.columns(in: workspaceId) {
            column.width = .proportion(1.0 / 3.0)
            column.cachedWidth = 0
        }
        let fixture = Fixture(controller: controller, workspaceId: workspaceId, monitor: monitor, tokens: tokens)
        let frames = fixture.frames()
        fixture.confirmLayout()
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard let token = tokens.first(where: { $0.windowId == Int(windowId) }) else { return nil }
            return WindowServerInfo(id: windowId, pid: token.pid, level: 0, frame: frames[token] ?? .zero)
        }
        controller.layoutRefreshController.resetState()
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        controller.hasStartedServices = true
        return fixture
    }
}
