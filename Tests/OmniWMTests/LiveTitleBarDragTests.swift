// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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
                  let home = columns.firstIndex(where: { $0.id == move.homeColumnId }),
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
    }

    func testNaturalDragClicksReachTheAppWithoutOption() {
        let option = CGEventFlags.maskAlternate

        XCTAssertEqual(MouseEventHandler.naturalDragPassThroughFlags(option, naturalDragModifier: option), [])
        XCTAssertEqual(
            MouseEventHandler.naturalDragPassThroughFlags(option.union(.maskShift), naturalDragModifier: option),
            .maskShift
        )
        XCTAssertEqual(MouseEventHandler.naturalDragPassThroughFlags(option, naturalDragModifier: nil), option)
        XCTAssertEqual(
            MouseEventHandler.naturalDragPassThroughFlags(option, naturalDragModifier: .maskCommand),
            option
        )
        XCTAssertEqual(
            MouseEventHandler.naturalDragPassThroughFlags(.maskCommand, naturalDragModifier: .maskCommand),
            .maskCommand
        )
    }

    func testTapKnowsTheNaturalDragModifierOnlyWhileTheSettingIsOn() throws {
        let fixture = try makeFixture(pid: 938_090)

        fixture.handler.syncTapFilterSnapshot()
        XCTAssertEqual(fixture.handler.inputTapThread.filterSnapshot.naturalDragModifier, .maskAlternate)

        fixture.controller.settings.niri.naturalWindowDrag = false
        fixture.handler.syncTapFilterSnapshot()
        XCTAssertNil(fixture.handler.inputTapThread.filterSnapshot.naturalDragModifier)
    }

    func testNaturalDragSettingChangesReachTheTapAtOnce() throws {
        let fixture = try makeFixture(pid: 938_092)
        let settings = fixture.controller.settings
        let snapshot = { fixture.handler.inputTapThread.filterSnapshot.naturalDragModifier }

        settings.niri.naturalWindowDragModifier = .command
        fixture.controller.applyNaturalWindowDragSettings()
        XCTAssertEqual(snapshot(), .maskCommand)

        settings.niri.naturalWindowDrag = false
        fixture.controller.applyNaturalWindowDragSettings()
        XCTAssertNil(snapshot())
        XCTAssertFalse(fixture.engine.tabbedColumnsFillHeight)

        settings.niri.naturalWindowDrag = true
        settings.quakeTerminal.enabled = false
        fixture.controller.applyPersistedSettings(settings, startServices: false)
        XCTAssertEqual(snapshot(), .maskCommand)
    }

    func testNaturalDragSettingReachesTheEngine() throws {
        let fixture = try makeFixture(pid: 938_091)
        let settings = fixture.controller.settings
        settings.quakeTerminal.enabled = false

        fixture.controller.applyPersistedSettings(settings, startServices: false)
        XCTAssertTrue(fixture.engine.tabbedColumnsFillHeight)

        settings.niri.naturalWindowDrag = false
        fixture.controller.applyPersistedSettings(settings, startServices: false)
        XCTAssertFalse(fixture.engine.tabbedColumnsFillHeight)
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
        XCTAssertNil(fixture.handler.state.deferredClickScroll)

        fixture.handler.dispatchMouseUp(at: try fixture.centre(of: other))

        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertEqual(try fixture.frames(), frames)
    }

    func testMacOSMovingTheWindowStartsALiveDragThatSwapsColumns() throws {
        let fixture = try makeFixture(pid: 938_002)
        let (dragged, neighbour) = (fixture.tokens[1], fixture.tokens[2])

        try fixture.startLiveDrag(dragged)

        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
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

    func testAStackedWindowStartsALiveDragAndMovesWithinItsStack() throws {
        let fixture = try makeFixture(pid: 938_004, stackFirstTwo: true)
        let (lower, upper) = (fixture.tokens[0], fixture.tokens[1])
        let stack = try column(holding: lower, in: fixture)
        XCTAssertEqual(stack.windowNodes.map(\.token), [lower, upper])

        try fixture.startLiveDrag(lower)

        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.engine.liveColumnMove?.inStack, true)
        let drop = try fixture.centre(of: upper)
        fixture.drag(to: drop)
        XCTAssertEqual(stack.windowNodes.map(\.token), [upper, lower])
        fixture.handler.dispatchMouseUp(at: drop)

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertEqual(stack.windowNodes.map(\.token), [upper, lower])
        XCTAssertGreaterThan(try fixture.settledFrame(lower).minY, try fixture.settledFrame(upper).maxY)
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
        }
    }

    func testCancellingAfterTheDisplayIsGoneLeavesNoDropSpaceOrMovedHomeSpot() throws {
        let fixture = try makeFixture(pid: 938_302, windowCount: 6)
        let order = fixture.order()
        try fixture.startLiveDrag(fixture.tokens[1])
        fixture.drag(to: try fixture.farHalf(of: fixture.tokens[2]))
        XCTAssertNotEqual(fixture.landingOrder(), order)

        let replacement = Monitor(
            id: .init(displayId: 93_802),
            displayId: 93_802,
            frame: fixture.monitor.frame,
            visibleFrame: fixture.monitor.visibleFrame,
            hasNotch: false,
            name: "Replacement"
        )
        fixture.manager.applyMonitorConfigurationChange([replacement])
        XCTAssertNotNil(fixture.manager.monitor(for: fixture.workspaceId))
        XCTAssertNotNil(fixture.engine.liveColumnMove)
        fixture.handler.cancelActiveMouseInteraction()

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.isLiveDropSpace })
        XCTAssertEqual(fixture.order(), order)
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
        fixture.handler.state.liveHoverTimer?.fire()
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
            let landed = ending == "release" ? [order[0], order[2], order[1]] + order.dropFirst(3) : order
            XCTAssertEqual(fixture.order(), landed, ending)
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

        let target = try fixture.farHalf(of: fixture.tokens[3])
        fixture.drag(to: CGPoint(x: target.x + 60, y: target.y))

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

    func testAFocusChangeBeforeTheDropSettlesKeepsTheStripOffTheDroppedWindow() throws {
        let fixture = try makeFixture(pid: 938_300, animated: true)
        centreColumns(.always, in: fixture)
        let (dragged, neighbour) = (fixture.tokens[1], fixture.tokens[2])
        try fixture.startLiveDrag(dragged)
        let drop = try fixture.centre(of: neighbour)
        fixture.drag(to: drop)
        fixture.handler.handleNiriAnimationsSettled(in: fixture.workspaceId)
        fixture.handler.dispatchMouseUp(at: drop)
        XCTAssertNotNil(fixture.handler.state.liveDropScroll)
        let other = try XCTUnwrap(fixture.engine.findNode(for: fixture.tokens[3], in: fixture.workspaceId))
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { $0.selectedNodeId = other.id }
        let offsetAtFocusChange = fixture.manager.niriViewportState(for: fixture.workspaceId).viewOffset

        fixture.handler.handleNiriAnimationsSettled(in: fixture.workspaceId)

        XCTAssertNil(fixture.handler.state.liveDropScroll)
        XCTAssertEqual(
            fixture.manager.niriViewportState(for: fixture.workspaceId).viewOffset,
            offsetAtFocusChange
        )
        XCTAssertEqual(fixture.manager.niriViewportState(for: fixture.workspaceId).selectedNodeId, other.id)
    }

    func testANewPressDropsAPendingDropScroll() throws {
        let fixture = try makeFixture(pid: 938_301, animated: true)
        centreColumns(.always, in: fixture)
        let (dragged, neighbour) = (fixture.tokens[1], fixture.tokens[2])
        try fixture.startLiveDrag(dragged)
        let drop = try fixture.centre(of: neighbour)
        fixture.drag(to: drop)
        fixture.handler.handleNiriAnimationsSettled(in: fixture.workspaceId)
        fixture.handler.dispatchMouseUp(at: drop)
        XCTAssertNotNil(fixture.handler.state.liveDropScroll)

        fixture.handler.receiveTapMouseDown(at: try fixture.centre(of: fixture.tokens[3]), modifiers: [])

        XCTAssertNil(fixture.handler.state.liveDropScroll)
    }

    func testHoldingAtTheRightEdgeScrollsOnlyAfterTheDelay() throws {
        let fixture = try makeFixture(pid: 938_020, windowCount: 6)
        let clock = edgeClock(fixture)
        try fixture.startLiveDrag(fixture.tokens[1])

        fixture.drag(to: edgePoint(.trailing, fixture))
        XCTAssertEqual(fixture.handler.state.liveEdgeScroll?.edge, .trailing)
        clock.now += 0.29
        fixture.handler.startLiveEdgeScrollIfDue()
        XCTAssertFalse(fixture.handler.isLiveEdgeScrolling)
        XCTAssertFalse(fixture.manager.animationDriver.hasEdgeScroll(in: fixture.workspaceId))

        clock.now += 0.01
        fixture.handler.startLiveEdgeScrollIfDue()

        XCTAssertTrue(fixture.handler.isLiveEdgeScrolling)
        let motion = try XCTUnwrap(fixture.manager.animationDriver.edgeScroll(in: fixture.workspaceId))
        XCTAssertGreaterThan(motion.to, motion.from)
        XCTAssertEqual(motion.speed, 1000)
    }

    func testColumnsPassingUnderAStillCursorAtTheRightEdgeMoveTheDropSpaceOnceEachUntilTheStripEnd() throws {
        let fixture = try makeFixture(pid: 938_021, windowCount: 6)
        let dragged = fixture.tokens[1]
        try startEdgeScroll(.trailing, dragging: dragged, in: fixture)
        let startIndex = try XCTUnwrap(fixture.landingOrder().firstIndex(of: dragged))
        let startSwaps = fixture.engine.liveColumnMove?.swapCount ?? 0

        var indices = [startIndex]
        tickEdgeScroll(fixture) {
            if let index = fixture.landingOrder().firstIndex(of: dragged), index != indices.last {
                indices.append(index)
            }
            return false
        }

        let afterFirstMove = Array(indices.dropFirst())
        XCTAssertGreaterThan(try XCTUnwrap(afterFirstMove.first), startIndex)
        XCTAssertEqual(afterFirstMove, Array(try XCTUnwrap(afterFirstMove.first) ... 5))
        XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, startSwaps + afterFirstMove.count)
        XCTAssertFalse(fixture.handler.isLiveEdgeScrolling)
        XCTAssertFalse(fixture.manager.animationDriver.hasMotion(in: fixture.workspaceId))
        let workingFrame = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        let gap = fixture.controller.innerGap(for: fixture.monitor)
        let last = try XCTUnwrap(liveStrip(fixture).last)
        XCTAssertTrue(last.column.isLiveDropSpace)
        XCTAssertEqual(last.maxX, workingFrame.maxX - gap, accuracy: 1)
    }

    func testTheEdgeScrollBuildsTheStripOnceAndShiftsItToMatchAFreshOne() throws {
        let fixture = try makeFixture(pid: 938_040, windowCount: 6)
        try startEdgeScroll(.trailing, dragging: fixture.tokens[1], in: fixture)
        let motion = try XCTUnwrap(fixture.manager.animationDriver.edgeScroll(in: fixture.workspaceId))
        let location = CGPoint(x: -10_000, y: 0)
        XCTAssertNil(fixture.handler.state.liveEdgeScroll?.strip)

        _ = fixture.handler.liveEdgeScrollReachesColumn(
            at: location, time: motion.startTime, engine: fixture.engine, workspaceId: fixture.workspaceId
        )
        let cached = try XCTUnwrap(fixture.handler.state.liveEdgeScroll?.strip)
        let later = motion.startTime + 0.1
        _ = fixture.handler.liveEdgeScrollReachesColumn(
            at: location, time: later, engine: fixture.engine, workspaceId: fixture.workspaceId
        )

        XCTAssertEqual(fixture.handler.state.liveEdgeScroll?.strip?.viewOffset, cached.viewOffset)
        var probe = fixture.manager.niriViewportState(for: fixture.workspaceId)
        probe.viewOffset = fixture.manager.animationDriver.liveViewOffset(
            in: fixture.workspaceId, semanticOffset: probe.viewOffset, at: later
        ) ?? probe.viewOffset
        XCTAssertNotEqual(probe.viewOffset, cached.viewOffset, accuracy: 1)
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.workspaceId))
        let fresh = fixture.engine.liveColumnStrip(context: context, state: probe)
        let shift = cached.viewOffset - probe.viewOffset
        XCTAssertEqual(fresh.count, cached.columns.count)
        for (fresh, cached) in zip(fresh, cached.columns) {
            XCTAssertTrue(fresh.column === cached.column)
            XCTAssertEqual(fresh.minX, cached.minX + shift, accuracy: 0.5)
            XCTAssertEqual(fresh.maxX, cached.maxX + shift, accuracy: 0.5)
        }
    }

    func testColumnsReachingThePointerDuringAnEdgeScrollSkipTheHoverDelay() throws {
        let fixture = try makeFixture(pid: 938_032, windowCount: 6, hoverDelay: 0.12)
        fixture.handler.liveDragClock = { 1_000 }
        let dragged = fixture.tokens[1]
        try startEdgeScroll(.trailing, dragging: dragged, in: fixture)
        let startIndex = try XCTUnwrap(fixture.landingOrder().firstIndex(of: dragged))

        var indices = [startIndex]
        tickEdgeScroll(fixture) {
            if let index = fixture.landingOrder().firstIndex(of: dragged), index != indices.last {
                indices.append(index)
            }
            return false
        }

        let afterFirstMove = Array(indices.dropFirst())
        XCTAssertGreaterThan(try XCTUnwrap(afterFirstMove.first), startIndex)
        XCTAssertEqual(afterFirstMove, Array(try XCTUnwrap(afterFirstMove.first) ... 5))
        XCTAssertNil(fixture.handler.state.liveHoverTimer)
    }

    func testColumnsPassingUnderAStillCursorAtTheLeftEdgeMoveTheDropSpaceOnceEachUntilTheStripStart() throws {
        let fixture = try makeFixture(pid: 938_022, windowCount: 6)
        let workingFrame = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        let gap = fixture.controller.innerGap(for: fixture.monitor)
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.workspaceId))
        let strip = fixture.engine.liveColumnStrip(
            context: context,
            state: fixture.manager.niriViewportState(for: fixture.workspaceId)
        )
        let overhang = try XCTUnwrap(strip.last).maxX - (workingFrame.maxX - gap)
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.jumpOffset(to: state.viewOffset + overhang)
        }
        try fixture.confirmLayout()
        let dragged = fixture.tokens[4]
        try startEdgeScroll(.leading, dragging: dragged, in: fixture)
        let startIndex = try XCTUnwrap(fixture.landingOrder().firstIndex(of: dragged))

        var indices = [startIndex]
        tickEdgeScroll(fixture) {
            if let index = fixture.landingOrder().firstIndex(of: dragged), index != indices.last {
                indices.append(index)
            }
            return false
        }

        let afterFirstMove = Array(indices.dropFirst())
        XCTAssertLessThan(try XCTUnwrap(afterFirstMove.first), startIndex)
        XCTAssertEqual(afterFirstMove, Array((0 ... (try XCTUnwrap(afterFirstMove.first))).reversed()))
        XCTAssertFalse(fixture.handler.isLiveEdgeScrolling)
        let first = try XCTUnwrap(liveStrip(fixture).first)
        XCTAssertTrue(first.column.isLiveDropSpace)
        XCTAssertEqual(first.minX, workingFrame.minX + gap, accuracy: 1)
    }

    func testTheEdgeScrollPausesWhileTheDropSpaceSettlesAndResumesAfter() throws {
        let fixture = try makeFixture(pid: 938_023, windowCount: 6, animated: true)
        let dragged = fixture.tokens[1]
        try startEdgeScroll(.trailing, dragging: dragged, in: fixture)
        let swaps = fixture.engine.liveColumnMove?.swapCount ?? 0

        tickEdgeScroll(fixture) { fixture.engine.liveColumnMove?.swapCount != swaps }

        XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, swaps + 1)
        XCTAssertEqual(fixture.engine.liveColumnMove?.phase, .settling)
        XCTAssertFalse(fixture.handler.isLiveEdgeScrolling)
        XCTAssertFalse(fixture.manager.animationDriver.hasEdgeScroll(in: fixture.workspaceId))
        let settlingOffset = fixture.manager.niriViewportState(for: fixture.workspaceId).viewOffset
        fixture.handler.handleLiveEdgeScrollTick(in: fixture.workspaceId, at: CACurrentMediaTime() + 0.1)
        XCTAssertEqual(fixture.manager.niriViewportState(for: fixture.workspaceId).viewOffset, settlingOffset)

        fixture.manager.animationDriver.removeMotions(for: [fixture.workspaceId])
        _ = fixture.engine.cancelAnimations(in: fixture.workspaceId)
        fixture.handler.handleNiriAnimationsSettled(in: fixture.workspaceId)

        XCTAssertEqual(fixture.engine.liveColumnMove?.phase, .dragging)
        XCTAssertTrue(fixture.handler.isLiveEdgeScrolling)
        let resumed = try XCTUnwrap(fixture.manager.animationDriver.edgeScroll(in: fixture.workspaceId))
        XCTAssertEqual(resumed.from, Double(settlingOffset), accuracy: 0.5)
        XCTAssertGreaterThan(resumed.to, resumed.from)
    }

    func testLeavingTheZoneStopsTheScrollWithoutSnappingBack() throws {
        let fixture = try makeFixture(pid: 938_024, windowCount: 6)
        try startEdgeScroll(.trailing, dragging: fixture.tokens[1], in: fixture)
        let motion = try XCTUnwrap(fixture.manager.animationDriver.edgeScroll(in: fixture.workspaceId))
        let (from, limit) = (motion.from, motion.to)
        let order = fixture.order()

        fixture.drag(to: CGPoint(x: fixture.monitor.frame.maxX - 60, y: fixture.monitor.frame.midY))

        XCTAssertNil(fixture.handler.state.liveEdgeScroll)
        XCTAssertFalse(fixture.manager.animationDriver.hasMotion(in: fixture.workspaceId))
        let offset = fixture.manager.niriViewportState(for: fixture.workspaceId).viewOffset
        XCTAssertGreaterThanOrEqual(Double(offset), from - 0.001)
        XCTAssertLessThan(Double(offset), limit)
        XCTAssertEqual(fixture.order(), order)
    }

    func testTheEdgeZoneIsThreePercentOfTheDisplayAndAtLeastFortyPoints() throws {
        let configuration = MoveConfiguration()
        XCTAssertEqual(configuration.liveEdgeZoneWidth(forDisplayWidth: 1_728), 51.84, accuracy: 0.01)
        XCTAssertEqual(configuration.liveEdgeZoneWidth(forDisplayWidth: 2_560), 76.8, accuracy: 0.01)
        XCTAssertEqual(configuration.liveEdgeZoneWidth(forDisplayWidth: 1_024), 40, accuracy: 0.01)

        let fixture = try makeFixture(pid: 938_033, windowCount: 6)
        let zone = configuration.liveEdgeZoneWidth(forDisplayWidth: fixture.monitor.frame.width)
        try fixture.startLiveDrag(fixture.tokens[1])
        fixture.drag(to: CGPoint(x: fixture.monitor.frame.maxX - zone - 2, y: fixture.monitor.frame.midY))
        XCTAssertNil(fixture.handler.state.liveEdgeScroll)
        fixture.drag(to: CGPoint(x: fixture.monitor.frame.maxX - zone + 2, y: fixture.monitor.frame.midY))
        XCTAssertEqual(fixture.handler.state.liveEdgeScroll?.edge, .trailing)
    }

    func testLeavingTheZoneBeforeTheDelayStartsNoScroll() throws {
        let fixture = try makeFixture(pid: 938_025, windowCount: 6)
        let clock = edgeClock(fixture)
        try fixture.startLiveDrag(fixture.tokens[1])
        fixture.drag(to: edgePoint(.trailing, fixture))
        fixture.drag(to: CGPoint(x: fixture.monitor.frame.maxX - 60, y: fixture.monitor.frame.midY))

        clock.now += 1
        fixture.handler.startLiveEdgeScrollIfDue()

        XCTAssertNil(fixture.handler.state.liveEdgeScroll)
        XCTAssertFalse(fixture.manager.animationDriver.hasEdgeScroll(in: fixture.workspaceId))
    }

    func testMovingWithinTheZoneKeepsTheDelayAndSwitchingEdgesRestartsIt() throws {
        let fixture = try makeFixture(pid: 938_026, windowCount: 6)
        let clock = edgeClock(fixture)
        try fixture.startLiveDrag(fixture.tokens[1])
        fixture.drag(to: edgePoint(.trailing, fixture))
        let entered = try XCTUnwrap(fixture.handler.state.liveEdgeScroll?.enteredAt)

        clock.now += 0.2
        fixture.drag(to: CGPoint(x: fixture.monitor.frame.maxX - 25, y: fixture.monitor.frame.midY + 40))
        XCTAssertEqual(fixture.handler.state.liveEdgeScroll?.enteredAt, entered)

        clock.now += 0.05
        fixture.drag(to: edgePoint(.leading, fixture))
        XCTAssertEqual(fixture.handler.state.liveEdgeScroll?.edge, .leading)
        XCTAssertEqual(fixture.handler.state.liveEdgeScroll?.enteredAt, clock.now)
    }

    func testADragStartingInsideTheEdgeZoneWaitsUntilPushedTowardTheEdge() throws {
        let fixture = try makeFixture(pid: 938_034, windowCount: 6)
        let clock = edgeClock(fixture)
        let start = try startLiveDragInsideTheEdgeZone(.leading, dragging: fixture.tokens[1], in: fixture)
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertNil(fixture.handler.state.liveEdgeScroll)

        clock.now += 0.4
        fixture.drag(to: CGPoint(x: start.x + 6, y: start.y))
        fixture.handler.startLiveEdgeScrollIfDue()
        XCTAssertNil(fixture.handler.state.liveEdgeScroll)
        XCTAssertFalse(fixture.handler.isLiveEdgeScrolling)

        clock.now += 0.1
        fixture.drag(to: CGPoint(x: start.x - 4, y: start.y))
        XCTAssertEqual(fixture.handler.state.liveEdgeScroll?.edge, .leading)
        XCTAssertEqual(fixture.handler.state.liveEdgeScroll?.enteredAt, clock.now)
    }

    func testADragStartingInsideTheEdgeZoneArmsItAfterLeavingAndComingBack() throws {
        let fixture = try makeFixture(pid: 938_035, windowCount: 6)
        let clock = edgeClock(fixture)
        let start = try startLiveDragInsideTheEdgeZone(.trailing, dragging: fixture.tokens[1], in: fixture)
        XCTAssertNil(fixture.handler.state.liveEdgeScroll)

        clock.now += 0.1
        fixture.drag(to: CGPoint(x: fixture.monitor.frame.midX, y: start.y))
        XCTAssertNil(fixture.handler.state.liveEdgeZoneHold)

        clock.now += 0.1
        fixture.drag(to: CGPoint(x: start.x - 4, y: start.y))
        XCTAssertEqual(fixture.handler.state.liveEdgeScroll?.edge, .trailing)
        XCTAssertEqual(fixture.handler.state.liveEdgeScroll?.enteredAt, clock.now)
    }

    func testNoEdgeScrollStartsWhereTheStripIsAlreadyAtItsEnd() throws {
        let fixture = try makeFixture(pid: 938_027, windowCount: 6)
        let clock = edgeClock(fixture)
        try fixture.startLiveDrag(fixture.tokens[1])
        fixture.drag(to: edgePoint(.leading, fixture))
        clock.now += 0.3
        fixture.handler.startLiveEdgeScrollIfDue()
        tickEdgeScroll(fixture)

        fixture.handler.startLiveEdgeScrollIfDue()

        XCTAssertEqual(fixture.handler.state.liveEdgeScroll?.edge, .leading)
        XCTAssertFalse(fixture.handler.isLiveEdgeScrolling)
        XCTAssertFalse(fixture.manager.animationDriver.hasEdgeScroll(in: fixture.workspaceId))
    }

    func testCancellingDuringAnEdgeScrollRestoresTheLayout() throws {
        for cancel in ["esc", "interaction", "pointer crosses to another display"] {
            let pid: pid_t = switch cancel {
            case "esc": 938_028
            case "interaction": 938_029
            default: 938_030
            }
            let fixture = try makeFixture(pid: pid, windowCount: 6)
            let order = fixture.order()
            let offset = fixture.manager.niriViewportState(for: fixture.workspaceId).viewOffset
            try startEdgeScroll(.trailing, dragging: fixture.tokens[1], in: fixture)
            let swaps = fixture.engine.liveColumnMove?.swapCount ?? 0
            tickEdgeScroll(fixture) { fixture.engine.liveColumnMove?.swapCount != swaps }
            XCTAssertNotEqual(fixture.landingOrder(), order, cancel)

            switch cancel {
            case "esc":
                fixture.handler.cancelLiveColumnDrag()
            case "interaction":
                fixture.handler.cancelActiveMouseInteraction()
            default:
                fixture.drag(to: CGPoint(x: fixture.monitor.frame.maxX + 5, y: fixture.monitor.frame.midY))
            }

            XCTAssertEqual(fixture.order(), order, cancel)
            XCTAssertEqual(
                fixture.manager.niriViewportState(for: fixture.workspaceId).viewOffset,
                offset,
                accuracy: 0.001,
                cancel
            )
            XCTAssertNil(fixture.handler.state.liveEdgeScroll, cancel)
            XCTAssertFalse(fixture.manager.animationDriver.hasEdgeScroll(in: fixture.workspaceId), cancel)
        }
    }

    func testReleaseDuringAnEdgeScrollDropsIntoTheDropSpace() throws {
        let fixture = try makeFixture(pid: 938_031, windowCount: 6)
        let dragged = fixture.tokens[1]
        try startEdgeScroll(.trailing, dragging: dragged, in: fixture)
        let swaps = fixture.engine.liveColumnMove?.swapCount ?? 0
        tickEdgeScroll(fixture) { fixture.engine.liveColumnMove?.swapCount != swaps }
        let order = fixture.landingOrder()

        fixture.handler.dispatchMouseUp(at: edgePoint(.trailing, fixture))

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertNil(fixture.handler.state.liveEdgeScroll)
        XCTAssertFalse(fixture.manager.animationDriver.hasEdgeScroll(in: fixture.workspaceId))
        XCTAssertEqual(fixture.order(), order)
    }

    func testReleaseAfterAnEdgeScrollLandsWhereTheDropSpaceWasWithoutScrollingBack() throws {
        let fixture = try makeFixture(pid: 938_034, windowCount: 8)
        let dragged = fixture.tokens[1]
        try startEdgeScroll(.trailing, dragging: dragged, in: fixture)
        let swaps = fixture.engine.liveColumnMove?.swapCount ?? 0
        tickEdgeScroll(fixture) { (fixture.engine.liveColumnMove?.swapCount ?? 0) >= swaps + 2 }
        fixture.handler.stopLiveEdgeScroll()
        let dropSpace = try XCTUnwrap(liveStrip(fixture).first { $0.column.isLiveDropSpace })
        let landing = fixture.landingOrder()

        fixture.handler.dispatchMouseUp(at: edgePoint(.trailing, fixture))

        XCTAssertEqual(fixture.order(), landing)
        let draggedColumn = try XCTUnwrap(fixture.engine.columns(in: fixture.workspaceId).first {
            $0.windowNodes.first?.token == dragged
        })
        let landed = try XCTUnwrap(liveStrip(fixture).first { $0.column === draggedColumn })
        let screen = fixture.monitor.frame
        XCTAssertGreaterThanOrEqual(landed.minX, screen.minX - 1)
        XCTAssertLessThanOrEqual(landed.maxX, screen.maxX + 1)
        XCTAssertLessThanOrEqual(abs(dropSpace.minX - landed.minX), landed.maxX - landed.minX)
    }

    private func liveStrip(_ fixture: Fixture) throws -> [LiveColumnMove.StripColumn] {
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.workspaceId))
        return fixture.engine.liveColumnStrip(
            context: context,
            state: fixture.manager.niriViewportState(for: fixture.workspaceId)
        )
    }

    private final class EdgeClock {
        var now: TimeInterval = 1_000
    }

    func testTheEdgeScrollStopsWhenTheEngineDropsTheMove() throws {
        let fixture = try makeFixture(pid: 938_303, windowCount: 6)
        let dragged = fixture.tokens[1]
        try startEdgeScroll(.trailing, dragging: dragged, in: fixture)
        XCTAssertTrue(fixture.manager.animationDriver.hasEdgeScroll(in: fixture.workspaceId))
        let window = try XCTUnwrap(fixture.engine.findNode(for: dragged, in: fixture.workspaceId))
        fixture.manager.withEngineMutationScope(in: fixture.workspaceId) {
            fixture.engine.cancelInteractions(for: [window.id], in: fixture.workspaceId)
        }
        XCTAssertNil(fixture.engine.liveColumnMove)

        fixture.drag(to: edgePoint(.trailing, fixture))

        XCTAssertFalse(fixture.handler.isLiveEdgeScrolling)
        XCTAssertFalse(fixture.manager.animationDriver.hasEdgeScroll(in: fixture.workspaceId))
    }

    func testTheScrollTickDrivesTheEdgeScrollAndKeepsItRegistered() throws {
        let fixture = try makeFixture(pid: 938_304, windowCount: 6)
        fixture.controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        try startEdgeScroll(.trailing, dragging: fixture.tokens[1], in: fixture)
        let handler = fixture.controller.niriLayoutHandler
        XCTAssertTrue(handler.hasScrollAnimation(for: fixture.workspaceId))
        let order = fixture.landingOrder()
        var time = try XCTUnwrap(fixture.manager.animationDriver.edgeScroll(in: fixture.workspaceId)).startTime

        for _ in 0 ..< 600 where fixture.landingOrder() == order {
            time += 1.0 / 60
            handler.tickScrollAnimation(targetTime: time, displayId: fixture.monitor.displayId)
            if fixture.handler.isLiveEdgeScrolling {
                XCTAssertTrue(handler.hasScrollAnimation(for: fixture.workspaceId))
            }
        }

        XCTAssertNotEqual(fixture.landingOrder(), order)
    }

    func testAnEdgeScrollRestartedOnItsLastFrameKeepsTheScrollTickRunning() throws {
        let fixture = try makeFixture(pid: 938_306, windowCount: 6)
        fixture.controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        try startEdgeScroll(.trailing, dragging: fixture.tokens[1], in: fixture)
        let handler = fixture.controller.niriLayoutHandler
        let driver = fixture.manager.animationDriver
        let motion = try XCTUnwrap(driver.edgeScroll(in: fixture.workspaceId))
        let last = try XCTUnwrap(fixture.engine.columns(in: fixture.workspaceId).last)
        last.width = .proportion(2.0 / 3.0)
        last.cachedWidth = 0

        handler.tickScrollAnimation(targetTime: motion.startTime + 60, displayId: fixture.monitor.displayId)

        XCTAssertTrue(driver.hasEdgeScroll(in: fixture.workspaceId))
        XCTAssertTrue(handler.hasScrollAnimation(for: fixture.workspaceId))
    }

    func testTheEdgeZoneAtAnEdgeSharedWithAnotherDisplayWorksLikeAnOuterOne() throws {
        let fixture = try makeFixture(pid: 938_305, windowCount: 6)
        let right = try addDisplay(rightOf: fixture)
        let clock = edgeClock(fixture)
        try fixture.startLiveDrag(fixture.tokens[1])

        fixture.drag(to: edgePoint(.trailing, fixture))
        XCTAssertEqual(fixture.handler.state.liveEdgeScroll?.edge, .trailing)
        clock.now += 0.3
        fixture.handler.startLiveEdgeScrollIfDue()

        XCTAssertTrue(fixture.handler.isLiveEdgeScrolling)
        XCTAssertNotEqual(fixture.manager.monitor(for: fixture.workspaceId)?.id, right.id)
    }

    func testAQuickCrossingToAnotherDisplayStartsNoEdgeScroll() throws {
        let fixture = try makeFixture(pid: 938_307, windowCount: 6)
        let right = try addDisplay(rightOf: fixture)
        let clock = edgeClock(fixture)
        try fixture.startLiveDrag(fixture.tokens[1])

        fixture.drag(to: edgePoint(.trailing, fixture))
        clock.now += 0.1
        fixture.drag(to: CGPoint(x: right.frame.midX, y: right.frame.midY))
        clock.now += 0.3
        fixture.handler.startLiveEdgeScrollIfDue()

        XCTAssertFalse(fixture.handler.isLiveEdgeScrolling)
        XCTAssertFalse(fixture.manager.animationDriver.hasEdgeScroll(in: fixture.workspaceId))
    }

    private func addDisplay(rightOf fixture: Fixture) throws -> Monitor {
        let frame = fixture.monitor.frame.offsetBy(dx: fixture.monitor.frame.width, dy: 0)
        let right = Monitor(
            id: .init(displayId: 93_802),
            displayId: 93_802,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Live Title Bar Drag, right"
        )
        fixture.manager.applyMonitorConfigurationChange([fixture.monitor, right])
        XCTAssertEqual(fixture.manager.monitor(for: fixture.workspaceId)?.id, fixture.monitor.id)
        return right
    }

    func testStackModeEdgeScrollOpensNoLandingGaps() throws {
        let fixture = try makeFixture(pid: 938_095, windowCount: 6)
        fixture.handler.modifierFlagsProvider = { .maskAlternate }
        try startEdgeScroll(.trailing, dragging: fixture.tokens[1], in: fixture)
        let swaps = fixture.engine.liveColumnMove?.swapCount
        var sawLandingWhileScrolling = false

        tickEdgeScroll(fixture) {
            if fixture.handler.isLiveEdgeScrolling, fixture.engine.liveColumnMove?.landing != nil {
                sawLandingWhileScrolling = true
            }
            return false
        }

        XCTAssertFalse(sawLandingWhileScrolling)
        XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, swaps)
        XCTAssertFalse(fixture.handler.isLiveEdgeScrolling)
    }

    func testStartingTheEdgeScrollInStackModeClosesTheLandingGap() throws {
        let fixture = try makeFixture(pid: 938_096, windowCount: 6)
        let clock = edgeClock(fixture)
        try fixture.startLiveDrag(fixture.tokens[1])
        fixture.handler.modifierFlagsProvider = { .maskAlternate }
        fixture.drag(to: edgePoint(.trailing, fixture))
        settleLiveDrag(fixture)
        XCTAssertNotNil(fixture.engine.liveColumnMove?.landing)

        clock.now += 0.3
        fixture.handler.startLiveEdgeScrollIfDue()

        XCTAssertTrue(fixture.handler.isLiveEdgeScrolling)
        XCTAssertNil(fixture.engine.liveColumnMove?.landing)
    }

    func testWhenTheStackModeEdgeScrollStopsTheColumnUnderThePointerOpensItsGap() throws {
        let fixture = try makeFixture(pid: 938_097, windowCount: 6)
        fixture.handler.modifierFlagsProvider = { .maskAlternate }
        try startEdgeScroll(.trailing, dragging: fixture.tokens[1], in: fixture)
        XCTAssertNil(fixture.engine.liveColumnMove?.landing)
        let target = try XCTUnwrap(fixture.tokens.last)

        fixture.drag(to: try fixture.farHalf(of: target))

        XCTAssertFalse(fixture.handler.isLiveEdgeScrolling)
        XCTAssertNotNil(fixture.engine.liveColumnMove?.landing)
    }

    func testReleasingDuringAStackModeEdgeScrollStacksOntoTheWindowUnderThePointer() throws {
        let fixture = try makeFixture(pid: 938_098, windowCount: 6)
        let dragged = fixture.tokens[1]
        fixture.handler.modifierFlagsProvider = { .maskAlternate }
        try startEdgeScroll(.trailing, dragging: dragged, in: fixture)
        let columnCount = fixture.engine.columns(in: fixture.workspaceId).count
        var ticks = 0
        tickEdgeScroll(fixture) {
            ticks += 1
            return ticks > 20
        }
        XCTAssertTrue(fixture.handler.isLiveEdgeScrolling)
        XCTAssertNil(fixture.engine.liveColumnMove?.landing)

        fixture.handler.dispatchMouseUp(at: edgePoint(.trailing, fixture))

        let column = try column(holding: dragged, in: fixture)
        XCTAssertEqual(column.windowNodes.count, 2)
        XCTAssertLessThan(fixture.engine.columns(in: fixture.workspaceId).count, columnCount)
    }

    func testReleasingOptionDuringTheEdgeScrollSwapsColumnsAgain() throws {
        let fixture = try makeFixture(pid: 938_099, windowCount: 6)
        fixture.handler.modifierFlagsProvider = { .maskAlternate }
        try startEdgeScroll(.trailing, dragging: fixture.tokens[1], in: fixture)
        let swaps = fixture.engine.liveColumnMove?.swapCount ?? 0

        fixture.handler.modifierFlagsProvider = { [] }
        fixture.handler.updateLiveColumnDrag(at: edgePoint(.trailing, fixture))
        XCTAssertEqual(fixture.engine.liveColumnMove?.stackMode, false)
        XCTAssertTrue(fixture.handler.isLiveEdgeScrolling)
        tickEdgeScroll(fixture)

        XCTAssertGreaterThan(fixture.engine.liveColumnMove?.swapCount ?? 0, swaps)
    }

    private func settleLiveDrag(_ fixture: Fixture) {
        guard fixture.engine.liveColumnMove?.phase == .settling else { return }
        fixture.manager.animationDriver.removeMotions(for: [fixture.workspaceId])
        _ = fixture.engine.cancelAnimations(in: fixture.workspaceId)
        fixture.handler.handleNiriAnimationsSettled(in: fixture.workspaceId)
    }

    private func edgeClock(_ fixture: Fixture) -> EdgeClock {
        let clock = EdgeClock()
        fixture.handler.liveDragClock = { clock.now }
        return clock
    }

    private func edgePoint(_ edge: MouseInputState.LiveEdgeScroll.Edge, _ fixture: Fixture) -> CGPoint {
        let frame = fixture.monitor.frame
        return CGPoint(x: edge == .trailing ? frame.maxX - 10 : frame.minX + 10, y: frame.midY)
    }

    private func startLiveDragInsideTheEdgeZone(
        _ edge: MouseInputState.LiveEdgeScroll.Edge,
        dragging token: WindowToken,
        in fixture: Fixture
    ) throws -> CGPoint {
        let frame = fixture.monitor.frame
        let zone = fixture.engine.moveConfiguration.liveEdgeZoneWidth(forDisplayWidth: frame.width)
        let start = CGPoint(x: edge == .trailing ? frame.maxX - zone / 2 : frame.minX + zone / 2, y: frame.midY)
        try fixture.beginDrag(token)
        fixture.drag(to: start)
        try fixture.macOSMoves(token, to: try fixture.frame(token).offsetBy(dx: 30, dy: 0))
        return start
    }

    private func startEdgeScroll(
        _ edge: MouseInputState.LiveEdgeScroll.Edge,
        dragging token: WindowToken,
        in fixture: Fixture
    ) throws {
        let clock = edgeClock(fixture)
        fixture.engine.moveConfiguration.liveHoverDelay = 0.12
        try fixture.startLiveDrag(token)
        let start = try fixture.centre(of: token)
        let end = edgePoint(edge, fixture)
        let steps = max(1, Int(abs(end.x - start.x) / 40))
        for step in 1 ... steps {
            let x = start.x + (end.x - start.x) * CGFloat(step) / CGFloat(steps)
            fixture.drag(to: CGPoint(x: x, y: end.y))
            if fixture.engine.liveColumnMove?.phase == .settling {
                fixture.manager.animationDriver.removeMotions(for: [fixture.workspaceId])
                _ = fixture.engine.cancelAnimations(in: fixture.workspaceId)
                fixture.handler.handleNiriAnimationsSettled(in: fixture.workspaceId)
            }
        }
        clock.now += 0.3
        fixture.handler.startLiveEdgeScrollIfDue()
        XCTAssertTrue(fixture.handler.isLiveEdgeScrolling)
    }

    private func tickEdgeScroll(_ fixture: Fixture, until done: () -> Bool = { false }) {
        let driver = fixture.manager.animationDriver
        var motion: EdgeScrollAnimation?
        var elapsed = 0.0
        for _ in 0 ..< 5_000 {
            guard let current = driver.edgeScroll(in: fixture.workspaceId) else { return }
            if current !== motion {
                motion = current
                elapsed = 0
            }
            elapsed += 1.0 / 60
            let time = current.startTime + elapsed
            _ = driver.tickResult(in: fixture.workspaceId, at: time)
            fixture.handler.handleLiveEdgeScrollTick(in: fixture.workspaceId, at: time)
            if done() { return }
        }
        XCTFail("Edge scroll did not finish")
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
        tabbedRuns: [ClosedRange<Int>] = [],
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
        var stackTop: NiriWindow?
        for (index, token) in tokens.enumerated() {
            let joinsStack = (stackFirstTwo && index == 1)
                || tabbedRuns.contains { $0.contains(index) && $0.lowerBound != index }
            if joinsStack, let top = stackTop {
                let window = NiriWindow(token: token)
                controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
                    engine.attachTransferredWindow(
                        window,
                        stackedWith: top,
                        after: true,
                        in: workspaceId,
                        state: &state
                    )
                }
                stackTop = window
                continue
            }
            previous = engine.addWindow(token: token, to: workspaceId, afterSelection: previous?.id)
            stackTop = previous
        }
        for run in tabbedRuns {
            let head = try XCTUnwrap(engine.findNode(for: tokens[run.lowerBound], in: workspaceId))
            let column = try XCTUnwrap(engine.findColumn(containing: head, in: workspaceId))
            controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
                column.displayMode = .tabbed
                column.setActiveTileIdx(1)
                engine.updateTabbedColumnVisibility(column: column)
            }
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

    private func column(holding token: WindowToken, in fixture: Fixture) throws -> NiriContainer {
        let window = try XCTUnwrap(fixture.engine.findNode(for: token, in: fixture.workspaceId))
        return try XCTUnwrap(fixture.engine.findColumn(containing: window, in: fixture.workspaceId))
    }

    private func railCommand(
        for column: NiriContainer,
        in fixture: Fixture
    ) throws -> TabRailGeometryCommand {
        let commands = fixture.controller.niriLayoutHandler.niriTabRailGeometryCommands(
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            monitor: fixture.controller.layoutRefreshController.buildMonitorSnapshot(for: fixture.monitor)
        )
        return try XCTUnwrap(commands.first { $0.key.owner == .niriColumn(column.id) })
    }

    private func railOwners(_ fixture: Fixture) -> [TabRailOwner] {
        fixture.controller.niriLayoutHandler.desiredTabRailInfos().map(\.owner)
    }

    func testTheDraggedTabbedColumnsRailHidesAsSoonAsTheDragStarts() throws {
        let fixture = try makeFixture(pid: 938_309, windowCount: 6, tabbedRuns: [0 ... 2, 4 ... 5])
        let dragged = try column(holding: fixture.tokens[1], in: fixture)
        let reconciler = fixture.controller.surfaceReconciler
        addTeardownBlock { @MainActor [controller = fixture.controller] in
            controller.tabRailManager.removeAll()
        }
        try fixture.beginDrag(fixture.tokens[1])
        reconciler.reconcileNow()
        XCTAssertTrue(reconciler.appliedScene.tabRails.contains { $0.owner == .niriColumn(dragged.id) })

        try fixture.macOSMoves(fixture.tokens[1], to: try fixture.frame(fixture.tokens[1]).offsetBy(dx: 30, dy: 0))
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)

        XCTAssertEqual(reconciler.pendingReconcileScope, .fullScene)
        reconciler.reconcileNow()
        XCTAssertFalse(reconciler.appliedScene.tabRails.contains { $0.owner == .niriColumn(dragged.id) })
    }

    func testDraggingATabbedColumnsVisibleWindowMovesTheWholeColumnAndKeepsItsTabs() throws {
        let fixture = try makeFixture(pid: 938_060, windowCount: 6, tabbedRuns: [0 ... 2])
        let (head, dragged, neighbour) = (fixture.tokens[0], fixture.tokens[1], fixture.tokens[3])
        let column = try column(holding: dragged, in: fixture)
        let windows = column.windowNodes.map(\.token)
        let sizing = fixture.engine.containerSizingState(for: column)
        XCTAssertTrue(column.isTabbed)
        XCTAssertEqual(column.activeTileIdx, 1)

        try fixture.startLiveDrag(dragged)

        XCTAssertNotNil(fixture.engine.liveColumnMove)
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertTrue(fixture.engine.isLiveDraggedColumn(column))
        let drop = try fixture.centre(of: neighbour)
        fixture.drag(to: drop)
        fixture.handler.dispatchMouseUp(at: drop)

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertEqual(fixture.order(), [neighbour, head, fixture.tokens[4], fixture.tokens[5]])
        XCTAssertEqual(column.windowNodes.map(\.token), windows)
        XCTAssertEqual(column.activeTileIdx, 1)
        XCTAssertEqual(column.displayMode, .tabbed)
        XCTAssertEqual(fixture.engine.containerSizingState(for: column), sizing)
        XCTAssertEqual(
            fixture.manager.niriViewportState(for: fixture.workspaceId).selectedNodeId,
            fixture.engine.findNode(for: dragged, in: fixture.workspaceId)?.id
        )
    }

    func testTheDraggedTabbedColumnsRailHidesDuringTheDragAndReturnsAtItsNewPlace() throws {
        let fixture = try makeFixture(pid: 938_061, windowCount: 6, tabbedRuns: [0 ... 2, 4 ... 5])
        let dragged = try column(holding: fixture.tokens[1], in: fixture)
        let other = try column(holding: fixture.tokens[4], in: fixture)
        XCTAssertNotEqual(try railCommand(for: dragged, in: fixture).visibleTileFrame, .null)
        XCTAssertEqual(Set(railOwners(fixture)), [.niriColumn(dragged.id), .niriColumn(other.id)])

        try fixture.startLiveDrag(fixture.tokens[1])
        _ = try fixture.frames()

        XCTAssertEqual(try railCommand(for: dragged, in: fixture).visibleTileFrame, .null)
        XCTAssertEqual(try railCommand(for: dragged, in: fixture).tileFrame, .zero)
        XCTAssertNotEqual(try railCommand(for: other, in: fixture).visibleTileFrame, .null)
        XCTAssertEqual(railOwners(fixture), [.niriColumn(other.id)])

        let drop = try fixture.centre(of: fixture.tokens[3])
        fixture.drag(to: drop)
        fixture.handler.dispatchMouseUp(at: drop)
        _ = try fixture.frames(animationTime: CACurrentMediaTime() + 60)

        let returned = try railCommand(for: dragged, in: fixture)
        XCTAssertEqual(returned.tileFrame, dragged.renderedFrame)
        XCTAssertNotEqual(returned.visibleTileFrame, .null)
        XCTAssertEqual(Set(railOwners(fixture)), [.niriColumn(dragged.id), .niriColumn(other.id)])
    }

    func testAnEdgeScrollWithATabbedColumnMovesTheDropSpaceOnceEachUntilTheStripEnd() throws {
        let fixture = try makeFixture(pid: 938_062, windowCount: 8, tabbedRuns: [1 ... 3])
        let dragged = try column(holding: fixture.tokens[2], in: fixture)
        let landingIndex = { () -> Int? in
            let columns = fixture.engine.columns(in: fixture.workspaceId)
            return columns.filter { $0 !== dragged }.firstIndex { $0.isLiveDropSpace }
                ?? columns.firstIndex { $0 === dragged }
        }
        try startEdgeScroll(.trailing, dragging: fixture.tokens[2], in: fixture)
        let startIndex = try XCTUnwrap(landingIndex())
        let startSwaps = fixture.engine.liveColumnMove?.swapCount ?? 0

        var indices = [startIndex]
        tickEdgeScroll(fixture) {
            if let index = landingIndex(), index != indices.last {
                indices.append(index)
            }
            return false
        }

        let afterFirstMove = Array(indices.dropFirst())
        XCTAssertGreaterThan(try XCTUnwrap(afterFirstMove.first), startIndex)
        XCTAssertEqual(afterFirstMove, Array(try XCTUnwrap(afterFirstMove.first) ... 5))
        XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, startSwaps + afterFirstMove.count)
        XCTAssertEqual(dragged.windowNodes.count, 3)
        XCTAssertTrue(dragged.isTabbed)
    }

    func testHoldingTheStackModifierStacksOntoTheWindowUnderThePointerOnRelease() throws {
        let fixture = try makeFixture(pid: 938_070)
        let (dragged, target) = (fixture.tokens[1], fixture.tokens[2])
        try fixture.startLiveDrag(dragged)
        fixture.handler.modifierFlagsProvider = { .maskAlternate }
        let targetFrame = try fixture.frame(target)
        let drop = CGPoint(x: targetFrame.midX, y: targetFrame.minY + targetFrame.height / 4)

        fixture.drag(to: drop)
        XCTAssertEqual(fixture.engine.liveColumnMove?.stackMode, true)
        XCTAssertNotNil(fixture.engine.liveColumnMove?.landing)
        fixture.handler.dispatchMouseUp(at: drop)

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertFalse(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))
        let column = try column(holding: target, in: fixture)
        XCTAssertEqual(column.windowNodes.map(\.token), [dragged, target])
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 3)
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.windowNodes.isEmpty })
        XCTAssertLessThan(try fixture.settledFrame(dragged).maxY, try fixture.settledFrame(target).minY)
        XCTAssertFalse(fixture.handler.liveDragModifierCapture.isActive)
    }

    func testReleasingTheStackModifierBeforeTheMouseDropsWithoutStackingOrSwapping() throws {
        let fixture = try makeFixture(pid: 938_071)
        let order = fixture.order()
        try fixture.startLiveDrag(fixture.tokens[1])
        fixture.handler.modifierFlagsProvider = { .maskAlternate }
        let targetFrame = try fixture.frame(fixture.tokens[2])
        let point = CGPoint(x: targetFrame.midX, y: targetFrame.minY + targetFrame.height / 4)
        fixture.drag(to: point)
        XCTAssertNotNil(fixture.engine.liveColumnMove?.landing)

        fixture.handler.modifierFlagsProvider = { [] }
        fixture.handler.updateLiveColumnDrag(at: point)
        XCTAssertEqual(fixture.engine.liveColumnMove?.stackMode, false)
        XCTAssertNil(fixture.engine.liveColumnMove?.landing)
        fixture.handler.updateLiveColumnDrag(at: point)
        XCTAssertEqual(fixture.order(), order)
        fixture.handler.dispatchMouseUp(at: point)

        XCTAssertEqual(fixture.order(), order)
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.windowNodes.count > 1 })
    }

    func testTheStackModifierAtMouseDownArmsTheTitleBarDragInsteadOfTheMove() throws {
        let fixture = try makeFixture(pid: 938_072)
        let token = fixture.tokens[1]
        let start = try fixture.frame(token)
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        XCTAssertEqual(fixture.controller.settings.gestures.mouseMoveModifierKey, .option)
        XCTAssertEqual(fixture.controller.settings.niri.naturalWindowDragModifier, .option)

        XCTAssertFalse(fixture.handler.dispatchMouseDown(
            at: CGPoint(x: start.midX, y: start.maxY - 10),
            modifiers: .maskAlternate,
            windowIdUnderPointer: token.windowId
        ))

        XCTAssertFalse(fixture.handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.token, token)
    }

    func testWithTheSettingOffOrADifferentStackModifierTheMoveStillStarts() throws {
        for configure in [
            { (fixture: Fixture) in fixture.controller.settings.niri.naturalWindowDrag = false },
            { (fixture: Fixture) in fixture.controller.settings.niri.naturalWindowDragModifier = .control }
        ] {
            let fixture = try makeFixture(pid: 938_073)
            configure(fixture)
            let token = fixture.tokens[1]
            let start = try fixture.frame(token)
            fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }

            XCTAssertFalse(fixture.handler.dispatchMouseDown(
                at: CGPoint(x: start.midX, y: start.midY),
                modifiers: .maskAlternate,
                windowIdUnderPointer: token.windowId
            ))

            XCTAssertTrue(fixture.handler.state.isMoving)
            XCTAssertNotNil(fixture.engine.interactiveMove)
            fixture.handler.cancelActiveMouseInteraction()
        }
    }

    func testADragStartedWithTheStackModifierHeldIsInStackModeFromTheStart() throws {
        let fixture = try makeFixture(pid: 938_074)
        fixture.controller.settings.niri.naturalWindowDragModifier = .control
        fixture.handler.modifierFlagsProvider = { .maskControl }
        let target = try column(holding: fixture.tokens[2], in: fixture)

        try fixture.startLiveDrag(fixture.tokens[1])
        fixture.drag(to: try fixture.farHalf(of: fixture.tokens[2]))

        XCTAssertEqual(fixture.engine.liveColumnMove?.stackMode, true)
        XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, 0)
        XCTAssertEqual(fixture.engine.liveColumnMove?.landing?.columnId, target.id)
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 4)

        fixture.handler.modifierFlagsProvider = { .maskAlternate }
        fixture.handler.updateLiveColumnDrag(at: try fixture.centre(of: fixture.tokens[2]))
        XCTAssertEqual(fixture.engine.liveColumnMove?.stackMode, false)
    }

    func testAModifierChangeSeenByTheKeyTapSwitchesStackModeWithoutAMouseMove() throws {
        let fixture = try makeFixture(pid: 938_077, hoverDelay: 60)
        try fixture.startLiveDrag(fixture.tokens[1])
        let targetFrame = try fixture.frame(fixture.tokens[2])
        fixture.drag(to: CGPoint(x: targetFrame.midX, y: targetFrame.minY + targetFrame.height / 4))
        XCTAssertEqual(fixture.engine.liveColumnMove?.stackMode, false)
        let capture = fixture.handler.liveDragModifierCapture

        capture.reportModifiersChanged(.maskAlternate)
        let pressed = expectation(description: "Modifier press handled")
        DispatchQueue.main.async { pressed.fulfill() }
        wait(for: [pressed], timeout: 1)
        XCTAssertEqual(fixture.engine.liveColumnMove?.stackMode, true)
        XCTAssertNotNil(fixture.engine.liveColumnMove?.landing)

        capture.reportModifiersChanged([])
        let released = expectation(description: "Modifier release handled")
        DispatchQueue.main.async { released.fulfill() }
        wait(for: [released], timeout: 1)
        XCTAssertEqual(fixture.engine.liveColumnMove?.stackMode, false)
        XCTAssertNil(fixture.engine.liveColumnMove?.landing)

        fixture.handler.cancelLiveColumnDrag()
        capture.reportModifiersChanged(.maskAlternate)
        let ignored = expectation(description: "Modifier after the drag ignored")
        DispatchQueue.main.async { ignored.fulfill() }
        wait(for: [ignored], timeout: 1)
        XCTAssertNil(fixture.engine.liveColumnMove)
    }

    func testCancellingInStackModeRestoresTheLayout() throws {
        let fixture = try makeFixture(pid: 938_075)
        let order = fixture.order()
        try fixture.startLiveDrag(fixture.tokens[1])
        fixture.handler.modifierFlagsProvider = { .maskAlternate }
        fixture.drag(to: try fixture.farHalf(of: fixture.tokens[2]))
        XCTAssertNotNil(fixture.engine.liveColumnMove?.landing)

        fixture.handler.cancelLiveColumnDrag()

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertEqual(fixture.order(), order)
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.windowNodes.count != 1 })
    }

    func testATabbedTargetShowsABlankRailEntryForTheDraggedWindow() throws {
        let fixture = try makeFixture(pid: 938_076, windowCount: 5, tabbedRuns: [2 ... 3])
        let tabbed = try column(holding: fixture.tokens[2], in: fixture)
        try fixture.startLiveDrag(fixture.tokens[0])
        fixture.handler.modifierFlagsProvider = { .maskAlternate }

        fixture.drag(to: try fixture.farHalf(of: fixture.tokens[3]))
        XCTAssertEqual(tabbed.windowNodes.count, 3)

        let info = try XCTUnwrap(fixture.controller.niriLayoutHandler.desiredTabRailInfos().first {
            $0.owner == .niriColumn(tabbed.id)
        })
        XCTAssertEqual(info.tabCount, 3)
        XCTAssertEqual(info.tabs.filter { $0.token == nil }.count, 1)
        let blank = try XCTUnwrap(info.tabs.firstIndex { $0.token == nil })
        XCTAssertEqual(blank, info.activeVisualIndex + 1)
    }

    private func railInfo(holding token: WindowToken, in fixture: Fixture) throws -> TabRailInfo {
        let column = try column(holding: token, in: fixture)
        return try XCTUnwrap(fixture.controller.niriLayoutHandler.desiredTabRailInfos().first {
            $0.owner == .niriColumn(column.id)
        })
    }

    private func tabPull(
        _ token: WindowToken,
        at location: CGPoint,
        rail info: TabRailInfo,
        pressedAt pressLocation: CGPoint? = nil,
        in fixture: Fixture
    ) {
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        fixture.handler.handleTabRailDrag(TabRailDrag(
            info: info,
            visualIndex: 0,
            token: token,
            location: location,
            pressLocation: pressLocation ?? location
        ))
    }

    func testDraggingATabInTheRailPullsItOutAndTheWindowFollowsThePointer() throws {
        let fixture = try makeFixture(pid: 938_080, windowCount: 5, tabbedRuns: [1 ... 2])
        let (kept, pulled, neighbour) = (fixture.tokens[1], fixture.tokens[2], fixture.tokens[3])
        let tabbed = try column(holding: pulled, in: fixture)
        XCTAssertTrue(tabbed.windowNodes[tabbed.activeTileIdx].token == pulled)
        let rail = try railInfo(holding: pulled, in: fixture)
        let start = try fixture.frame(pulled)
        fixture.handler.nativeWindowFrameProvider = { _ in start }
        let press = CGPoint(x: start.minX - 10, y: start.midY)

        tabPull(pulled, at: press, rail: rail, in: fixture)
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.engine.liveColumnMove?.pullsTab, true)
        XCTAssertEqual(tabbed.windowNodes.map(\.token), [kept])
        XCTAssertEqual(tabbed.displayMode, .normal)
        XCTAssertNil(fixture.controller.niriLayoutHandler.desiredTabRailInfos().first {
            $0.owner == .niriColumn(tabbed.id)
        })
        XCTAssertTrue(fixture.handler.liveDragModifierCapture.isActive)
        XCTAssertEqual(fixture.engine.liveFloatingFrame(for: pulled, in: fixture.workspaceId), start)

        let away = try fixture.centre(of: neighbour)
        fixture.drag(to: away)
        XCTAssertEqual(
            fixture.engine.liveFloatingFrame(for: pulled, in: fixture.workspaceId),
            start.offsetBy(dx: away.x - press.x, dy: away.y - press.y)
        )
        XCTAssertEqual(tabbed.windowNodes.map(\.token), [kept])
        XCTAssertEqual(tabbed.displayMode, .normal)

        fixture.handler.dispatchMouseUp(at: away)
        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertFalse(fixture.handler.liveDragModifierCapture.isActive)
        XCTAssertEqual(try column(holding: pulled, in: fixture).windowNodes.map(\.token), [pulled])
    }

    func testTheLayoutWritesTheFloatingFrameOfAPulledTab() throws {
        let fixture = try makeFixture(pid: 938_081, windowCount: 4, tabbedRuns: [1 ... 2])
        let pulled = fixture.tokens[2]
        let rail = try railInfo(holding: pulled, in: fixture)
        let start = try fixture.frame(pulled)
        fixture.handler.nativeWindowFrameProvider = { _ in start }
        tabPull(pulled, at: CGPoint(x: start.minX - 10, y: start.midY), rail: rail, in: fixture)
        let floating = try XCTUnwrap(fixture.engine.liveFloatingFrame(for: pulled, in: fixture.workspaceId))

        let diff = fixture.controller.niriLayoutHandler.layoutDiff(
            windows: [LayoutWindowSnapshot(
                token: pulled,
                constraints: .unconstrained,
                hiddenState: nil,
                layoutReason: .standard
            )],
            frames: [pulled: try fixture.frame(fixture.tokens[1])],
            hiddenHandles: [:],
            context: NiriLayoutDiffContext(
                engine: fixture.engine,
                workspaceId: fixture.workspaceId,
                canRestoreHiddenWorkspaceWindows: false,
                reassertHidden: false
            )
        )

        XCTAssertEqual(diff.frameChanges.map(\.token), [pulled])
        XCTAssertEqual(diff.frameChanges.first?.frame, floating)
    }

    func testCancellingATabPullPutsTheTabBack() throws {
        let fixture = try makeFixture(pid: 938_082, windowCount: 4, tabbedRuns: [1 ... 2])
        let pulled = fixture.tokens[2]
        let tabbed = try column(holding: pulled, in: fixture)
        let tabs = tabbed.windowNodes.map(\.token)
        let rail = try railInfo(holding: pulled, in: fixture)
        let start = try fixture.frame(pulled)
        fixture.handler.nativeWindowFrameProvider = { _ in start }
        tabPull(pulled, at: CGPoint(x: start.minX - 10, y: start.midY), rail: rail, in: fixture)
        fixture.drag(to: try fixture.farHalf(of: fixture.tokens[3]))
        XCTAssertEqual(tabbed.windowNodes.count, 1)

        fixture.handler.cancelLiveColumnDrag()
        fixture.handler.dispatchMouseUp(at: try fixture.centre(of: fixture.tokens[3]))

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertEqual(tabbed.windowNodes.map(\.token), tabs)
        XCTAssertTrue(tabbed.isTabbed)
        XCTAssertEqual(tabbed.windowNodes[tabbed.activeTileIdx].token, pulled)
    }

    func testATabPullNeedsTheSetting() throws {
        let fixture = try makeFixture(pid: 938_083, windowCount: 4, tabbedRuns: [1 ... 2])
        fixture.controller.settings.niri.naturalWindowDrag = false
        let pulled = fixture.tokens[2]
        let rail = try railInfo(holding: pulled, in: fixture)
        let start = try fixture.frame(pulled)
        fixture.handler.nativeWindowFrameProvider = { _ in start }

        tabPull(pulled, at: CGPoint(x: start.minX - 10, y: start.midY), rail: rail, in: fixture)

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
    }

    func testATabPullCarriesOnThroughTheMouseTapOnceTheRailIsGone() throws {
        let fixture = try makeFixture(pid: 938_084, windowCount: 5, tabbedRuns: [1 ... 2])
        let (kept, pulled) = (fixture.tokens[1], fixture.tokens[2])
        let tabbed = try column(holding: pulled, in: fixture)
        let rail = try railInfo(holding: pulled, in: fixture)
        let start = try fixture.frame(pulled)
        fixture.handler.nativeWindowFrameProvider = { _ in start }
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        let press = CGPoint(x: start.minX - 10, y: start.midY)
        tabPull(pulled, at: press, rail: rail, in: fixture)

        let away = try fixture.centre(of: fixture.tokens[3])
        fixture.drag(to: away)

        XCTAssertEqual(tabbed.windowNodes.map(\.token), [kept])
        XCTAssertEqual(tabbed.displayMode, .normal)
        XCTAssertNil(fixture.controller.niriLayoutHandler.desiredTabRailInfos().first {
            $0.owner == .niriColumn(tabbed.id)
        })
        XCTAssertEqual(
            fixture.engine.liveFloatingFrame(for: pulled, in: fixture.workspaceId),
            start.offsetBy(dx: away.x - press.x, dy: away.y - press.y)
        )

        fixture.handler.dispatchMouseUp(at: away)

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(try column(holding: pulled, in: fixture).windowNodes.map(\.token), [pulled])
        XCTAssertEqual(tabbed.windowNodes.map(\.token), [kept])
    }

    func testATabPullStartsFromTheLayoutFrameAtThePointerNotFromAStaleFrame() throws {
        let fixture = try makeFixture(pid: 938_085, windowCount: 4, tabbedRuns: [1 ... 2])
        let pulled = fixture.tokens[2]
        let rail = try railInfo(holding: pulled, in: fixture)
        let layoutFrame = try fixture.frame(pulled)
        fixture.handler.nativeWindowFrameProvider = { _ in CGRect(x: -6000, y: -6000, width: 400, height: 300) }
        let press = CGPoint(x: layoutFrame.minX - 10, y: layoutFrame.midY)
        let began = CGPoint(x: press.x + 12, y: press.y)

        tabPull(pulled, at: began, rail: rail, pressedAt: press, in: fixture)

        XCTAssertEqual(fixture.engine.liveFloatingFrame(for: pulled, in: fixture.workspaceId), layoutFrame)
        let next = CGPoint(x: began.x + 50, y: began.y - 20)
        fixture.drag(to: next)
        XCTAssertEqual(
            fixture.engine.liveFloatingFrame(for: pulled, in: fixture.workspaceId),
            layoutFrame.offsetBy(dx: 50, dy: -20)
        )
    }
}
