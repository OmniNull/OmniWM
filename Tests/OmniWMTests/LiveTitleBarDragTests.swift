// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import CoreGraphics
@testable import OmniWM
import QuartzCore
import XCTest

private final class DragClock {
    var now: TimeInterval = 1_000
}

private final class ReportedFrame {
    var frame: CGRect?

    init(_ frame: CGRect?) {
        self.frame = frame
    }
}

@MainActor
final class LiveTitleBarDragTests: NiriInteractionTestCase {
    @MainActor
    private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let tokens: [WindowToken]
        let reported = ReportedFrame(nil)

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

        func entry(_ token: WindowToken) throws -> WindowState {
            try XCTUnwrap(manager.entry(for: token))
        }

        func order() -> [WindowToken] {
            engine.columns(in: workspaceId).compactMap { $0.windowNodes.first?.token }
        }

        func landingOrder() -> [WindowToken] {
            guard let move = engine.liveColumnMove, engine.liveDropSpace(for: move) != nil else { return order() }
            return engine.columns(in: workspaceId).compactMap { column in
                if column.isLiveDropSpace { return move.windowToken }
                let token = column.windowNodes.first?.token
                return token == move.windowToken ? nil : token
            }
        }

        func frames(animationTime: TimeInterval? = nil) throws -> [WindowToken: CGRect] {
            if manager.activeLayoutKind(for: workspaceId) == .dwindle {
                let engine = try XCTUnwrap(controller.dwindleEngine)
                return engine.calculateLayout(
                    for: workspaceId,
                    screen: controller.insetWorkingFrame(for: monitor),
                    calculationSettings: controller.dwindleLayoutHandler.calculationSettings(
                        controller.resolvedDwindleSettings(for: monitor),
                        from: engine
                    )
                )
            }
            let gap = controller.innerGap(for: monitor)
            return try XCTUnwrap(controller.niriEngine).calculateLayoutWithVisibility(
                state: manager.niriViewportState(for: workspaceId),
                workspaceId: workspaceId,
                monitorFrame: controller.insetWorkingFrame(for: monitor),
                gaps: (horizontal: gap, vertical: gap),
                orientation: controller.settings.monitors.effectiveOrientation(for: monitor),
                animationTime: animationTime
            ).frames
        }

        func settledFrame(_ token: WindowToken) throws -> CGRect {
            try XCTUnwrap(frames(animationTime: CACurrentMediaTime() + 60)[token])
        }

        func frame(_ token: WindowToken) throws -> CGRect {
            try XCTUnwrap(frames()[token])
        }

        func confirmLayout() throws {
            for (token, frame) in try frames() {
                controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame)
            }
        }

        func beginDrag(_ token: WindowToken) throws {
            handler.retireNativeTitleBarDragAtInputBoundary()
            handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            let start = try frame(token)
            reported.frame = start
            handler.nativeWindowFrameProvider = { [reported] _ in reported.frame }
            XCTAssertFalse(handler.dispatchMouseDown(
                at: CGPoint(x: start.midX, y: start.maxY - 10),
                modifiers: [],
                windowIdUnderPointer: token.windowId
            ))
            handler.dispatchMouseDragged(at: CGPoint(x: start.midX + 5, y: start.maxY - 10))
            XCTAssertEqual(phase, .dragging)
        }

        func macOSMoves(_ token: WindowToken, to frame: CGRect) throws {
            reported.frame = frame
            XCTAssertTrue(handler.handleNativeTitleBarDragFrameChanged(for: try entry(token)))
        }

        func press(_ token: WindowToken, reportsWindowUnderPointer: Bool = true) throws -> CGPoint {
            handler.retireNativeTitleBarDragAtInputBoundary()
            handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            let start = try frame(token)
            reported.frame = start
            handler.nativeWindowFrameProvider = { [reported] _ in reported.frame }
            let visible = start.intersection(controller.insetWorkingFrame(for: monitor))
            let location = CGPoint(x: visible.midX, y: start.maxY - 10)
            XCTAssertFalse(handler.dispatchMouseDown(
                at: location,
                modifiers: [],
                windowIdUnderPointer: reportsWindowUnderPointer ? token.windowId : nil
            ))
            return location
        }

        func startLiveDrag(_ token: WindowToken) throws {
            try beginDrag(token)
            let start = try frame(token)
            try macOSMoves(token, to: start.offsetBy(dx: 30, dy: 0))
        }

        func drag(to point: CGPoint) {
            handler.dispatchMouseDragged(at: point)
        }

        func centre(of token: WindowToken) throws -> CGPoint {
            let frame = try frame(token)
            return CGPoint(x: frame.midX, y: frame.midY)
        }

        func farHalf(of token: WindowToken) throws -> CGPoint {
            let frame = try frame(token)
            let columns = engine.columns(in: workspaceId)
            guard let move = engine.liveColumnMove,
                  let home = columns.firstIndex(where: { $0.windowNodes.contains { $0.id == move.windowId } }),
                  let target = columns.firstIndex(where: { $0.windowNodes.contains { $0.token == token } }),
                  home != target
            else { return CGPoint(x: frame.midX, y: frame.midY) }
            let working = controller.insetWorkingFrame(for: monitor)
            let minX = max(frame.minX, working.minX)
            let maxX = min(frame.maxX, working.maxX)
            let quarter = (maxX - minX) / 4
            return CGPoint(x: target > home ? maxX - quarter : minX + quarter, y: frame.midY)
        }
    }

    func testSettingOffKeepsSnappingTitleBarDragsBack() throws {
        let fixture = try makeFixture(pid: 938_001)
        fixture.controller.settings.niri.naturalWindowDrag = false
        let order = fixture.order()

        try fixture.startLiveDrag(fixture.tokens[1])
        fixture.drag(to: try fixture.farHalf(of: fixture.tokens[2]))
        fixture.handler.dispatchMouseUp(at: try fixture.centre(of: fixture.tokens[2]))

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertEqual(fixture.order(), order)
        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertFalse(fixture.handler.liveDragEscapeCapture.isActive)
    }

    func testDwindleTitleBarDragsStartNoLiveDragAndStillSnapBack() throws {
        let fixture = try makeFixture(pid: 938_050, windowCount: 3, layout: .dwindle)
        XCTAssertTrue(fixture.controller.settings.niri.naturalWindowDrag)
        XCTAssertEqual(fixture.manager.activeLayoutKind(for: fixture.workspaceId), .dwindle)
        XCTAssertNotNil(fixture.controller.niriEngine?.findNode(for: fixture.tokens[0], in: fixture.workspaceId))
        let (dragged, other) = (fixture.tokens[0], fixture.tokens[1])
        let frames = try fixture.frames()

        try fixture.startLiveDrag(dragged)
        fixture.drag(to: try fixture.farHalf(of: other))

        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertNil(fixture.controller.niriEngine?.liveColumnMove)
        XCTAssertFalse(fixture.handler.liveDragEscapeCapture.isActive)
        XCTAssertNil(fixture.handler.state.deferredClickScroll)

        fixture.handler.dispatchMouseUp(at: try fixture.centre(of: other))

        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertEqual(try fixture.frames(), frames)
        XCTAssertFalse(fixture.handler.liveDragEscapeCapture.isActive)
    }

    func testMacOSMovingTheWindowStartsALiveDragThatSwapsColumns() throws {
        let fixture = try makeFixture(pid: 938_002)
        let (dragged, neighbour) = (fixture.tokens[1], fixture.tokens[2])

        try fixture.startLiveDrag(dragged)

        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertTrue(fixture.handler.liveDragEscapeCapture.isActive)
        XCTAssertNotNil(fixture.engine.liveColumnMove)

        fixture.drag(to: try fixture.farHalf(of: neighbour))

        XCTAssertEqual(fixture.landingOrder(), [0, 2, 1, 3].map { fixture.tokens[$0] })
        XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, 1)
    }

    func testResizesAndDragsWithoutAFrameChangeStartNoLiveDrag() throws {
        let fixture = try makeFixture(pid: 938_003)
        let dragged = fixture.tokens[1]
        let order = fixture.order()

        try fixture.beginDrag(dragged)
        let start = try fixture.frame(dragged)
        fixture.drag(to: try fixture.farHalf(of: fixture.tokens[2]))
        XCTAssertNil(fixture.engine.liveColumnMove)

        try fixture.macOSMoves(dragged, to: CGRect(
            x: start.minX, y: start.minY, width: start.width + 120, height: start.height
        ))
        fixture.drag(to: try fixture.farHalf(of: fixture.tokens[2]))

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.order(), order)
    }

    func testStackedWindowsKeepSnappingBack() throws {
        let fixture = try makeFixture(pid: 938_004, stackFirstTwo: true)
        let dragged = fixture.tokens[0]

        try fixture.startLiveDrag(dragged)

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.liveDragDeclined, true)
    }

    func testReleaseDropsTheWindowIntoItsNewSlot() throws {
        let fixture = try makeFixture(pid: 938_005)
        let (dragged, neighbour) = (fixture.tokens[1], fixture.tokens[2])
        try fixture.startLiveDrag(dragged)
        let drop = try fixture.centre(of: neighbour)
        fixture.drag(to: drop)
        let order = fixture.landingOrder()

        fixture.handler.dispatchMouseUp(at: drop)

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertFalse(fixture.handler.liveDragEscapeCapture.isActive)
        XCTAssertNil(fixture.handler.state.liveDropScroll)
        XCTAssertEqual(fixture.order(), order)
        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertEqual(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.affectedWorkspaceIds,
            [fixture.workspaceId]
        )
        XCTAssertEqual(
            fixture.manager.niriViewportState(for: fixture.workspaceId).selectedNodeId,
            fixture.engine.findNode(for: dragged, in: fixture.workspaceId)?.id
        )
    }

    func testEscRestoresTheLayoutAndIsNotPassedOn() throws {
        let fixture = try makeFixture(pid: 938_006)
        let (dragged, neighbour) = (fixture.tokens[1], fixture.tokens[2])
        let order = fixture.order()
        let offset = fixture.manager.niriViewportState(for: fixture.workspaceId).viewOffset
        try fixture.startLiveDrag(dragged)
        fixture.drag(to: try fixture.farHalf(of: neighbour))
        XCTAssertNotEqual(fixture.landingOrder(), order)

        let capture = fixture.handler.liveDragEscapeCapture
        XCTAssertFalse(capture.consumesKeyEvent(type: .keyDown, keyCode: Int64(kVK_ANSI_A)))
        XCTAssertTrue(capture.consumesKeyEvent(type: .keyDown, keyCode: Int64(kVK_Escape)))
        let drained = expectation(description: "Escape handled")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)

        XCTAssertEqual(fixture.order(), order)
        XCTAssertEqual(
            fixture.manager.niriViewportState(for: fixture.workspaceId).viewOffset,
            offset,
            accuracy: 0.001
        )
        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertFalse(capture.isActive)
        XCTAssertTrue(capture.consumesKeyEvent(type: .keyUp, keyCode: Int64(kVK_Escape)))
        XCTAssertFalse(capture.consumesKeyEvent(type: .keyUp, keyCode: Int64(kVK_Escape)))
        XCTAssertFalse(capture.consumesKeyEvent(type: .keyDown, keyCode: Int64(kVK_Escape)))

        try fixture.macOSMoves(dragged, to: try fixture.frame(dragged).offsetBy(dx: 60, dy: 0))
        fixture.drag(to: try fixture.farHalf(of: neighbour))
        XCTAssertNil(fixture.engine.liveColumnMove)
        fixture.handler.dispatchMouseUp(at: try fixture.centre(of: neighbour))
        XCTAssertEqual(fixture.order(), order)
        XCTAssertEqual(fixture.phase, .awaitingCorrection)
    }

    func testOtherCancelsRestoreTheLayout() throws {
        for cancel in ["interaction", "pointer leaves the display"] {
            let fixture = try makeFixture(pid: cancel == "interaction" ? 938_007 : 938_008)
            let order = fixture.order()
            try fixture.startLiveDrag(fixture.tokens[1])
            fixture.drag(to: try fixture.farHalf(of: fixture.tokens[2]))
            XCTAssertNotEqual(fixture.landingOrder(), order, cancel)

            if cancel == "interaction" {
                fixture.handler.cancelActiveMouseInteraction()
            } else {
                fixture.drag(to: CGPoint(x: workingFrame.maxX + 2_000, y: workingFrame.midY))
            }

            XCTAssertEqual(fixture.order(), order, cancel)
            XCTAssertNil(fixture.engine.liveColumnMove, cancel)
            XCTAssertFalse(fixture.handler.isLiveColumnDragActive, cancel)
            XCTAssertFalse(fixture.handler.liveDragEscapeCapture.isActive, cancel)
        }
    }

    func testThePointerOnTheDisplaysOwnEdgesKeepsTheDrag() throws {
        let fixture = try makeFixture(pid: 938_011)
        let frame = fixture.monitor.frame
        try fixture.startLiveDrag(fixture.tokens[1])
        fixture.drag(to: try fixture.farHalf(of: fixture.tokens[2]))
        XCTAssertNotEqual(fixture.landingOrder(), [0, 1, 2, 3].map { fixture.tokens[$0] })

        for point in [
            CGPoint(x: frame.maxX, y: frame.midY),
            CGPoint(x: frame.minX, y: frame.midY),
            CGPoint(x: frame.midX, y: frame.maxY),
            CGPoint(x: frame.maxX, y: frame.maxY)
        ] {
            fixture.drag(to: point)
            XCTAssertTrue(fixture.handler.isLiveColumnDragActive, "\(point)")
            XCTAssertNotNil(fixture.engine.liveColumnMove, "\(point)")
        }

        fixture.drag(to: CGPoint(x: frame.maxX + 1, y: frame.midY))

        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertEqual(fixture.order(), [0, 1, 2, 3].map { fixture.tokens[$0] })
    }

    func testDraggingOverOmniWMsOwnEdgeMaskKeepsTheDrag() throws {
        let fixture = try makeFixture(pid: 938_012)
        let frame = fixture.monitor.frame
        let mask = CGRect(x: frame.maxX - 6, y: frame.minY, width: 6, height: frame.height)
        fixture.controller.ownedWindowRegistry.registerWindowNumber(
            surfaceId: "live-drag-edge-mask-test",
            policy: SurfacePolicy(
                kind: .parkingEdgeMask, hitTestPolicy: .interactive, capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            ),
            windowNumber: 938_012, frameProvider: { mask }, visibilityProvider: { true }
        )
        defer { fixture.controller.ownedWindowRegistry.unregister(surfaceId: "live-drag-edge-mask-test") }
        let overMask = CGPoint(x: mask.midX, y: mask.midY)
        XCTAssertTrue(fixture.handler.shouldBlockOwnWindowInput(at: overMask))
        try fixture.startLiveDrag(fixture.tokens[1])
        fixture.drag(to: try fixture.farHalf(of: fixture.tokens[2]))

        fixture.drag(to: overMask)
        fixture.handler.dispatchQueuedMouseDragged(at: overMask, button: .left)

        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertNotNil(fixture.engine.liveColumnMove)
        XCTAssertNotEqual(fixture.landingOrder(), [0, 1, 2, 3].map { fixture.tokens[$0] })
    }

    func testTheHoverDelayTimerMovesTheColumnWhileThePointerIsStill() throws {
        let fixture = try makeFixture(pid: 938_013, hoverDelay: 0.12)
        let clock = DragClock()
        fixture.handler.liveDragClock = { clock.now }
        try fixture.startLiveDrag(fixture.tokens[1])
        let order = fixture.order()
        let target = try fixture.farHalf(of: fixture.tokens[2])

        fixture.drag(to: target)

        XCTAssertEqual(fixture.order(), order)
        XCTAssertNotNil(fixture.handler.state.liveHoverTimer)
        clock.now += 0.12
        fixture.handler.updateLiveColumnDrag(at: target)
        XCTAssertEqual(fixture.landingOrder(), [0, 2, 1, 3].map { fixture.tokens[$0] })
        XCTAssertNil(fixture.handler.state.liveHoverTimer)
    }

    func testReleaseOrCancelWhileHoveringStopsTheHoverTimer() throws {
        for ending in ["release", "cancel"] {
            let fixture = try makeFixture(pid: ending == "release" ? 938_014 : 938_015, hoverDelay: 0.12)
            fixture.handler.liveDragClock = { 1_000 }
            try fixture.startLiveDrag(fixture.tokens[1])
            let order = fixture.order()
            let target = try fixture.farHalf(of: fixture.tokens[2])
            fixture.drag(to: target)
            XCTAssertNotNil(fixture.handler.state.liveHoverTimer, ending)

            if ending == "release" {
                fixture.handler.dispatchMouseUp(at: target)
            } else {
                fixture.handler.cancelLiveColumnDrag()
            }

            XCTAssertNil(fixture.handler.state.liveHoverTimer, ending)
            XCTAssertEqual(fixture.order(), order, ending)
        }
    }

    func testScrollWheelDoesNotMoveTheStripDuringALiveDrag() throws {
        let fixture = try makeFixture(pid: 938_009)
        fixture.controller.settings.gestures.scrollEnabled = true
        try fixture.startLiveDrag(fixture.tokens[1])
        let offset = fixture.manager.niriViewportState(for: fixture.workspaceId).viewOffset

        fixture.handler.dispatchScrollWheel(MouseScrollIntake(
            location: try fixture.centre(of: fixture.tokens[1]),
            deltaX: 0,
            deltaY: -600,
            momentumPhase: 0,
            phase: 0,
            modifiersRawValue: fixture.controller.settings.gestures.scrollModifierKey.cgEventFlag.rawValue
        ))

        XCTAssertEqual(fixture.manager.niriViewportState(for: fixture.workspaceId).viewOffset, offset)
        XCTAssertTrue(fixture.controller.isInteractiveGestureActive)
    }

    func testPressingAPartlyVisibleWindowDoesNotScrollUntilAClickIsReleased() async throws {
        for (index, reportsWindow) in [true, false].enumerated() {
            try await assertPressDoesNotScroll(
                pid: pid_t(938_014 + index * 10),
                reportsWindowUnderPointer: reportsWindow
            )
        }
    }

    private func assertPressDoesNotScroll(pid: pid_t, reportsWindowUnderPointer: Bool) async throws {
        let fixture = try makeFixture(pid: pid, windowCount: 5)
        let target = fixture.tokens[3]
        try scroll(fixture, so: target, isHalfOffTheRightEdge: ())
        let before = try fixture.settledFrame(target)

        let press = try fixture.press(target, reportsWindowUnderPointer: reportsWindowUnderPointer)
        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: try fixture.entry(target), isWorkspaceActive: true, appFullscreen: false
        )
        try await drainRefreshes(fixture)

        let pressed = fixture.manager.niriViewportState(for: fixture.workspaceId)
        XCTAssertEqual(try fixture.settledFrame(target).minX, before.minX, accuracy: 0.5)
        XCTAssertEqual(pressed.selectedNodeId, fixture.engine.findNode(for: target, in: fixture.workspaceId)?.id)
        XCTAssertEqual(fixture.handler.state.deferredClickScroll, target)

        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.dispatchMouseUp(at: press)
        try await drainRefreshes(fixture)

        XCTAssertNil(fixture.handler.state.deferredClickScroll)
        XCTAssertNotEqual(try fixture.settledFrame(target).minX, before.minX)
        XCTAssertLessThanOrEqual(try fixture.settledFrame(target).maxX, workingFrame.maxX + 1)
    }

    func testALostMouseUpDoesNotKeepHoldingTheSelectionScroll() throws {
        let fixture = try makeFixture(pid: 938_016)
        fixture.handler.state.deferredClickScroll = fixture.tokens[1]
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        XCTAssertTrue(fixture.handler.holdsSelectionScroll(in: fixture.workspaceId))

        fixture.handler.pressedMouseButtonsProvider = { 0 }

        XCTAssertFalse(fixture.handler.holdsSelectionScroll(in: fixture.workspaceId))
    }

    func testWithTheSettingOffAClickStillScrollsAtOnce() throws {
        let fixture = try makeFixture(pid: 938_015, windowCount: 5)
        fixture.controller.settings.niri.naturalWindowDrag = false
        let target = fixture.tokens[3]
        try scroll(fixture, so: target, isHalfOffTheRightEdge: ())
        let before = try fixture.settledFrame(target)

        _ = try fixture.press(target)
        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: try fixture.entry(target), isWorkspaceActive: true, appFullscreen: false
        )

        XCTAssertNotEqual(try fixture.settledFrame(target).minX, before.minX)
        XCTAssertNil(fixture.handler.state.deferredClickScroll)
    }

    func testAPressThatBecomesALiveDragDropsTheDeferredClickScroll() throws {
        let fixture = try makeFixture(pid: 938_016, windowCount: 5)
        let target = fixture.tokens[3]
        try scroll(fixture, so: target, isHalfOffTheRightEdge: ())
        let press = try fixture.press(target)
        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: try fixture.entry(target), isWorkspaceActive: true, appFullscreen: false
        )
        XCTAssertEqual(fixture.handler.state.deferredClickScroll, target)

        fixture.drag(to: CGPoint(x: press.x - 5, y: press.y))
        try fixture.macOSMoves(target, to: try fixture.frame(target).offsetBy(dx: -30, dy: 0))

        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertNil(fixture.handler.state.deferredClickScroll)
    }

    func testHitTestGeometryMatchesTheAppLayout() throws {
        let fixture = try makeFixture(pid: 938_011, windowCount: 5)
        let geometry = fixture.controller.niriInteractionGeometry(for: fixture.monitor)
        let context = NiriInteractionContext(
            workspaceId: fixture.workspaceId,
            motion: .disabled,
            workingFrame: geometry.workingFrame,
            gaps: geometry.innerGap,
            orientation: .horizontal
        )
        let strip = fixture.engine.liveColumnStrip(
            context: context,
            state: fixture.manager.niriViewportState(for: fixture.workspaceId)
        )
        let frames = try fixture.frames()
        var compared = 0
        for column in strip {
            let token = column.column.windowNodes[0].token
            guard let frame = frames[token], frame.minX >= workingFrame.minX, frame.maxX <= workingFrame.maxX
            else { continue }
            XCTAssertEqual(column.minX, frame.minX, accuracy: 1)
            XCTAssertEqual(column.maxX, frame.maxX, accuracy: 1)
            compared += 1
        }
        XCTAssertGreaterThanOrEqual(compared, 2)
    }

    func testRelayoutsDuringALiveDragNeverScrollTheStrip() async throws {
        for centring in [CenterFocusedColumn.always, .never] {
            let fixture = try makeFixture(pid: centring == .always ? 938_012 : 938_013, windowCount: 5)
            centreColumns(centring, in: fixture)
            try fixture.startLiveDrag(fixture.tokens[1])
            let cursor = try fixture.farHalf(of: fixture.tokens[2])
            fixture.drag(to: cursor)
            XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, 1, "\(centring)")
            let viewport = fixture.manager.niriViewportState(for: fixture.workspaceId)
            let order = fixture.order()

            try await drainRefreshes(fixture)
            for _ in 0 ..< 3 {
                fixture.drag(to: cursor)
                try await drainRefreshes(fixture)
            }

            let after = fixture.manager.niriViewportState(for: fixture.workspaceId)
            XCTAssertEqual(after.viewOffset, viewport.viewOffset, accuracy: 0.001, "\(centring)")
            XCTAssertEqual(after.activeColumnIndex, viewport.activeColumnIndex, "\(centring)")
            XCTAssertEqual(fixture.order(), order, "\(centring)")
            XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, 1, "\(centring)")
        }
    }

    func testTheDraggedWindowStaysShownAndDraggingWhenItsHomeSpotScrollsOffScreen() async throws {
        let fixture = try makeFixture(pid: 938_014, windowCount: 6)
        let dragged = fixture.tokens[0]
        try fixture.startLiveDrag(dragged)
        let home = try fixture.settledFrame(dragged)
        let neighbour = try fixture.settledFrame(fixture.tokens[1])
        let workingFrame = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.jumpOffset(to: state.viewOffset + neighbour.maxX - workingFrame.minX + 10)
        }
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.workspaceId))
        let strip = fixture.engine.liveColumnStrip(
            context: context,
            state: fixture.manager.niriViewportState(for: fixture.workspaceId)
        )
        let homeColumn = try XCTUnwrap(fixture.engine.findNode(for: dragged, in: fixture.workspaceId)?.parent)
        XCTAssertLessThan(try XCTUnwrap(strip.first { $0.column === homeColumn }).maxX, workingFrame.minX)

        fixture.controller.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: [fixture.workspaceId]
        )
        try await drainRefreshes(fixture)

        XCTAssertNil(try fixture.entry(dragged).hiddenState)
        try fixture.macOSMoves(dragged, to: home.offsetBy(dx: 60, dy: 0))
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertNotNil(fixture.engine.liveColumnMove)
        XCTAssertEqual(fixture.phase, .dragging)
    }

    func testDragEventsRunHitTestsWhileAChangeAnimates() throws {
        let fixture = try makeFixture(pid: 938_094, windowCount: 5, animated: true)
        try fixture.startLiveDrag(fixture.tokens[1])
        fixture.drag(to: try fixture.farHalf(of: fixture.tokens[2]))
        XCTAssertEqual(fixture.engine.liveColumnMove?.phase, .settling)
        let firstOrder = fixture.landingOrder()

        fixture.drag(to: try fixture.farHalf(of: fixture.tokens[3]))

        XCTAssertNotEqual(fixture.landingOrder(), firstOrder)
    }

    func testDropScrollWaitsUntilTheDropHasSettled() throws {
        let fixture = try makeFixture(pid: 938_010, animated: true)
        centreColumns(.always, in: fixture)
        let (dragged, neighbour) = (fixture.tokens[1], fixture.tokens[2])
        try fixture.startLiveDrag(dragged)
        let drop = try fixture.centre(of: neighbour)
        fixture.drag(to: drop)
        fixture.handler.handleNiriAnimationsSettled(in: fixture.workspaceId)

        fixture.handler.dispatchMouseUp(at: drop)
        XCTAssertNotNil(fixture.handler.state.liveDropScroll)
        let offsetAtDrop = fixture.manager.niriViewportState(for: fixture.workspaceId).viewOffset

        fixture.handler.handleNiriAnimationsSettled(in: fixture.workspaceId)

        XCTAssertNil(fixture.handler.state.liveDropScroll)
        XCTAssertNotEqual(fixture.manager.niriViewportState(for: fixture.workspaceId).viewOffset, offsetAtDrop)
        let dropped = try fixture.settledFrame(dragged)
        let workingFrame = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        XCTAssertEqual(dropped.midX, workingFrame.midX, accuracy: 2)
    }

    private func scroll(_ fixture: Fixture, so token: WindowToken, isHalfOffTheRightEdge: Void) throws {
        let frame = try fixture.settledFrame(token)
        let edge = fixture.controller.insetWorkingFrame(for: fixture.monitor).maxX
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.jumpOffset(to: state.viewOffset + frame.minX - (edge - frame.width / 2))
        }
        try fixture.confirmLayout()
        let moved = try fixture.settledFrame(token)
        XCTAssertEqual(moved.midX, edge, accuracy: 1)
    }

    private func centreColumns(_ centring: CenterFocusedColumn, in fixture: Fixture) {
        let current = fixture.engine.effectiveSettings(in: fixture.workspaceId)
        fixture.manager.withEngineMutationScope(in: fixture.workspaceId) {
            fixture.engine.updateMonitorSettings(
                ResolvedNiriSettings(
                    visibleContainerCount: current.visibleContainerCount,
                    defaultContainerPrimarySpan: current.defaultContainerPrimarySpan,
                    centerFocusedColumn: centring,
                    alwaysCenterSingleColumn: current.alwaysCenterSingleColumn,
                    singleWindowFit: current.singleWindowFit,
                    infiniteLoop: current.infiniteLoop
                ),
                for: fixture.monitor.id
            )
        }
    }

    private func drainRefreshes(_ fixture: Fixture) async throws {
        let refreshController = fixture.controller.layoutRefreshController
        var completed = 0
        while let task = refreshController.layoutState.activeRefreshTask {
            guard completed < 200 else {
                XCTFail("Layout refresh chain exceeded 200 tasks")
                return
            }
            await task.value
            completed += 1
        }
    }

    private func makeFixture(
        pid: pid_t,
        windowCount: Int = 4,
        stackFirstTwo: Bool = false,
        animated: Bool = false,
        hoverDelay: TimeInterval = 0,
        layout: LayoutType = .niri
    ) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "LiveTitleBarDragTests")
        addTeardownBlock { @MainActor [controller] in
            controller.hasStartedServices = false
            controller.layoutRefreshController.resetState()
            controller.mouseEventHandler.cleanup()
            controller.surfaceReconciler.cleanup()
            controller.axManager.cleanup()
        }
        controller.motionPolicy.animationsEnabled = animated
        controller.mouseEventHandler.liveDragEscapeCapture.installsEventTap = false
        let monitor = Monitor(
            id: .init(displayId: 93_801),
            displayId: 93_801,
            frame: workingFrame,
            visibleFrame: workingFrame,
            hasNotch: false,
            name: "Live Title Bar Drag"
        )
        controller.settings.niri.naturalWindowDrag = true
        controller.settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: layout
            )
        ]
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let tokens = (0 ..< windowCount).map { WindowToken(pid: pid, windowId: Int(pid) + 100 + $0) }
        for token in tokens {
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        }
        if layout == .dwindle {
            return try makeDwindleFixture(
                controller: controller,
                workspaceId: workspaceId,
                monitor: monitor,
                tokens: tokens
            )
        }
        controller.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        engine.moveConfiguration.liveHoverDelay = hoverDelay
        var previous: NiriWindow?
        for (index, token) in tokens.enumerated() {
            if stackFirstTwo, index == 1, let first = previous {
                controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
                    engine.attachTransferredWindow(
                        NiriWindow(token: token),
                        stackedWith: first,
                        after: true,
                        in: workspaceId,
                        state: &state
                    )
                }
                continue
            }
            previous = engine.addWindow(token: token, to: workspaceId, afterSelection: previous?.id)
        }
        for column in engine.columns(in: workspaceId) {
            column.width = .proportion(1.0 / 3.0)
            column.cachedWidth = 0
        }
        let fixture = Fixture(controller: controller, workspaceId: workspaceId, monitor: monitor, tokens: tokens)
        return try finishFixture(fixture, tokens: tokens)
    }

    private func makeDwindleFixture(
        controller: WMController,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        tokens: [WindowToken]
    ) throws -> Fixture {
        controller.enableDwindleLayout()
        let engine = try XCTUnwrap(controller.dwindleEngine)
        controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            for token in tokens {
                _ = engine.setPreselection(.right, in: workspaceId)
                _ = engine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
            }
        }
        engine.cancelAnimations(in: workspaceId)
        controller.enableNiriLayout()
        let niri = try XCTUnwrap(controller.niriEngine)
        var previous: NiriWindow?
        for token in tokens {
            previous = niri.addWindow(token: token, to: workspaceId, afterSelection: previous?.id)
        }
        let fixture = Fixture(controller: controller, workspaceId: workspaceId, monitor: monitor, tokens: tokens)
        return try finishFixture(fixture, tokens: tokens)
    }

    private func finishFixture(_ fixture: Fixture, tokens: [WindowToken]) throws -> Fixture {
        let controller = fixture.controller
        let frames = try fixture.frames()
        try fixture.confirmLayout()
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
