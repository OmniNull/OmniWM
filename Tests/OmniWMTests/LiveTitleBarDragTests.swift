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
        static let titleBarInset: CGFloat = 10
        static let animationSampleRate: Double = 60

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
            try XCTUnwrap(frames(animationTime: .infinity)[token])
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
                at: CGPoint(x: start.midX, y: start.maxY - Self.titleBarInset),
                modifiers: [],
                windowIdUnderPointer: token.windowId
            ))
            handler.dispatchMouseDragged(at: CGPoint(x: start.midX + 5, y: start.maxY - Self.titleBarInset))
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
            let location = CGPoint(x: visible.midX, y: start.maxY - Self.titleBarInset)
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
            let vertical = controller.settings.monitors.effectiveOrientation(for: monitor) == .vertical
            let start = vertical ? max(frame.minY, working.minY) : max(frame.minX, working.minX)
            let end = vertical ? min(frame.maxY, working.maxY) : min(frame.maxX, working.maxX)
            let quarter = (end - start) / 4
            let primary = target > home ? end - quarter : start + quarter
            return vertical ? CGPoint(x: frame.midX, y: primary) : CGPoint(x: primary, y: frame.midY)
        }
    }

    func testPortraitTitleBarDragReordersRowsAndRecordsOneUndoableChange() throws {
        let display = CGRect(x: -260, y: 180, width: 900, height: 1_500)
        let fixture = try makeFixture(pid: 938_001, portrait: true, displayFrame: display)
        XCTAssertEqual(fixture.handler.liveColumnContext(for: fixture.workspaceId)?.orientation, .vertical)
        let original = fixture.tokens
        let expected = [1, 0, 2, 3].map { fixture.tokens[$0] }
        let dragged = fixture.tokens[0]
        let start = try fixture.frame(dragged)
        try fixture.startLiveDrag(dragged)
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        let desired = try fixture.farHalf(of: fixture.tokens[1])
        let target = CGPoint(x: desired.x, y: desired.y + start.height / 2 - Fixture.titleBarInset)
        fixture.drag(to: target)
        XCTAssertEqual(fixture.landingOrder(), expected)
        let sequence = fixture.manager.worldSeq
        fixture.drag(to: target)
        XCTAssertEqual(fixture.manager.worldSeq, sequence)
        fixture.handler.dispatchMouseUp(at: target)
        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertEqual(fixture.order(), expected)
        let history = fixture.controller.niriLayoutHandler
        XCTAssertTrue(history.stepLayoutHistory(.undo, in: fixture.workspaceId))
        XCTAssertEqual(fixture.order(), original)
        XCTAssertTrue(history.stepLayoutHistory(.redo, in: fixture.workspaceId))
        XCTAssertEqual(fixture.order(), expected)
    }

    func testATitleBarDragKeepsLivePointerStateForEachLayout() throws {
        let strips: [(pid: pid_t, layout: LayoutType, portrait: Bool)] = [
            (938_404, .niri, false), (938_405, .niri, true), (938_406, .dwindle, false)
        ]
        for strip in strips {
            let fixture = try makeFixture(pid: strip.pid, layout: strip.layout, portrait: strip.portrait)
            let niri = strip.layout == .niri
            try fixture.beginDrag(fixture.tokens[1])
            XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.canStartLiveNiriDrag, niri, "\(strip)")
            XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.canStartLiveDwindleDrag, !niri, "\(strip)")
            XCTAssertNotNil(fixture.handler.state.nativeTitleBarDrag?.liveStartFrame, "\(strip)")
            let pointer = CGPoint(x: 430, y: 300)
            _ = fixture.handler.trackLiveColumnDrag(at: pointer, button: .left)
            XCTAssertEqual(fixture.handler.livePointer.location, pointer, "\(strip)")
            XCTAssertEqual(fixture.handler.livePointer.samples.isEmpty, !niri, "\(strip)")
        }
    }

    func testAHandedOverLiveDragKeepsItsLivePointerState() throws {
        let fixture = try makeFixture(pid: 938_407)
        try fixture.startLiveDrag(fixture.tokens[1])
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)

        fixture.handler.handOverLiveColumnDrag()
        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.liveDragHandedOver, true)

        let pointer = CGPoint(x: fixture.monitor.frame.maxX + 40, y: 300)
        _ = fixture.handler.trackLiveColumnDrag(at: pointer, button: .left)

        XCTAssertEqual(fixture.handler.livePointer.location, pointer)
        XCTAssertFalse(fixture.handler.livePointer.samples.isEmpty)
    }

    func testStripPolicySettingsReachTheEngine() throws {
        let fixture = try makeFixture(pid: 938_091)
        let settings = fixture.controller.settings
        settings.quakeTerminal.enabled = false
        fixture.controller.applyPersistedSettings(settings, startServices: false)
        XCTAssertEqual(fixture.engine.policies, NiriStripPolicies(fitsVisibleContainerCount: false))

        settings.niri.fitToVisibleContainerCount = true
        settings.niri.opensNewWindowsAtAppWidth = true
        settings.niri.keepSizeOnUnstack = true
        settings.niri.keepSizesOnDisplayMove = true
        settings.niri.keepStripEndsOnScreen = true
        fixture.controller.applyPersistedSettings(settings, startServices: false)
        XCTAssertEqual(fixture.engine.policies, NiriStripPolicies(
            fitsVisibleContainerCount: true,
            opensNewWindowsAtAppWidth: true,
            keepsSizeOnUnstack: true,
            keepsSizesOnDisplayMove: true,
            keepsStripEndsOnScreen: true
        ))

        settings.niri.keepStripEndsOnScreen = false
        fixture.controller.applyNiriStripPolicies()
        XCTAssertFalse(fixture.engine.policies.keepsStripEndsOnScreen)
    }

    func testPeeksFollowTheirPercentage() throws {
        let fixture = try makeFixture(pid: 938_191)
        let settings = fixture.controller.settings
        settings.quakeTerminal.enabled = false
        let percent: Double = 3
        settings.niri.edgePeekPercent = percent

        fixture.controller.applyPersistedSettings(settings, startServices: false)
        XCTAssertEqual(fixture.engine.edgePeekShare, CGFloat(percent / 100))

        settings.niri.edgePeekPercent = 0
        fixture.controller.applyPersistedSettings(settings, startServices: false)
        XCTAssertNil(fixture.engine.edgePeekShare)
    }

    func testSettingChangesReachTheEngineAtOnce() throws {
        let fixture = try makeFixture(pid: 938_192)
        let settings = fixture.controller.settings

        for percent: Double in [3, 2.5] {
            settings.niri.edgePeekPercent = percent
            fixture.controller.updateNiriConfig(edgePeekShare: fixture.controller.edgePeekShare)
            XCTAssertEqual(fixture.engine.edgePeekShare, CGFloat(percent / 100), "\(percent)%")
        }

        settings.niri.edgePeekPercent = 0
        fixture.controller.updateNiriConfig(edgePeekShare: fixture.controller.edgePeekShare)
        XCTAssertNil(fixture.engine.edgePeekShare)
    }

    func testDwindleTitleBarDragsReorderWithoutStartingNiriMovement() throws {
        let fixture = try makeFixture(pid: 938_050, windowCount: 3, layout: .dwindle)
        XCTAssertEqual(fixture.manager.activeLayoutKind(for: fixture.workspaceId), .dwindle)
        XCTAssertNotNil(fixture.controller.niriEngine?.findNode(for: fixture.tokens[0], in: fixture.workspaceId))
        let (dragged, other) = (fixture.tokens[0], fixture.tokens[1])
        let frames = try fixture.frames()

        try fixture.startLiveDrag(dragged)
        fixture.drag(to: try fixture.farHalf(of: other))

        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
        XCTAssertTrue(fixture.handler.state.nativeTitleBarDrag?.dwindleLiveDrag == true)
        XCTAssertNil(fixture.controller.niriEngine?.liveColumnMove)
        XCTAssertNil(fixture.handler.state.deferredClickScroll)

        fixture.handler.dispatchMouseUp(at: try fixture.centre(of: other))

        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        var expected = frames
        expected[dragged] = frames[other]
        expected[other] = frames[dragged]
        XCTAssertEqual(try fixture.frames(), expected)
        XCTAssertEqual(fixture.controller.dwindleEngine?.layoutHistoryCounts(in: fixture.workspaceId).undo, 1)
    }

    func testMacOSMovingTheWindowStartsALiveDragThatSwapsColumns() throws {
        let fixture = try makeFixture(pid: 938_002)
        let (dragged, neighbour) = (fixture.tokens[1], fixture.tokens[2])

        try fixture.startLiveDrag(dragged)

        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertNotNil(fixture.engine.liveColumnMove)

        fixture.drag(to: try fixture.farHalf(of: neighbour))

        XCTAssertEqual(fixture.landingOrder(), [0, 2, 1, 3].map { fixture.tokens[$0] })
    }

    func testADragEventThatChangesNothingCommitsNoWorldEvent() throws {
        let fixture = try makeFixture(pid: 938_410)
        try fixture.startLiveDrag(fixture.tokens[1])
        let target = try fixture.farHalf(of: fixture.tokens[2])
        let beforeSwap = fixture.manager.worldSeq

        fixture.drag(to: target)
        let swapped = fixture.landingOrder()
        XCTAssertEqual(swapped, [0, 2, 1, 3].map { fixture.tokens[$0] })
        XCTAssertGreaterThan(fixture.manager.worldSeq, beforeSwap)

        let afterSwap = fixture.manager.worldSeq
        fixture.drag(to: target)

        XCTAssertEqual(fixture.manager.worldSeq, afterSwap)
        XCTAssertEqual(fixture.landingOrder(), swapped)
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
    }

    func testADragEventThatShiftsTheStripStoresItsViewportInTheSameWorldEvent() throws {
        let fixture = try makeFixture(pid: 938_411)
        let dragged = fixture.tokens[1]
        try fixture.startLiveDrag(dragged)
        let frame = try fixture.frame(dragged)
        let travel: CGFloat = 1
        let from = CGPoint(x: frame.midX, y: frame.maxY - Fixture.titleBarInset)
        fixture.drag(to: from)
        let viewport = fixture.manager.niriViewportState(for: fixture.workspaceId)
        let recorded = fixture.manager.recordedWorldEventCount

        fixture.drag(to: CGPoint(x: from.x + travel, y: from.y))

        let move = fixture.manager.viewportMutationEvent(in: fixture.workspaceId)
        XCTAssertNotEqual(fixture.manager.niriViewportState(for: fixture.workspaceId), viewport)
        XCTAssertEqual(fixture.manager.worldEvents(after: recorded), [move])
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
    }

    func testTheDraggedWindowsCentreNotThePointerOpensTheHint() throws {
        let fixture = try makeFixture(pid: 938_090)
        let clock = DragClock()
        fixture.handler.liveDragClock = { clock.now }
        let (dragged, target) = (fixture.tokens[1], fixture.tokens[2])
        fixture.handler.retireNativeTitleBarDragAtInputBoundary()
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        let start = try fixture.frame(dragged)
        fixture.reported.frame = start
        fixture.handler.nativeWindowFrameProvider = { [reported = fixture.reported] _ in reported.frame }
        let grab = CGPoint(x: start.minX + 20, y: start.maxY - 10)
        XCTAssertFalse(fixture.handler.dispatchMouseDown(
            at: grab,
            modifiers: [],
            windowIdUnderPointer: dragged.windowId
        ))
        fixture.drag(to: CGPoint(x: grab.x + 5, y: grab.y))
        try fixture.macOSMoves(dragged, to: start.offsetBy(dx: 5, dy: 0))
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        let offset = start.midX - grab.x

        let targetFrame = try fixture.frame(target)
        let pointer = CGPoint(x: targetFrame.midX - offset, y: targetFrame.maxY - targetFrame.height / 4)
        XCTAssertLessThan(pointer.x, targetFrame.minX + targetFrame.width / 3)
        XCTAssertEqual(fixture.handler.liveDragReference(pointer).x, targetFrame.midX, accuracy: 0.5)
        fixture.drag(to: pointer)
        clock.now += 0.2
        fixture.handler.liveDragSession?.hoverTimer?.fire()

        XCTAssertNotNil(fixture.engine.liveColumnMove?.landing)
    }

    func testNearAScreenEdgeTheReferenceEasesIntoThePointer() throws {
        let fixture = try makeFixture(pid: 938_092)
        let display = fixture.monitor.frame
        fixture.handler.liveDragSession = .init(referenceOffset: -300)

        XCTAssertEqual(
            fixture.handler.liveDragReference(CGPoint(x: display.midX, y: 300)).x,
            display.midX - 300,
            accuracy: 0.5
        )
        XCTAssertEqual(
            fixture.handler.liveDragReference(CGPoint(x: display.maxX - 150, y: 300)).x,
            display.maxX - 300,
            accuracy: 0.5
        )
        XCTAssertEqual(
            fixture.handler.liveDragReference(CGPoint(x: display.maxX - 1, y: 300)).x,
            display.maxX - 2,
            accuracy: 0.5
        )
        XCTAssertEqual(
            fixture.handler.liveDragWindowMidX(CGPoint(x: display.maxX - 1, y: 300)) ?? .nan,
            display.maxX - 301,
            accuracy: 0.5
        )
        let samples = stride(from: display.maxX - 400, to: display.maxX, by: 10).map {
            fixture.handler.liveDragReference(CGPoint(x: $0, y: 300)).x
        }
        for (earlier, later) in zip(samples, samples.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later, earlier - 0.5)
            XCTAssertLessThanOrEqual(later - earlier, 20.5)
        }
    }

    func testThePointerCountsAsSlowedOnceItMovesLessThanSixPointsInSixtyMilliseconds() throws {
        let fixture = try makeFixture(pid: 938_121)
        let clock = DragClock()
        fixture.handler.liveDragClock = { clock.now }
        for step in 0 ... 4 {
            clock.now = 1 + Double(step) * 0.016
            fixture.handler.recordLivePointerSample(CGPoint(x: 400 + CGFloat(step) / 4, y: 300))
        }
        XCTAssertTrue(fixture.handler.livePointerHasSlowed(at: clock.now))

        for step in 5 ... 9 {
            clock.now = 1 + Double(step) * 0.016
            fixture.handler.recordLivePointerSample(CGPoint(x: 400 + CGFloat(step) * 5, y: 300))
        }
        XCTAssertFalse(fixture.handler.livePointerHasSlowed(at: clock.now))
    }

    func testAStoppedPointerCountsAsSlowedSixtyMillisecondsAfterItsLastEvent() throws {
        let fixture = try makeFixture(pid: 938_122)
        let clock = DragClock()
        fixture.handler.liveDragClock = { clock.now }
        clock.now = 1
        fixture.handler.recordLivePointerSample(CGPoint(x: 400, y: 300))
        clock.now = 1.03
        fixture.handler.recordLivePointerSample(CGPoint(x: 460, y: 300))

        XCTAssertFalse(fixture.handler.livePointerHasSlowed(at: 1.03))
        XCTAssertEqual(fixture.handler.livePointerStopCheckDelay(at: 1.03) ?? 0, 0.06, accuracy: 0.001)
        XCTAssertFalse(fixture.handler.livePointerHasSlowed(at: 1.07))
        XCTAssertTrue(fixture.handler.livePointerHasSlowed(at: 1.09))
    }

    func testAPointerThatStopsGetsItsDropSpaceBeforeTheHoverDelay() throws {
        let fixture = try makeFixture(pid: 938_123, hoverDelay: 0.2)
        let clock = DragClock()
        fixture.handler.liveDragClock = { clock.now }
        try fixture.startLiveDrag(fixture.tokens[1])
        let order = fixture.order()
        let target = try fixture.farHalf(of: fixture.tokens[2])

        fixture.drag(to: target)

        XCTAssertEqual(fixture.order(), order)
        let timer = try XCTUnwrap(fixture.handler.liveDragSession?.hoverTimer)
        XCTAssertLessThan(timer.fireDate.timeIntervalSinceNow, 0.1)
        clock.now += 0.06
        timer.fire()
        XCTAssertEqual(fixture.landingOrder(), [0, 2, 1, 3].map { fixture.tokens[$0] })
    }

    func testPointerEventsDuringAHoverMoveTheSameCheckTimer() throws {
        let fixture = try makeFixture(pid: 938_124, hoverDelay: 0.2)
        let clock = DragClock()
        fixture.handler.liveDragClock = { clock.now }
        try fixture.startLiveDrag(fixture.tokens[1])
        let target = try fixture.farHalf(of: fixture.tokens[2])

        fixture.drag(to: target)
        let timer = try XCTUnwrap(fixture.handler.liveDragSession?.hoverTimer)
        let elapsed = MoveConfiguration.liveSlowDownWindow / 2
        let fireDateAfterElapsed = timer.fireDate.addingTimeInterval(-elapsed)
        clock.now += elapsed
        timer.fireDate = fireDateAfterElapsed
        fixture.drag(to: CGPoint(x: target.x + 1, y: target.y))

        XCTAssertTrue(fixture.handler.liveDragSession?.hoverTimer === timer)
        XCTAssertTrue(timer.isValid)
        XCTAssertGreaterThan(timer.fireDate, fireDateAfterElapsed)
    }

    func testATabPullKeepsThePointerAsTheReference() throws {
        let fixture = try makeFixture(pid: 938_091)
        fixture.handler.liveDragSession = .init(referenceOffset: 300)
        let point = CGPoint(x: 400, y: 300)
        XCTAssertEqual(fixture.handler.liveDragReference(point), CGPoint(x: 700, y: 300))
        XCTAssertEqual(fixture.handler.liveDragWindowMidX(point), 700)

        fixture.handler.liveDragSession?.carriedWindow = .init(
            token: fixture.tokens[1],
            anchorLocation: point,
            startFrame: try fixture.frame(fixture.tokens[1])
        )

        XCTAssertEqual(fixture.handler.liveDragReference(point), point)
        XCTAssertNil(fixture.handler.liveDragWindowMidX(point))
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
        XCTAssertEqual(fixture.engine.liveColumnMove?.home, .stackSlot)
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
        let drop = try fixture.farHalf(of: neighbour)
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

    func testTheHoverDelayTimerMovesTheColumnWhileThePointerKeepsMovingOverTheTarget() throws {
        let fixture = try makeFixture(pid: 938_013, hoverDelay: 0.12)
        let clock = DragClock()
        fixture.handler.liveDragClock = { clock.now }
        try fixture.startLiveDrag(fixture.tokens[1])
        let order = fixture.order()
        let target = try fixture.farHalf(of: fixture.tokens[2])

        let hoverStart = clock.now
        fixture.drag(to: target)
        for step in 1 ... 5 {
            clock.now = hoverStart + Double(step) * 0.02
            fixture.drag(to: CGPoint(x: target.x + CGFloat(step) * 4, y: target.y))
        }

        XCTAssertEqual(fixture.landingOrder(), order)
        let timer = try XCTUnwrap(fixture.handler.liveDragSession?.hoverTimer)
        clock.now = hoverStart + 0.12
        XCTAssertFalse(fixture.handler.livePointerHasSlowed(at: clock.now))
        timer.fire()
        XCTAssertEqual(fixture.landingOrder(), [0, 2, 1, 3].map { fixture.tokens[$0] })
        XCTAssertNil(fixture.handler.liveDragSession?.hoverTimer)
    }

    func testReleaseOrCancelWhileHoveringStopsTheHoverTimer() throws {
        for ending in ["release", "cancel"] {
            let fixture = try makeFixture(pid: ending == "release" ? 938_014 : 938_015, hoverDelay: 0.12)
            fixture.handler.liveDragClock = { 1_000 }
            try fixture.startLiveDrag(fixture.tokens[1])
            let order = fixture.order()
            let target = try fixture.farHalf(of: fixture.tokens[2])
            fixture.drag(to: target)
            XCTAssertNotNil(fixture.handler.liveDragSession?.hoverTimer, ending)

            if ending == "release" {
                fixture.handler.dispatchMouseUp(at: target)
            } else {
                fixture.handler.cancelLiveColumnDrag()
            }

            XCTAssertNil(fixture.handler.liveDragSession?.hoverTimer, ending)
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

    private func viewOrigin(_ fixture: Fixture) -> CGFloat {
        fixture.manager.niriViewportState(for: fixture.workspaceId).viewPosPixels(
            columns: fixture.engine.columns(in: fixture.workspaceId),
            gap: fixture.controller.innerGap(for: fixture.monitor)
        )
    }

    func testWithFocusClickedWindowsWithoutScrollingAClickLeavesTheViewWhereItWas() async throws {
        let fixture = try makeFixture(pid: 938_501, windowCount: 5)
        fixture.controller.settings.focus.clickFocusWithoutScrolling = true
        let target = fixture.tokens[3]
        try scroll(fixture, so: target, isHalfOffTheRightEdge: ())
        let before = viewOrigin(fixture)
        let targetId = fixture.engine.findNode(for: target, in: fixture.workspaceId)?.id

        let press = try fixture.press(target)
        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: try fixture.entry(target), isWorkspaceActive: true, appFullscreen: false
        )
        try await drainRefreshes(fixture)

        XCTAssertNil(fixture.handler.state.deferredClickScroll)
        XCTAssertEqual(fixture.manager.niriViewportState(for: fixture.workspaceId).selectedNodeId, targetId)
        XCTAssertEqual(viewOrigin(fixture), before)

        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.dispatchMouseUp(at: press)
        try await drainRefreshes(fixture)

        XCTAssertEqual(viewOrigin(fixture), before)

        fixture.controller.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: [fixture.workspaceId]
        )
        try await drainRefreshes(fixture)

        XCTAssertEqual(viewOrigin(fixture), before)
        XCTAssertEqual(fixture.manager.niriViewportState(for: fixture.workspaceId).clickFocusedNodeId, targetId)
    }

    func testWithCenterFocusedColumnAlwaysAClickStillScrollsOnRelease() async throws {
        let fixture = try makeFixture(pid: 938_502, windowCount: 5)
        fixture.controller.settings.focus.clickFocusWithoutScrolling = true
        centreColumns(.always, in: fixture)
        let target = fixture.tokens[3]
        try scroll(fixture, so: target, isHalfOffTheRightEdge: ())
        let before = viewOrigin(fixture)

        let press = try fixture.press(target)
        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: try fixture.entry(target), isWorkspaceActive: true, appFullscreen: false
        )
        try await drainRefreshes(fixture)

        XCTAssertEqual(fixture.handler.state.deferredClickScroll, target)
        XCTAssertEqual(viewOrigin(fixture), before)

        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.dispatchMouseUp(at: press)
        try await drainRefreshes(fixture)

        XCTAssertNil(fixture.handler.state.deferredClickScroll)
        XCTAssertNotEqual(viewOrigin(fixture), before)
    }

    func testClickingAPeekFocusesItsColumnAndScrollsItIntoViewOnRelease() async throws {
        let fixture = try makeFixture(pid: 938_190, windowCount: 5)
        fixture.controller.settings.niri.edgePeekPercent = 3
        fixture.controller.updateNiriConfig(edgePeekShare: fixture.controller.edgePeekShare)
        let target = fixture.tokens[3]
        try scroll(fixture, so: target, isHalfOffTheRightEdge: ())
        let before = try fixture.settledFrame(target)

        let press = try fixture.press(target, reportsWindowUnderPointer: true)
        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: try fixture.entry(target), isWorkspaceActive: true, appFullscreen: false
        )
        try await drainRefreshes(fixture)

        XCTAssertEqual(try fixture.settledFrame(target).minX, before.minX, accuracy: 0.5)

        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.dispatchMouseUp(at: press)
        try await drainRefreshes(fixture)

        let after = try fixture.settledFrame(target)
        XCTAssertEqual(
            fixture.manager.niriViewportState(for: fixture.workspaceId).selectedNodeId,
            fixture.engine.findNode(for: target, in: fixture.workspaceId)?.id
        )
        XCTAssertLessThanOrEqual(after.maxX, workingFrame.maxX - (fixture.monitor.frame.width * 0.03).rounded() + 1)
    }

    func testALostMouseUpDoesNotKeepHoldingTheSelectionScroll() throws {
        let fixture = try makeFixture(pid: 938_016)
        fixture.handler.state.deferredClickScroll = fixture.tokens[1]
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        XCTAssertTrue(fixture.handler.holdsSelectionScroll(in: fixture.workspaceId))

        fixture.handler.pressedMouseButtonsProvider = { 0 }

        XCTAssertFalse(fixture.handler.holdsSelectionScroll(in: fixture.workspaceId))
    }

    func testAWindowFocusedWhileOmniWMsOwnScrollRunsIsScrolledIntoView() async throws {
        let fixture = try makeFixture(pid: 938_017, windowCount: 5)
        let target = fixture.tokens[3]
        try scroll(fixture, so: target, isHalfOffTheRightEdge: ())
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.springOffset(to: state.viewOffset - 40)
        }
        XCTAssertTrue(fixture.manager.animationDriver.hasMotion(in: fixture.workspaceId))
        XCTAssertFalse(fixture.manager.animationDriver.hasUserMotion(in: fixture.workspaceId))

        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: try fixture.entry(target), isWorkspaceActive: true, appFullscreen: false
        )
        fixture.manager.animationDriver.removeMotions(for: [fixture.workspaceId])
        try await drainRefreshes(fixture)

        let workingFrame = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        XCTAssertLessThanOrEqual(try fixture.settledFrame(target).maxX, workingFrame.maxX)
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
            let landing = [0, 2, 1, 3, 4].map { fixture.tokens[$0] }
            XCTAssertEqual(fixture.landingOrder(), landing, "\(centring)")
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
            XCTAssertEqual(fixture.landingOrder(), landing, "\(centring)")
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

    func testTheDropGoesStraightToItsFinalScrollSoTheDropScrollHasNothingLeft() throws {
        let fixture = try makeFixture(pid: 938_010, animated: true)
        centreColumns(.always, in: fixture)
        let (dragged, neighbour) = (fixture.tokens[1], fixture.tokens[2])
        try fixture.startLiveDrag(dragged)
        let drop = try fixture.farHalf(of: neighbour)
        fixture.drag(to: drop)
        fixture.handler.handleNiriAnimationsSettled(in: fixture.workspaceId)

        fixture.handler.dispatchMouseUp(at: drop)
        XCTAssertNotNil(fixture.handler.state.liveDropScroll)
        let offsetAtDrop = fixture.manager.niriViewportState(for: fixture.workspaceId).viewOffset

        fixture.handler.handleNiriAnimationsSettled(in: fixture.workspaceId)

        XCTAssertNil(fixture.handler.state.liveDropScroll)
        XCTAssertEqual(
            fixture.manager.niriViewportState(for: fixture.workspaceId).viewOffset,
            offsetAtDrop,
            accuracy: 0.5
        )
        let dropped = try fixture.settledFrame(dragged)
        let workingFrame = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        XCTAssertEqual(dropped.midX, workingFrame.midX, accuracy: 2)
    }

    func testAFocusChangeBeforeTheDropSettlesKeepsTheStripOffTheDroppedWindow() throws {
        let fixture = try makeFixture(pid: 938_300, animated: true)
        centreColumns(.always, in: fixture)
        let (dragged, neighbour) = (fixture.tokens[1], fixture.tokens[2])
        try fixture.startLiveDrag(dragged)
        let drop = try fixture.farHalf(of: neighbour)
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
        let drop = try fixture.farHalf(of: neighbour)
        fixture.drag(to: drop)
        fixture.handler.handleNiriAnimationsSettled(in: fixture.workspaceId)
        fixture.handler.dispatchMouseUp(at: drop)
        XCTAssertNotNil(fixture.handler.state.liveDropScroll)

        fixture.handler.receiveTapMouseDown(at: try fixture.centre(of: fixture.tokens[3]), modifiers: [])

        XCTAssertNil(fixture.handler.state.liveDropScroll)
    }

    func testHoldingAtTheRightEdgeHopsOnlyAfterTheDelay() throws {
        let fixture = try makeFixture(pid: 938_020, windowCount: 6)
        let clock = edgeClock(fixture)
        let dragged = fixture.tokens[1]
        try fixture.startLiveDrag(dragged)

        fixture.drag(to: edgePoint(.trailing, fixture))
        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.edge, .trailing)
        let entered = fixture.landingOrder()
        clock.now += 0.29
        fixture.handler.startLiveEdgeScrollIfDue()
        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.hopping, false)
        XCTAssertEqual(fixture.landingOrder(), entered)

        clock.now += 0.01
        fixture.handler.startLiveEdgeScrollIfDue()

        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.hopping, true)
        XCTAssertGreaterThan(
            try XCTUnwrap(fixture.landingOrder().firstIndex(of: dragged)),
            try XCTUnwrap(entered.firstIndex(of: dragged))
        )
        XCTAssertFalse(fixture.handler.isLiveEdgeScrolling)
        XCTAssertFalse(fixture.manager.animationDriver.hasEdgeScroll(in: fixture.workspaceId))
    }

    func testHoldingAtAnEdgeHopsTheDropSpacePastEachWindowUntilTheStripEnd() throws {
        for edge in [MouseInputState.LiveEdge.trailing, .leading] {
            let fixture = try makeFixture(pid: edge == .trailing ? 938_091 : 938_092, windowCount: 6)
            let dragged = fixture.tokens[edge == .trailing ? 1 : 4]
            try startEdgeScroll(edge, dragging: dragged, in: fixture)
            var indices = [try XCTUnwrap(fixture.landingOrder().firstIndex(of: dragged))]

            hopEdge(fixture) {
                if let index = fixture.landingOrder().firstIndex(of: dragged), index != indices.last {
                    indices.append(index)
                }
                return false
            }

            let expected = edge == .trailing ? Array(indices[0] ... 5) : Array((0 ... indices[0]).reversed())
            XCTAssertEqual(indices, expected, "\(edge)")
            XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.hopsDone, true, "\(edge)")
            let workingFrame = fixture.controller.insetWorkingFrame(for: fixture.monitor)
            let strip = try liveStrip(fixture)
            let gap = try XCTUnwrap(edge == .trailing ? strip.last : strip.first)
            XCTAssertTrue(gap.column.isLiveDropSpace, "\(edge)")
            XCTAssertGreaterThanOrEqual(gap.minX, workingFrame.minX - 1, "\(edge)")
            XCTAssertLessThanOrEqual(gap.maxX, workingFrame.maxX + 1, "\(edge)")
        }
    }

    func testInTheEdgeZoneThePointerAloneMovesNoGapBeforeTheHops() throws {
        let fixture = try makeFixture(pid: 938_094, windowCount: 6)
        let clock = edgeClock(fixture)
        let dragged = fixture.tokens[1]
        try fixture.startLiveDrag(dragged)
        let edge = edgePoint(.trailing, fixture)
        fixture.drag(to: CGPoint(x: edge.x - 2, y: edge.y))
        let entered = fixture.landingOrder()

        fixture.drag(to: CGPoint(x: edge.x - 30, y: edge.y))
        clock.now += 0.1
        fixture.drag(to: edge)

        XCTAssertEqual(fixture.landingOrder(), entered)
    }

    func testReleaseAfterEdgeHopsLandsInTheLastGap() throws {
        let fixture = try makeFixture(pid: 938_093, windowCount: 6)
        let dragged = fixture.tokens[1]
        try startEdgeScroll(.trailing, dragging: dragged, in: fixture)
        var hops = 0
        hopEdge(fixture) {
            hops += 1
            return hops == 2
        }
        let landing = try XCTUnwrap(fixture.landingOrder().firstIndex(of: dragged))

        fixture.handler.dispatchMouseUp(at: edgePoint(.trailing, fixture))

        XCTAssertEqual(fixture.order().firstIndex(of: dragged), landing)
    }

    func testTheHalfSecondStartsWhenTheGapSlidesUnderThePointer() throws {
        let fixture = try makeFixture(pid: 938_320, windowCount: 8, animated: true)
        let dragged = fixture.tokens[1]
        try startEdgeScroll(.trailing, dragging: dragged, in: fixture)
        fixture.manager.animationDriver.removeMotions(for: [fixture.workspaceId])
        _ = fixture.engine.cancelAnimations(in: fixture.workspaceId)
        fixture.handler.liveDragSession?.edgeScroll?.delayTimer?.invalidate()
        fixture.handler.liveDragSession?.edgeScroll?.delayTimer = nil
        fixture.handler.runLiveEdgeHop()
        XCTAssertTrue(fixture.handler.hasPendingLiveColumnAnimation(in: fixture.workspaceId, engine: fixture.engine))
        let nextHop = { fixture.handler.liveDragSession?.edgeScroll?.delayTimer }
        XCTAssertNil(nextHop())

        fixture.handler.handleLiveEdgeScrollTick(in: fixture.workspaceId, at: CACurrentMediaTime())
        XCTAssertNil(nextHop())

        fixture.handler.handleLiveEdgeScrollTick(in: fixture.workspaceId, at: CACurrentMediaTime() + 10)
        let hop = try XCTUnwrap(nextHop())
        XCTAssertEqual(hop.fireDate.timeIntervalSinceNow, 0.5, accuracy: 0.02)
        let landing = fixture.landingOrder()

        hop.fire()
        XCTAssertGreaterThan(
            try XCTUnwrap(fixture.landingOrder().firstIndex(of: dragged)),
            try XCTUnwrap(landing.firstIndex(of: dragged))
        )
        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.hopping, true)
    }

    func testTheHalfSecondStartsWhenTheSlideSettlesIfTheGapNeverReachedThePointer() throws {
        let fixture = try makeFixture(pid: 938_331, windowCount: 8, animated: true)
        try startEdgeScroll(.trailing, dragging: fixture.tokens[1], in: fixture)
        fixture.handler.liveDragSession?.edgeScroll?.delayTimer?.invalidate()
        fixture.handler.liveDragSession?.edgeScroll?.delayTimer = nil
        fixture.handler.runLiveEdgeHop()
        XCTAssertNil(fixture.handler.liveDragSession?.edgeScroll?.delayTimer)

        fixture.manager.animationDriver.removeMotions(for: [fixture.workspaceId])
        _ = fixture.engine.cancelAnimations(in: fixture.workspaceId)
        fixture.handler.handleNiriAnimationsSettled(in: fixture.workspaceId)

        let hop = try XCTUnwrap(fixture.handler.liveDragSession?.edgeScroll?.delayTimer)
        XCTAssertEqual(hop.fireDate.timeIntervalSinceNow, 0.5, accuracy: 0.02)
    }

    func testTheFirstHopStartsAfterTheEdgeDelayWhileTheDragIsStillSettling() throws {
        let fixture = try makeFixture(pid: 938_332, windowCount: 6, animated: true)
        let clock = edgeClock(fixture)
        let dragged = fixture.tokens[3]
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.jumpOffset(to: state.viewOffset + 1_000)
        }
        try fixture.confirmLayout()
        try fixture.startLiveDrag(dragged)
        let start = try fixture.centre(of: dragged)
        let end = edgePoint(.leading, fixture)
        let steps = max(1, Int(abs(end.x - start.x) / 40))
        for step in 1 ... steps {
            fixture.drag(to: CGPoint(x: start.x + (end.x - start.x) * CGFloat(step) / CGFloat(steps), y: end.y))
        }
        XCTAssertEqual(fixture.engine.liveColumnMove?.phase, .settling)
        let landing = fixture.landingOrder()

        clock.now += MoveConfiguration.liveEdgeScrollDelay
        fixture.handler.startLiveEdgeScrollIfDue()

        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.hopping, true)
        XCTAssertNotEqual(fixture.landingOrder(), landing)
    }

    func testWithoutAnimationsTheHopsComeHalfASecondApart() throws {
        let fixture = try makeFixture(pid: 938_330, windowCount: 6)
        try startEdgeScroll(.trailing, dragging: fixture.tokens[1], in: fixture)
        XCTAssertFalse(fixture.handler.hasPendingLiveColumnAnimation(in: fixture.workspaceId, engine: fixture.engine))

        let pause = try XCTUnwrap(fixture.handler.liveDragSession?.edgeScroll?.delayTimer)

        XCTAssertEqual(pause.fireDate.timeIntervalSinceNow, 0.5, accuracy: 0.02)
    }

    func testNoHintOpensWhileThePointerIsInTheEdgeZone() throws {
        let fixture = try makeFixture(pid: 938_321, windowCount: 5, displayWidth: 4_000)
        let clock = edgeClock(fixture)
        let target = fixture.tokens[1]
        try scroll(fixture, so: target, showsAtTheLeftEdge: 300)
        try fixture.startLiveDrag(fixture.tokens[2])
        let (outside, inZone) = try centreThirdPoints(of: target, aroundTheLeadingEdgeZoneIn: fixture)

        fixture.drag(to: inZone)
        clock.now += 0.25
        fixture.drag(to: inZone)
        fixture.handler.liveDragSession?.hoverTimer?.fire()

        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.edge, .leading)
        XCTAssertNil(fixture.engine.liveColumnMove?.landing)

        fixture.drag(to: outside)
        clock.now += 0.25
        fixture.drag(to: outside)
        fixture.handler.liveDragSession?.hoverTimer?.fire()

        XCTAssertNil(fixture.handler.liveDragSession?.edgeScroll)
        XCTAssertNotNil(fixture.engine.liveColumnMove?.landing)
    }

    func testTheFirstHopClosesAHintOpenWhenThePointerEnteredTheEdgeZone() throws {
        let fixture = try makeFixture(pid: 938_322, windowCount: 5, displayWidth: 4_000)
        let clock = edgeClock(fixture)
        let (dragged, target) = (fixture.tokens[2], fixture.tokens[1])
        try scroll(fixture, so: target, showsAtTheLeftEdge: 300)
        try fixture.startLiveDrag(dragged)
        let (outside, inZone) = try centreThirdPoints(of: target, aroundTheLeadingEdgeZoneIn: fixture)
        fixture.drag(to: outside)
        clock.now += 0.25
        fixture.drag(to: outside)
        fixture.handler.liveDragSession?.hoverTimer?.fire()
        XCTAssertNotNil(fixture.engine.liveColumnMove?.landing)
        XCTAssertEqual(
            fixture.engine.liveColumnMove?.landing?.columnId,
            try column(holding: target, in: fixture).id
        )

        fixture.drag(to: inZone)
        XCTAssertNotNil(fixture.engine.liveColumnMove?.landing)
        clock.now += MoveConfiguration.liveEdgeScrollDelay
        fixture.handler.startLiveEdgeScrollIfDue()

        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.hopping, true)
        XCTAssertNil(fixture.engine.liveColumnMove?.landing)
        XCTAssertNil(fixture.engine.liveColumnMove?.landing)
        let landing = fixture.landingOrder()
        XCTAssertLessThan(
            try XCTUnwrap(landing.firstIndex(of: dragged)),
            try XCTUnwrap(landing.firstIndex(of: target))
        )
    }

    func testReleasingOverAnOpenHintStacksOntoTheWindow() throws {
        let fixture = try makeFixture(pid: 938_323)
        let clock = DragClock()
        fixture.handler.liveDragClock = { clock.now }
        let (dragged, target) = (fixture.tokens[1], fixture.tokens[2])
        try fixture.startLiveDrag(dragged)
        let targetFrame = try fixture.frame(target)
        let pointer = CGPoint(x: targetFrame.midX, y: targetFrame.minY + targetFrame.height / 4)

        fixture.drag(to: pointer)
        clock.now += 0.2
        fixture.handler.liveDragSession?.hoverTimer?.fire()
        XCTAssertNotNil(fixture.engine.liveColumnMove?.landing)
        fixture.handler.dispatchMouseUp(at: pointer)

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertFalse(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))
        XCTAssertEqual(try column(holding: target, in: fixture).windowNodes.map(\.token), [dragged, target])
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 3)
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.windowNodes.isEmpty })
        XCTAssertLessThan(try fixture.settledFrame(dragged).maxY, try fixture.settledFrame(target).minY)
    }

    func testAWindowMovingWithinItsStackScrollsTheStripSteadilyAtTheEdgeUntilItLeavesTheStack() throws {
        let fixture = try makeFixture(pid: 938_324, windowCount: 6, stackFirstTwo: true)
        let dragged = try startEdgeScrollWithinTheStack(in: fixture)
        let stack = try column(holding: dragged, in: fixture)
        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.hopping, false)
        let motion = try XCTUnwrap(fixture.manager.animationDriver.edgeScroll(in: fixture.workspaceId))
        XCTAssertLessThan(motion.to, motion.from)
        XCTAssertEqual(motion.speed, Double(MoveConfiguration.liveEdgeScrollSpeed))
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.workspaceId))
        var initialViewport = fixture.manager.niriViewportState(for: fixture.workspaceId)
        initialViewport.viewOffset = motion.from
        let initialStrip = fixture.engine.liveColumnStrip(context: context, state: initialViewport)
        let slot = try XCTUnwrap(initialStrip.first { $0.column === stack })
        let pointer = try XCTUnwrap(fixture.handler.livePointer.location)
        let leaveInset = slot.width * max(0, 0.5 - MoveConfiguration.liveStackLeaveOutsideShare)
        let distanceUntilDeparture = pointer.x - (slot.minX + leaveInset)
        let sampleMotionFraction: CGFloat = 0.5
        let sampleFramesPerSecond = CGFloat(Fixture.animationSampleRate)
        let sampleDuration = distanceUntilDeparture * sampleMotionFraction / MoveConfiguration.liveEdgeScrollSpeed
        let sampleTick = Int(floor(sampleDuration * sampleFramesPerSecond))
        XCTAssertGreaterThan(sampleTick, 0)
        var ticks = 0
        var observedIntermediateStack = false
        tickEdgeScroll(fixture) {
            ticks += 1
            if ticks == sampleTick {
                XCTAssertTrue(fixture.handler.isLiveEdgeScrolling)
                XCTAssertEqual(fixture.engine.liveColumnMove?.home, .stackSlot)
                XCTAssertEqual(stack.windowNodes.count, 2)
                observedIntermediateStack = true
            }
            return false
        }
        XCTAssertTrue(observedIntermediateStack)
        XCTAssertFalse(fixture.handler.isLiveEdgeScrolling)
        XCTAssertEqual(fixture.engine.liveColumnMove.map { $0.home != .stackSlot }, true)
        XCTAssertEqual(stack.windowNodes.count, 1)
    }

    func testAnEdgeScrollWithinAStackBuildsTheStripOnceAndShiftsItToMatchAFreshOne() throws {
        let fixture = try makeFixture(pid: 938_040, windowCount: 6, stackFirstTwo: true)
        try startEdgeScrollWithinTheStack(in: fixture)
        let motion = try XCTUnwrap(fixture.manager.animationDriver.edgeScroll(in: fixture.workspaceId))
        let location = CGPoint(x: -10_000, y: 0)
        XCTAssertNil(fixture.handler.liveDragSession?.edgeScroll?.strip)

        _ = fixture.handler.liveEdgeScrollReachesColumn(
            at: location, time: motion.startTime, engine: fixture.engine, workspaceId: fixture.workspaceId
        )
        let cached = try XCTUnwrap(fixture.handler.liveDragSession?.edgeScroll?.strip)
        let later = motion.startTime + 0.1
        _ = fixture.handler.liveEdgeScrollReachesColumn(
            at: location, time: later, engine: fixture.engine, workspaceId: fixture.workspaceId
        )

        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.strip?.viewOffset, cached.viewOffset)
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

    func testTheEdgeZoneIsThreePercentOfTheDisplayAndAtLeastFortyPoints() throws {
        XCTAssertEqual(MoveConfiguration.liveEdgeZoneWidth(forDisplayWidth: 1_728), 51.84, accuracy: 0.01)
        XCTAssertEqual(MoveConfiguration.liveEdgeZoneWidth(forDisplayWidth: 2_560), 76.8, accuracy: 0.01)
        XCTAssertEqual(MoveConfiguration.liveEdgeZoneWidth(forDisplayWidth: 1_024), 40, accuracy: 0.01)

        let fixture = try makeFixture(pid: 938_033, windowCount: 6)
        let zone = MoveConfiguration.liveEdgeZoneWidth(forDisplayWidth: fixture.monitor.frame.width)
        try fixture.startLiveDrag(fixture.tokens[1])
        fixture.drag(to: CGPoint(x: fixture.monitor.frame.maxX - zone - 2, y: fixture.monitor.frame.midY))
        XCTAssertNil(fixture.handler.liveDragSession?.edgeScroll)
        fixture.drag(to: CGPoint(x: fixture.monitor.frame.maxX - zone + 2, y: fixture.monitor.frame.midY))
        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.edge, .trailing)
    }

    func testLeavingTheZoneBeforeTheDelayStartsNoScroll() throws {
        let fixture = try makeFixture(pid: 938_025, windowCount: 6)
        let clock = edgeClock(fixture)
        try fixture.startLiveDrag(fixture.tokens[1])
        fixture.drag(to: edgePoint(.trailing, fixture))
        fixture.drag(to: CGPoint(x: fixture.monitor.frame.maxX - 60, y: fixture.monitor.frame.midY))

        clock.now += 1
        fixture.handler.startLiveEdgeScrollIfDue()

        XCTAssertNil(fixture.handler.liveDragSession?.edgeScroll)
        XCTAssertFalse(fixture.manager.animationDriver.hasEdgeScroll(in: fixture.workspaceId))
    }

    func testMovingWithinTheZoneKeepsTheDelayAndSwitchingEdgesRestartsIt() throws {
        let fixture = try makeFixture(pid: 938_026, windowCount: 6)
        let clock = edgeClock(fixture)
        try fixture.startLiveDrag(fixture.tokens[1])
        fixture.drag(to: edgePoint(.trailing, fixture))
        let entered = try XCTUnwrap(fixture.handler.liveDragSession?.edgeScroll?.enteredAt)

        clock.now += 0.2
        fixture.drag(to: CGPoint(x: fixture.monitor.frame.maxX - 25, y: fixture.monitor.frame.midY + 40))
        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.enteredAt, entered)

        clock.now += 0.05
        fixture.drag(to: edgePoint(.leading, fixture))
        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.edge, .leading)
        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.enteredAt, clock.now)
    }

    func testADragStartingInsideTheEdgeZoneWaitsUntilPushedTowardTheEdge() throws {
        let fixture = try makeFixture(pid: 938_034, windowCount: 6)
        let clock = edgeClock(fixture)
        let start = try startLiveDragInsideTheEdgeZone(.leading, dragging: fixture.tokens[1], in: fixture)
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertNil(fixture.handler.liveDragSession?.edgeScroll)

        clock.now += 0.4
        fixture.drag(to: CGPoint(x: start.x + 6, y: start.y))
        fixture.handler.startLiveEdgeScrollIfDue()
        XCTAssertNil(fixture.handler.liveDragSession?.edgeScroll)
        XCTAssertFalse(fixture.handler.isLiveEdgeScrolling)

        clock.now += 0.1
        fixture.drag(to: CGPoint(x: start.x - 4, y: start.y))
        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.edge, .leading)
        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.enteredAt, clock.now)
    }

    func testADragStartingInsideTheEdgeZoneArmsItAfterLeavingAndComingBack() throws {
        let fixture = try makeFixture(pid: 938_035, windowCount: 6)
        let clock = edgeClock(fixture)
        let start = try startLiveDragInsideTheEdgeZone(.trailing, dragging: fixture.tokens[1], in: fixture)
        XCTAssertNil(fixture.handler.liveDragSession?.edgeScroll)

        clock.now += 0.1
        fixture.drag(to: CGPoint(x: fixture.monitor.frame.midX, y: start.y))
        XCTAssertNil(fixture.handler.liveDragSession?.edgeZoneHold)

        clock.now += 0.1
        fixture.drag(to: CGPoint(x: start.x - 4, y: start.y))
        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.edge, .trailing)
        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.enteredAt, clock.now)
    }

    func testCancellingDuringEdgeHopsRestoresTheLayout() throws {
        for cancel in ["interaction", "pointer crosses to another display"] {
            let fixture = try makeFixture(pid: cancel == "interaction" ? 938_029 : 938_030, windowCount: 6)
            let order = fixture.order()
            let offset = fixture.manager.niriViewportState(for: fixture.workspaceId).viewOffset
            try startEdgeScroll(.trailing, dragging: fixture.tokens[1], in: fixture)
            var hops = 0
            hopEdge(fixture) {
                hops += 1
                return hops == 2
            }
            XCTAssertNotEqual(fixture.landingOrder(), order, cancel)
            XCTAssertNotEqual(
                fixture.manager.niriViewportState(for: fixture.workspaceId).viewOffset,
                offset,
                accuracy: 1,
                cancel
            )

            if cancel == "interaction" {
                fixture.handler.cancelActiveMouseInteraction()
            } else {
                fixture.drag(to: CGPoint(x: fixture.monitor.frame.maxX + 5, y: fixture.monitor.frame.midY))
            }

            XCTAssertEqual(fixture.order(), order, cancel)
            XCTAssertEqual(
                fixture.manager.niriViewportState(for: fixture.workspaceId).viewOffset,
                offset,
                accuracy: 0.001,
                cancel
            )
            XCTAssertNil(fixture.handler.liveDragSession?.edgeScroll, cancel)
            XCTAssertFalse(fixture.manager.animationDriver.hasEdgeScroll(in: fixture.workspaceId), cancel)
        }
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

    func testTheEdgeHopsStopWhenTheEngineDropsTheMove() throws {
        let fixture = try makeFixture(pid: 938_303, windowCount: 6)
        let dragged = fixture.tokens[1]
        try startEdgeScroll(.trailing, dragging: dragged, in: fixture)
        let nextHopCheck = try XCTUnwrap(fixture.handler.liveDragSession?.edgeScroll?.delayTimer)
        XCTAssertTrue(nextHopCheck.isValid)
        let window = try XCTUnwrap(fixture.engine.findNode(for: dragged, in: fixture.workspaceId))
        fixture.manager.withEngineMutationScope(in: fixture.workspaceId) {
            fixture.engine.cancelInteractions(for: [window.id], in: fixture.workspaceId)
        }
        XCTAssertNil(fixture.engine.liveColumnMove)

        fixture.drag(to: edgePoint(.trailing, fixture))

        XCTAssertNil(fixture.handler.liveDragSession?.edgeScroll)
        XCTAssertFalse(nextHopCheck.isValid)
        XCTAssertFalse(fixture.manager.animationDriver.hasEdgeScroll(in: fixture.workspaceId))
    }

    func testTheEdgeZoneAtAnEdgeSharedWithAnotherDisplayWorksLikeAnOuterOne() throws {
        let fixture = try makeFixture(pid: 938_305, windowCount: 6)
        let right = try addDisplay(rightOf: fixture)
        let clock = edgeClock(fixture)
        try fixture.startLiveDrag(fixture.tokens[1])

        fixture.drag(to: edgePoint(.trailing, fixture))
        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.edge, .trailing)
        let entered = fixture.landingOrder()
        clock.now += MoveConfiguration.liveEdgeScrollDelay
        fixture.handler.startLiveEdgeScrollIfDue()

        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.hopping, true)
        XCTAssertGreaterThan(
            try XCTUnwrap(fixture.landingOrder().firstIndex(of: fixture.tokens[1])),
            try XCTUnwrap(entered.firstIndex(of: fixture.tokens[1]))
        )
        XCTAssertNotEqual(fixture.manager.monitor(for: fixture.workspaceId)?.id, right.id)
    }

    func testAQuickCrossingToAnotherDisplayStartsNoEdgeHops() throws {
        let fixture = try makeFixture(pid: 938_307, windowCount: 6)
        let right = try addDisplay(rightOf: fixture)
        let clock = edgeClock(fixture)
        try fixture.startLiveDrag(fixture.tokens[1])

        fixture.drag(to: edgePoint(.trailing, fixture))
        clock.now += 0.1
        fixture.drag(to: CGPoint(x: right.frame.midX, y: right.frame.midY))
        clock.now += MoveConfiguration.liveEdgeScrollDelay
        fixture.handler.startLiveEdgeScrollIfDue()

        XCTAssertNil(fixture.handler.liveDragSession?.edgeScroll)
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

    func testOnOneDisplayALiveDragPublishesNoHold() throws {
        let fixture = try makeFixture(pid: 938_194, windowCount: 6)
        let barrier = fixture.controller.pointerEdgeBarrier
        try fixture.startLiveDrag(fixture.tokens[1])
        fixture.drag(to: try fixture.centre(of: fixture.tokens[1]))
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertNil(barrier.liveDragHold)

        try startEdgeScroll(.trailing, dragging: fixture.tokens[1], in: fixture, started: true)
        XCTAssertNil(barrier.liveDragHold)
        fixture.handler.dispatchMouseUp(at: edgePoint(.trailing, fixture))
    }

    func testALiveDragHoldsOnlyTheSidesTheStripCanScrollUntilItEnds() throws {
        let fixture = try makeFixture(pid: 938_193, windowCount: 6)
        _ = try addDisplay(rightOf: fixture)
        let barrier = fixture.controller.pointerEdgeBarrier
        XCTAssertNil(barrier.liveDragHold)
        try fixture.startLiveDrag(fixture.tokens[1])
        fixture.drag(to: try fixture.centre(of: fixture.tokens[1]))
        XCTAssertEqual(barrier.liveDragHold?.monitorId, fixture.monitor.id)
        XCTAssertEqual(barrier.liveDragHold?.heldDirections.contains(.right), true)

        try startEdgeScroll(.trailing, dragging: fixture.tokens[1], in: fixture, started: true)
        XCTAssertEqual(barrier.liveDragHold?.heldDirections.contains(.right), true)
        hopEdge(fixture)
        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.hopsDone, true)
        fixture.drag(to: edgePoint(.trailing, fixture))
        XCTAssertEqual(barrier.liveDragHold?.heldDirections.contains(.right), false)
        XCTAssertEqual(barrier.liveDragHold?.heldDirections.contains(.left), true)

        fixture.handler.dispatchMouseUp(at: edgePoint(.trailing, fixture))
        XCTAssertNil(barrier.liveDragHold)
    }

    func testAWindowTallerThanItsLayoutFrameStillStartsALiveDrag() throws {
        let fixture = try makeFixture(pid: 938_135)
        let token = fixture.tokens[1]
        let laidOut = try fixture.frame(token)
        let real = CGRect(x: laidOut.minX, y: laidOut.minY - 24, width: laidOut.width, height: laidOut.height + 24)
        fixture.handler.retireNativeTitleBarDragAtInputBoundary()
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        fixture.reported.frame = real
        fixture.handler.nativeWindowFrameProvider = { [reported = fixture.reported] _ in reported.frame }
        XCTAssertFalse(fixture.handler.dispatchMouseDown(
            at: CGPoint(x: real.midX, y: real.maxY - 10),
            modifiers: [],
            windowIdUnderPointer: token.windowId
        ))
        fixture.handler.dispatchMouseDragged(at: CGPoint(x: real.midX + 5, y: real.maxY - 10))

        try fixture.macOSMoves(token, to: real.offsetBy(dx: 30, dy: 0))

        XCTAssertNotNil(fixture.engine.liveColumnMove)
    }

    func testAnUndoThatScrollsStartsEveryWindowWhereItIsDrawn() throws {
        let fixture = try makeFixture(pid: 938_136, windowCount: 8, animated: true)
        try stackDrop(fixture.tokens[1], onto: fixture.tokens[2], in: fixture)
        let width = fixture.controller.insetWorkingFrame(for: fixture.monitor).width
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.jumpOffset(to: state.viewOffset + width * 1.5)
        }
        let now = CACurrentMediaTime()
        let drawn = try framesWhereDrawn(fixture, at: now)

        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo, in: fixture.workspaceId))

        XCTAssertTrue(fixture.manager.animationDriver.hasMotion(in: fixture.workspaceId))
        let started = try framesWhereDrawn(fixture, at: now)
        let screen = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        var checked = 0
        for token in fixture.tokens where token != fixture.tokens[1] {
            let before = try XCTUnwrap(drawn[token])
            guard before.intersects(screen) else { continue }
            let after = try XCTUnwrap(started[token])
            XCTAssertEqual(after.minX, before.minX, accuracy: 5, "window \(token.windowId) jumped")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    private func framesWhereDrawn(_ fixture: Fixture, at time: TimeInterval) throws -> [WindowToken: CGRect] {
        var probe = fixture.manager.niriViewportState(for: fixture.workspaceId)
        probe.viewOffset = fixture.manager.animationDriver.liveViewOffset(
            in: fixture.workspaceId,
            semanticOffset: probe.viewOffset,
            at: time
        ) ?? probe.viewOffset
        let gap = fixture.controller.innerGap(for: fixture.monitor)
        return try XCTUnwrap(fixture.controller.niriEngine).calculateLayoutWithVisibility(
            state: probe,
            workspaceId: fixture.workspaceId,
            monitorFrame: fixture.controller.insetWorkingFrame(for: fixture.monitor),
            gaps: (horizontal: gap, vertical: gap),
            orientation: fixture.controller.settings.monitors.effectiveOrientation(for: fixture.monitor),
            animationTime: time
        ).frames
    }

    func testAStackDropThatOverflowsIsUndoneWithTheMessageOverTheWindowThatWentBack() throws {
        let fixture = try makeFixture(pid: 938_125)
        let watch = watchOverflows(fixture)
        let columnsBefore = fixture.engine.columns(in: fixture.workspaceId).count
        try stackDrop(fixture.tokens[1], onto: fixture.tokens[2], in: fixture)
        let stack = try column(holding: fixture.tokens[2], in: fixture)
        XCTAssertEqual(stack.windowNodes.count, 2)

        try appTakes(40, more: fixture.tokens[1], in: fixture, watch)
        checkOverflows(fixture)

        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, columnsBefore)
        XCTAssertEqual(try column(holding: fixture.tokens[2], in: fixture).windowNodes.count, 1)
        XCTAssertEqual(
            fixture.controller.columnModeToast.message,
            .overflowUndone(columnId: stack.id, window: fixture.tokens[1])
        )
        XCTAssertEqual(fixture.controller.columnModeToast.source?.workspaceId, fixture.workspaceId)
        XCTAssertNil(fixture.engine.peekLayoutHistory(.redo, in: fixture.workspaceId))
        XCTAssertFalse(fixture.controller.niriLayoutHandler.stepLayoutHistory(.redo, in: fixture.workspaceId))
    }

    func testWithAnimationsTheMessageShowsOnceTheUndoneWindowsSettle() throws {
        let fixture = try makeFixture(pid: 938_152, animated: true)
        let watch = watchOverflows(fixture)
        try stackDrop(fixture.tokens[1], onto: fixture.tokens[2], in: fixture, settling: false)
        settle(fixture)
        try appTakes(40, more: fixture.tokens[1], in: fixture, watch)
        checkOverflows(fixture)
        XCTAssertEqual(try column(holding: fixture.tokens[2], in: fixture).windowNodes.count, 1)
        XCTAssertTrue(hasPendingNiriAnimationWork(
            state: fixture.manager.niriViewportState(for: fixture.workspaceId),
            driver: fixture.manager.animationDriver,
            engine: fixture.engine,
            workspaceId: fixture.workspaceId
        ))
        XCTAssertTrue(layOut(fixture))
        fixture.controller.niriLayoutHandler.followOverflowMessage(in: fixture.workspaceId)
        XCTAssertNil(fixture.controller.columnModeToast.message)

        settle(fixture)
        XCTAssertTrue(layOut(fixture))
        fixture.controller.niriLayoutHandler.followOverflowMessage(in: fixture.workspaceId)

        XCTAssertNotNil(fixture.controller.columnModeToast.message)
    }

    func testAKeyboardMoveIntoAStackThatOverflowsIsUndone() throws {
        let fixture = try makeFixture(pid: 938_133)
        let watch = watchOverflows(fixture)
        try recordStep(in: fixture) {
            XCTAssertTrue(move(fixture.tokens[1], after: fixture.tokens[2], in: fixture))
        }
        XCTAssertEqual(try column(holding: fixture.tokens[2], in: fixture).windowNodes.count, 2)

        try appTakes(40, more: fixture.tokens[1], in: fixture, watch)
        checkOverflows(fixture)

        XCTAssertEqual(try column(holding: fixture.tokens[1], in: fixture).windowNodes.count, 1)
        XCTAssertEqual(try column(holding: fixture.tokens[2], in: fixture).windowNodes.count, 1)
    }

    func testASizeRefusalInAWorkspaceSwitchedToDwindleReportsNoOverflow() throws {
        for switchesToDwindle in [false, true] {
            let fixture = try makeFixture(pid: switchesToDwindle ? 938_146 : 938_145)
            _ = watchOverflows(fixture)
            try recordStep(in: fixture) {
                XCTAssertTrue(move(fixture.tokens[1], after: fixture.tokens[2], in: fixture))
            }
            let token = fixture.tokens[1]
            let asked = try XCTUnwrap(fixture.engine.findNode(for: token, in: fixture.workspaceId)?.frame)
            var taken = asked
            taken.size.height += 2 * AXRecentFrameWriteFailure.maxAcceptedSizeSnap
            if switchesToDwindle {
                XCTAssertTrue(fixture.controller.commandHandler.setWorkspaceLayout(.dwindle, forWorkspaceNamed: "1"))
                XCTAssertEqual(try column(holding: token, in: fixture).windowNodes.count, 2)
            }

            fixture.controller.axManager.onTerminalFrameRefusal?(AXFrameTerminalRefusal(
                pid: token.pid,
                windowId: token.windowId,
                targetFrame: asked,
                observedFrame: taken,
                failureReason: .verificationMismatch
            ))

            let handler = fixture.controller.niriLayoutHandler
            XCTAssertEqual(handler.overflowReports.isEmpty, switchesToDwindle, "to Dwindle \(switchesToDwindle)")
            XCTAssertEqual(handler.isOverflowCheckScheduled, !switchesToDwindle, "to Dwindle \(switchesToDwindle)")
        }
    }

    func testATabbedColumnTurnedIntoAStackThatOverflowsIsUndone() throws {
        let fixture = try makeFixture(pid: 938_150, tabbedRuns: [1 ... 2])
        let watch = watchOverflows(fixture)
        let tabbed = try column(holding: fixture.tokens[1], in: fixture)
        XCTAssertTrue(layOut(fixture))
        try recordStep(in: fixture) {
            fixture.manager.withEngineMutationScope(in: fixture.workspaceId) {
                tabbed.displayMode = .normal
                fixture.engine.updateTabbedColumnVisibility(column: tabbed)
            }
        }

        try appTakes(40, more: fixture.tokens[2], in: fixture, watch)
        checkOverflows(fixture)

        XCTAssertTrue(tabbed.isTabbed)
        XCTAssertNotNil(fixture.controller.columnModeToast.message)
    }

    func testAHeightResizeThatSqueezesAWindowBelowItsAppIsUndone() throws {
        let fixture = try makeFixture(pid: 938_151, stackFirstTwo: true)
        let watch = watchOverflows(fixture)
        let top = try XCTUnwrap(fixture.engine.findNode(for: fixture.tokens[0], in: fixture.workspaceId))
        let heightBefore = top.height
        try recordStep(in: fixture) {
            top.height = .auto(weight: 3)
        }

        try appTakes(40, more: fixture.tokens[1], in: fixture, watch)
        checkOverflows(fixture)

        XCTAssertEqual(top.height, heightBefore)
        let stack = try column(holding: fixture.tokens[0], in: fixture)
        XCTAssertEqual(fixture.controller.columnModeToast.message, .overflowUndone(columnId: stack.id, window: nil))
    }

    func testAWidthChangeOnAnOverflowingStackIsKept() throws {
        let fixture = try makeFixture(pid: 938_137, stackFirstTwo: true)
        let watch = watchOverflows(fixture)
        let stack = try column(holding: fixture.tokens[0], in: fixture)
        try recordStep(in: fixture) {
            stack.width = .proportion(0.5)
            stack.cachedWidth = 0
        }

        try appTakes(40, more: fixture.tokens[1], in: fixture, watch)
        checkOverflows(fixture)

        XCTAssertEqual(stack.width, .proportion(0.5))
        XCTAssertNil(fixture.controller.columnModeToast.message)
    }

    func testAnAppThatSnapsBy16PointsOrLessIsKept() throws {
        let fixture = try makeFixture(pid: 938_138)
        let watch = watchOverflows(fixture)
        try stackDrop(fixture.tokens[1], onto: fixture.tokens[2], in: fixture)

        try appTakes(16, more: fixture.tokens[1], in: fixture, watch)

        XCTAssertTrue(fixture.controller.niriLayoutHandler.overflowReports.isEmpty)
        checkOverflows(fixture)
        XCTAssertEqual(try column(holding: fixture.tokens[2], in: fixture).windowNodes.count, 2)
    }

    func testTakingAWindowOutOfAnOverflowingStackIsKept() throws {
        let fixture = try makeFixture(pid: 938_134, windowCount: 5, stackFirstTwo: true)
        let watch = watchOverflows(fixture)
        XCTAssertTrue(move(fixture.tokens[2], after: fixture.tokens[1], in: fixture))
        let stack = try column(holding: fixture.tokens[0], in: fixture)
        XCTAssertEqual(stack.windowNodes.count, 3)
        try recordStep(in: fixture) {
            XCTAssertTrue(move(fixture.tokens[1], after: fixture.tokens[3], in: fixture))
        }
        XCTAssertEqual(stack.windowNodes.count, 2)

        try appTakes(40, more: fixture.tokens[0], in: fixture, watch)
        checkOverflows(fixture)

        XCTAssertEqual(try column(holding: fixture.tokens[3], in: fixture).windowNodes.count, 2)
        XCTAssertNil(fixture.controller.columnModeToast.message)
    }

    func testAfterUndoALateReportUndoesNothingAndAfterRedoTheOverflowStays() throws {
        let fixture = try makeFixture(pid: 938_139, stackFirstTwo: true)
        let watch = watchOverflows(fixture)
        let top = try XCTUnwrap(fixture.engine.findNode(for: fixture.tokens[0], in: fixture.workspaceId))
        try recordStep(in: fixture) { top.height = .auto(weight: 2) }
        try recordStep(in: fixture) { top.height = .auto(weight: 3) }
        let handler = fixture.controller.niriLayoutHandler

        XCTAssertTrue(handler.stepLayoutHistory(.undo, in: fixture.workspaceId))
        try appTakes(40, more: fixture.tokens[1], in: fixture, watch)
        checkOverflows(fixture)
        XCTAssertEqual(top.height, .auto(weight: 2))

        XCTAssertTrue(handler.stepLayoutHistory(.redo, in: fixture.workspaceId))
        try appTakes(40, more: fixture.tokens[1], in: fixture, watch)
        checkOverflows(fixture)
        XCTAssertEqual(top.height, .auto(weight: 3))
        XCTAssertNil(fixture.controller.columnModeToast.message)
    }

    func testACommandThatChangesNothingDoesNotStopTheDropsUndo() throws {
        let fixture = try makeFixture(pid: 938_140)
        let watch = watchOverflows(fixture)
        try stackDrop(fixture.tokens[1], onto: fixture.tokens[2], in: fixture)
        try recordStep(in: fixture) {}

        try appTakes(40, more: fixture.tokens[1], in: fixture, watch)
        checkOverflows(fixture)

        XCTAssertEqual(try column(holding: fixture.tokens[2], in: fixture).windowNodes.count, 1)
    }

    func testAReportHeldBackByAQueuedRefreshIsCheckedAgainWhenTheRefreshEnds() throws {
        let fixture = try makeFixture(pid: 938_150)
        let handler = fixture.controller.niriLayoutHandler
        let refreshes = fixture.controller.layoutRefreshController
        handler.overflowReports[fixture.tokens[1]] = 0
        XCTAssertFalse(handler.isOverflowCheckScheduled)

        refreshes.finishRefresh(
            .init(kind: .immediateRelayout, reason: .workspaceTransition),
            didComplete: true,
            generation: refreshes.layoutState.refreshGeneration
        )

        XCTAssertTrue(handler.isOverflowCheckScheduled)
        handler.overflowReports.removeAll()
    }

    func testAReportHeldWhileTheStackDropSettlesIsDecidedWhenTheDropIsRecorded() throws {
        let fixture = try makeFixture(pid: 938_130, animated: true)
        let watch = watchOverflows(fixture)
        try stackDrop(fixture.tokens[1], onto: fixture.tokens[2], in: fixture, settling: false)
        XCTAssertTrue(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))

        try appTakes(40, more: fixture.tokens[1], in: fixture, watch)
        fixture.controller.niriLayoutHandler.overflowReports[fixture.tokens[1]] = watch.clock.now
        checkOverflows(fixture)
        XCTAssertFalse(fixture.controller.niriLayoutHandler.overflowReports.isEmpty)
        XCTAssertNil(fixture.controller.columnModeToast.message)

        settle(fixture)
        checkOverflows(fixture)
        settle(fixture)
        fixture.controller.niriLayoutHandler.followOverflowMessage(in: fixture.workspaceId)

        XCTAssertEqual(try column(holding: fixture.tokens[2], in: fixture).windowNodes.count, 1)
        XCTAssertNotNil(fixture.controller.columnModeToast.message)
    }

    func testAReportDuringADragThatIsCancelledUndoesNothingLater() throws {
        let fixture = try makeFixture(pid: 938_141, stackFirstTwo: true)
        let watch = watchOverflows(fixture)
        try fixture.startLiveDrag(fixture.tokens[3])
        try appTakes(40, more: fixture.tokens[1], in: fixture, watch)
        checkOverflows(fixture)
        XCTAssertFalse(fixture.controller.niriLayoutHandler.overflowReports.isEmpty)

        fixture.handler.cancelLiveColumnDrag()
        checkOverflows(fixture)
        XCTAssertTrue(fixture.controller.niriLayoutHandler.overflowReports.isEmpty)

        watch.clock.now += 1
        try stackDrop(fixture.tokens[3], onto: fixture.tokens[2], in: fixture)
        checkOverflows(fixture)
        XCTAssertEqual(try column(holding: fixture.tokens[0], in: fixture).windowNodes.count, 2)
        XCTAssertEqual(try column(holding: fixture.tokens[2], in: fixture).windowNodes.count, 2)
        XCTAssertNil(fixture.controller.columnModeToast.message)
    }

    func testADragStartedWhileADropSettlesIsNotDisturbed() throws {
        let fixture = try makeFixture(pid: 938_142, animated: true)
        let watch = watchOverflows(fixture)
        try stackDrop(fixture.tokens[1], onto: fixture.tokens[2], in: fixture, settling: false)
        try appTakes(40, more: fixture.tokens[1], in: fixture, watch)
        fixture.controller.niriLayoutHandler.overflowReports[fixture.tokens[1]] = watch.clock.now

        try fixture.startLiveDrag(fixture.tokens[0])

        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertEqual(try column(holding: fixture.tokens[2], in: fixture).windowNodes.count, 2)
        XCTAssertNil(fixture.controller.columnModeToast.message)
        checkOverflows(fixture)
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertFalse(fixture.controller.niriLayoutHandler.overflowReports.isEmpty)
    }

    func testOmniWMsOwnResizeAfterADropDoesNotUndoTheDrop() throws {
        let fixture = try makeFixture(pid: 938_132)
        let watch = watchOverflows(fixture)
        try stackDrop(fixture.tokens[1], onto: fixture.tokens[2], in: fixture)
        try appTakes(40, more: fixture.tokens[1], in: fixture, watch)
        fixture.handler.state.isResizing = true
        checkOverflows(fixture)
        XCTAssertFalse(fixture.controller.niriLayoutHandler.overflowReports.isEmpty)

        let joined = try XCTUnwrap(fixture.engine.findNode(for: fixture.tokens[1], in: fixture.workspaceId))
        joined.height = .auto(weight: 3)
        fixture.handler.state.isResizing = false
        checkOverflows(fixture)

        XCTAssertEqual(try column(holding: fixture.tokens[2], in: fixture).windowNodes.count, 2)
        XCTAssertNil(fixture.controller.columnModeToast.message)
    }

    func testAReportTheWindowServerContradictsUndoesNothing() throws {
        let fixture = try makeFixture(pid: 938_143)
        let watch = watchOverflows(fixture)
        try stackDrop(fixture.tokens[1], onto: fixture.tokens[2], in: fixture)
        try appTakes(40, more: fixture.tokens[1], in: fixture, watch)

        let asked = try XCTUnwrap(fixture.engine.findNode(for: fixture.tokens[1], in: fixture.workspaceId)?.frame)
        watch.shown[fixture.tokens[1].windowId] = asked
        checkOverflows(fixture)

        XCTAssertEqual(try column(holding: fixture.tokens[2], in: fixture).windowNodes.count, 2)
    }

    func testAReportLongAfterTheStepWithNothingDoneSinceStillUndoesIt() throws {
        let fixture = try makeFixture(pid: 938_144)
        let watch = watchOverflows(fixture)
        try stackDrop(fixture.tokens[1], onto: fixture.tokens[2], in: fixture)
        watch.clock.now += 60

        try appTakes(40, more: fixture.tokens[1], in: fixture, watch)
        checkOverflows(fixture)

        XCTAssertEqual(try column(holding: fixture.tokens[2], in: fixture).windowNodes.count, 1)
    }

    func testAReportAfterTheUserActedSinceTheStepUndoesNothing() throws {
        let pids: [String: pid_t] = ["mouse-down": 938_151, "command": 938_152, "wheel": 938_504, "ipc": 938_505]
        for act in ["mouse-down", "command", "wheel", "ipc"] {
            let fixture = try makeFixture(pid: try XCTUnwrap(pids[act]))
            let watch = watchOverflows(fixture)
            try stackDrop(fixture.tokens[1], onto: fixture.tokens[2], in: fixture)
            watch.clock.now += 0.1
            switch act {
            case "mouse-down":
                fixture.handler.dispatchMouseDown(at: CGPoint(x: -10_000, y: -10_000), modifiers: [])
            case "command":
                _ = fixture.controller.commandHandler
                    .handleHotkeyInvocation(.init(command: .focusNavigation(.previous)))
            case "wheel":
                let gestures = fixture.controller.settings.gestures
                gestures.scrollEnabled = true
                fixture.handler.handleScrollWheelFromTap(MouseScrollIntake(
                    location: fixture.monitor.frame.center,
                    deltaX: -niriWheelScrollTickAmount,
                    deltaY: 0,
                    momentumPhase: 0,
                    phase: 0,
                    modifiersRawValue: gestures.scrollModifierKey.cgEventFlag.rawValue
                ))
            default:
                fixture.controller.eventInterpreter.handleIntakeEvent(StampedIntakeEvent(
                    seq: 1,
                    event: .ipcCommand(IPCCommandIntake(
                        perform: {
                            IPCCommandRouter(controller: $0, sessionToken: "test").handle(.raiseAllFloatingWindows)
                        },
                        completion: { _ in }
                    ))
                ))
            }
            watch.clock.now += 0.1

            try appTakes(40, more: fixture.tokens[1], in: fixture, watch)
            checkOverflows(fixture)

            XCTAssertEqual(try column(holding: fixture.tokens[2], in: fixture).windowNodes.count, 2, act)
        }
    }

    func testAClickWhileTheDropStillSettlesCountsAsActingSinceTheStep() throws {
        let fixture = try makeFixture(pid: 938_506, animated: true)
        let watch = watchOverflows(fixture)
        try stackDrop(fixture.tokens[1], onto: fixture.tokens[2], in: fixture, settling: false)
        fixture.handler.dispatchMouseDown(at: CGPoint(x: -10_000, y: -10_000), modifiers: [])
        settle(fixture)

        try appTakes(40, more: fixture.tokens[1], in: fixture, watch)
        checkOverflows(fixture)

        XCTAssertEqual(try column(holding: fixture.tokens[2], in: fixture).windowNodes.count, 2)
    }

    func testATitleBarDragBegunDuringASlideEndsTheSlideAndBecomesALiveDrag() throws {
        let fixture = try makeFixture(pid: 938_503, windowCount: 5)
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.animateToOffset(state.viewOffset + 300, motion: .enabled, scale: 2)
        }
        fixture.controller.niriLayoutHandler.startScrollAnimationIfNeeded(
            for: fixture.workspaceId,
            state: fixture.manager.niriViewportState(for: fixture.workspaceId),
            engine: fixture.engine
        )
        XCTAssertTrue(fixture.manager.animationDriver.hasMotion(in: fixture.workspaceId))

        try fixture.startLiveDrag(fixture.tokens[1])

        XCTAssertFalse(fixture.manager.animationDriver.hasMotion(in: fixture.workspaceId))
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
    }

    func testATabbedColumnAndALoneWindowAreNeverReported() throws {
        let fixture = try makeFixture(pid: 938_129, tabbedRuns: [0 ... 1])
        let watch = watchOverflows(fixture)

        try appTakes(40, more: fixture.tokens[1], in: fixture, watch)
        try appTakes(40, more: fixture.tokens[2], in: fixture, watch)

        XCTAssertTrue(fixture.controller.niriLayoutHandler.overflowReports.isEmpty)
    }

    func testLearningAMinimumAfterADropDoesNotStopItsUndoAndTheMinimumIsLearned() throws {
        let fixture = try makeFixture(pid: 938_145)
        let watch = watchOverflows(fixture)
        try stackDrop(fixture.tokens[1], onto: fixture.tokens[2], in: fixture)
        let height = fixture.controller.insetWorkingFrame(for: fixture.monitor).height

        try appTakes(height * 0.4, more: fixture.tokens[1], in: fixture, watch, clamping: true)
        try appTakes(height * 0.4, more: fixture.tokens[2], in: fixture, watch, clamping: true)
        checkOverflows(fixture)

        XCTAssertGreaterThan(
            try XCTUnwrap(fixture.manager.observedSizeEvidence(for: fixture.tokens[1])).minSize.height,
            height / 2
        )
        XCTAssertEqual(try column(holding: fixture.tokens[2], in: fixture).windowNodes.count, 1)
    }

    func testAMinimumLearnedAfterADropThatThenFitsKeepsTheDrop() throws {
        let fixture = try makeFixture(pid: 938_146)
        let watch = watchOverflows(fixture)
        try stackDrop(fixture.tokens[1], onto: fixture.tokens[2], in: fixture)

        try appTakes(40, more: fixture.tokens[1], in: fixture, watch, clamping: true)
        checkOverflows(fixture)

        XCTAssertEqual(try column(holding: fixture.tokens[2], in: fixture).windowNodes.count, 2)
    }

    func testTheAutomaticUndoKeepsTheFocusedWindow() throws {
        let fixture = try makeFixture(pid: 938_147)
        let watch = watchOverflows(fixture)
        try stackDrop(fixture.tokens[1], onto: fixture.tokens[2], in: fixture)
        let clicked = try XCTUnwrap(fixture.engine.findNode(for: fixture.tokens[0], in: fixture.workspaceId))
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { $0.selectedNodeId = clicked.id }

        try appTakes(40, more: fixture.tokens[1], in: fixture, watch)
        checkOverflows(fixture)

        XCTAssertEqual(try column(holding: fixture.tokens[2], in: fixture).windowNodes.count, 1)
        XCTAssertEqual(fixture.manager.niriViewportState(for: fixture.workspaceId).selectedNodeId, clicked.id)
    }

    func testAStackDropKeepsTheTargetColumnsLearnedHeights() throws {
        let fixture = try makeFixture(pid: 938_148)
        var learned = ObservedSizeEvidence()
        learned.minSize.height = 500
        XCTAssertTrue(fixture.manager.setObservedSizeEvidence(learned, for: fixture.tokens[2]))

        try stackDrop(fixture.tokens[1], onto: fixture.tokens[2], in: fixture)

        XCTAssertEqual(fixture.manager.observedSizeEvidence(for: fixture.tokens[2]), learned)
    }

    private func move(_ token: WindowToken, after target: WindowToken, in fixture: Fixture) -> Bool {
        guard let window = fixture.engine.findNode(for: token, in: fixture.workspaceId),
              let beside = fixture.engine.findNode(for: target, in: fixture.workspaceId),
              let context = fixture.handler.liveColumnContext(for: fixture.workspaceId)
        else { return false }
        return fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
            fixture.engine.insertWindowByMove(
                sourceWindowId: window.id,
                targetWindowId: beside.id,
                position: .after,
                context: context,
                state: &state
            )
        }
    }

    func testTheMessageFollowsTheWindowThatWentBackWhenTheStripScrolls() throws {
        let fixture = try makeFixture(pid: 938_127)
        let watch = watchOverflows(fixture)
        try stackDrop(fixture.tokens[1], onto: fixture.tokens[2], in: fixture)
        try appTakes(40, more: fixture.tokens[1], in: fixture, watch)
        checkOverflows(fixture)
        let panel = try XCTUnwrap(fixture.controller.ownedWindowRegistry.visibleWindows(kind: .columnModeToast).first)
        XCTAssertTrue(layOut(fixture))
        fixture.controller.niriLayoutHandler.followOverflowMessage(in: fixture.workspaceId)
        let before = try XCTUnwrap(column(holding: fixture.tokens[1], in: fixture).renderedFrame)
        XCTAssertEqual(panel.frame.midX, before.midX, accuracy: 1)

        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.jumpOffset(to: state.viewOffset + 200)
        }
        XCTAssertTrue(layOut(fixture))

        let after = try XCTUnwrap(column(holding: fixture.tokens[1], in: fixture).renderedFrame)
        XCTAssertNotEqual(after.midX, before.midX, accuracy: 1)
        XCTAssertEqual(panel.frame.midX, after.midX, accuracy: 1)
    }

    private func layOut(_ fixture: Fixture) -> Bool {
        fixture.controller.niriLayoutHandler.applyFramesOnDemand(
            wsId: fixture.workspaceId,
            state: fixture.manager.niriViewportState(for: fixture.workspaceId),
            engine: fixture.engine,
            monitor: fixture.monitor
        )
    }

    private final class OverflowWatch {
        let clock = DragClock()
        var shown: [Int: CGRect] = [:]
    }

    private func watchOverflows(_ fixture: Fixture) -> OverflowWatch {
        let watch = OverflowWatch()
        fixture.controller.niriLayoutHandler.layoutStepClock = { [clock = watch.clock] in clock.now }
        fixture.controller.serviceLifecycleManager.connectAXFrameCallbacks(fixture.controller)
        addTeardownBlock { @MainActor in fixture.controller.columnModeToast.destroy() }
        return watch
    }

    private func recordStep(in fixture: Fixture, _ change: () throws -> Void) throws {
        let handler = fixture.controller.niriLayoutHandler
        let start = handler.layoutChangeStart(in: fixture.workspaceId)
        XCTAssertNotNil(start)
        try change()
        handler.recordLayoutChange(since: start)
        XCTAssertTrue(layOut(fixture))
    }

    private func appTakes(
        _ extra: CGFloat,
        more token: WindowToken,
        in fixture: Fixture,
        _ watch: OverflowWatch,
        clamping: Bool = false
    ) throws {
        XCTAssertTrue(layOut(fixture))
        let asked = try XCTUnwrap(fixture.engine.findNode(for: token, in: fixture.workspaceId)?.frame)
        var taken = asked
        taken.size.height += extra
        watch.shown[token.windowId] = taken
        fixture.handler.nativeWindowFrameProvider = { [watch] in watch.shown[$0.windowId] }
        let axManager = fixture.controller.axManager
        guard clamping else {
            axManager.onTerminalFrameRefusal?(AXFrameTerminalRefusal(
                pid: token.pid,
                windowId: token.windowId,
                targetFrame: asked,
                observedFrame: taken,
                failureReason: .verificationMismatch
            ))
            return
        }
        axManager.onStableSizeClamp?(AXFrameApplyResult(
            requestId: 0,
            pid: token.pid,
            windowId: token.windowId,
            expectedWindow: try XCTUnwrap(fixture.entry(token).axRef),
            targetFrame: asked,
            currentFrameHint: nil,
            writeResult: AXFrameWriteResult(
                observedFrame: taken,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: .verificationMismatch
            )
        ))
    }

    private func checkOverflows(_ fixture: Fixture) {
        fixture.controller.layoutRefreshController.dropQueuedRefreshes()
        fixture.manager.withEngineMutationScope(in: fixture.workspaceId) {
            for token in fixture.tokens {
                guard let learned = fixture.manager.observedSizeEvidence(for: token)?.minSize else { continue }
                fixture.engine.updateWindowConstraints(
                    for: token,
                    constraints: WindowSizeConstraints(minSize: learned, maxSize: .zero, isFixed: false),
                    in: fixture.workspaceId,
                    motion: .disabled
                )
            }
        }
        _ = layOut(fixture)
        fixture.controller.niriLayoutHandler.checkOverflowReports()
    }

    func testAStackDropThatFitsShowsNoMessage() throws {
        let fixture = try makeFixture(pid: 938_126)

        try stackDrop(fixture.tokens[1], onto: fixture.tokens[2], in: fixture)

        XCTAssertEqual(try column(holding: fixture.tokens[1], in: fixture).windowNodes.count, 2)
        XCTAssertNil(fixture.controller.columnModeToast.message)
    }

    private func stackDrop(
        _ token: WindowToken,
        onto target: WindowToken,
        in fixture: Fixture,
        settling: Bool = true
    ) throws {
        let clock = DragClock()
        fixture.handler.liveDragClock = { clock.now }
        try fixture.startLiveDrag(token)
        let drop = try fixture.centre(of: target)
        fixture.drag(to: drop)
        clock.now += 0.2
        fixture.handler.liveDragSession?.hoverTimer?.fire()
        XCTAssertNotNil(fixture.engine.liveColumnMove?.landing)
        fixture.handler.dispatchMouseUp(at: drop)
        if settling {
            settle(fixture)
        }
    }

    private func settle(_ fixture: Fixture) {
        fixture.manager.animationDriver.removeMotions(for: [fixture.workspaceId])
        _ = fixture.engine.cancelAnimations(in: fixture.workspaceId)
        fixture.handler.handleNiriAnimationsSettled(in: fixture.workspaceId)
    }

    private func edgeClock(_ fixture: Fixture) -> EdgeClock {
        let clock = EdgeClock()
        fixture.handler.liveDragClock = { clock.now }
        return clock
    }

    private func edgePoint(_ edge: MouseInputState.LiveEdge, _ fixture: Fixture) -> CGPoint {
        let frame = fixture.monitor.frame
        return CGPoint(x: edge == .trailing ? frame.maxX - 10 : frame.minX + 10, y: frame.midY)
    }

    private func startLiveDragInsideTheEdgeZone(
        _ edge: MouseInputState.LiveEdge,
        dragging token: WindowToken,
        in fixture: Fixture
    ) throws -> CGPoint {
        let frame = fixture.monitor.frame
        let zone = MoveConfiguration.liveEdgeZoneWidth(forDisplayWidth: frame.width)
        let start = CGPoint(x: edge == .trailing ? frame.maxX - zone / 2 : frame.minX + zone / 2, y: frame.midY)
        try fixture.beginDrag(token)
        fixture.drag(to: start)
        try fixture.macOSMoves(token, to: try fixture.frame(token).offsetBy(dx: 30, dy: 0))
        return start
    }

    private func startEdgeScroll(
        _ edge: MouseInputState.LiveEdge,
        dragging token: WindowToken,
        in fixture: Fixture,
        started: Bool = false
    ) throws {
        let clock = edgeClock(fixture)
        fixture.engine.liveHoverDelay = 0.12
        if !started {
            try fixture.startLiveDrag(token)
        }
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
        clock.now += MoveConfiguration.liveEdgeScrollDelay
        fixture.handler.startLiveEdgeScrollIfDue()
        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.hopping, true)
    }

    private func centreThirdPoints(
        of token: WindowToken,
        aroundTheLeadingEdgeZoneIn fixture: Fixture
    ) throws -> (outside: CGPoint, inZone: CGPoint) {
        let column = try column(holding: token, in: fixture)
        let placed = try XCTUnwrap(liveStrip(fixture).first { $0.column === column })
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.workspaceId))
        let centre = try XCTUnwrap(fixture.engine.liveCentreThird(of: placed, context: context))
        let frame = fixture.monitor.frame
        let zone = MoveConfiguration.liveEdgeZoneWidth(forDisplayWidth: frame.width)
        let y = try fixture.frame(token).midY
        let outside = CGPoint(x: frame.minX + zone + 10, y: y)
        let inZone = CGPoint(x: frame.minX + zone - 3, y: y)
        for x in [outside.x, inZone.x] {
            XCTAssertTrue(centre.contains(x), "\(x) outside \(centre)")
        }
        return (outside, inZone)
    }

    @discardableResult
    private func startEdgeScrollWithinTheStack(in fixture: Fixture) throws -> WindowToken {
        let clock = edgeClock(fixture)
        let dragged = fixture.tokens[0]
        let working = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        let stack = try fixture.settledFrame(dragged)
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.jumpOffset(to: state.viewOffset + stack.midX - working.minX)
        }
        try fixture.confirmLayout()
        let press = try fixture.press(dragged)
        fixture.drag(to: CGPoint(x: press.x + 5, y: press.y))
        try fixture.macOSMoves(dragged, to: try fixture.frame(dragged).offsetBy(dx: 30, dy: 0))
        XCTAssertEqual(fixture.engine.liveColumnMove?.home, .stackSlot)

        fixture.drag(to: CGPoint(x: edgePoint(.leading, fixture).x, y: press.y))
        clock.now += MoveConfiguration.liveEdgeScrollDelay
        fixture.handler.startLiveEdgeScrollIfDue()

        XCTAssertEqual(fixture.engine.liveColumnMove?.home, .stackSlot)
        XCTAssertTrue(fixture.handler.isLiveEdgeScrolling)
        return dragged
    }

    private func hopEdge(_ fixture: Fixture, until done: () -> Bool = { false }) {
        let maximumHopsIncludingEnd = fixture.tokens.count + 1
        for _ in 0 ..< maximumHopsIncludingEnd {
            guard fixture.handler.liveDragSession?.edgeScroll?.hopping == true else { return }
            fixture.manager.animationDriver.removeMotions(for: [fixture.workspaceId])
            _ = fixture.engine.cancelAnimations(in: fixture.workspaceId)
            fixture.handler.runLiveEdgeHop()
            if done() { return }
        }
        XCTAssertNotEqual(
            fixture.handler.liveDragSession?.edgeScroll?.hopping,
            true,
            "Edge hops exceeded the fixture's windows"
        )
    }

    private func tickEdgeScroll(_ fixture: Fixture, until done: () -> Bool = { false }) {
        let driver = fixture.manager.animationDriver
        let sampleFramesPerSecond = Fixture.animationSampleRate
        let scrollSpeed = Double(MoveConfiguration.liveEdgeScrollSpeed)
        let maximumMotionsIncludingEnd = fixture.tokens.count + 1
        for _ in 0 ..< maximumMotionsIncludingEnd {
            guard let motion = driver.edgeScroll(in: fixture.workspaceId) else { return }
            XCTAssertEqual(motion.speed, scrollSpeed)
            let duration = abs(motion.to - motion.from) / scrollSpeed
            let tickCount = max(1, Int(ceil(duration * sampleFramesPerSecond)))
            for tick in 1 ... tickCount {
                guard let current = driver.edgeScroll(in: fixture.workspaceId) else { return }
                guard current === motion else { break }
                let time = tick == tickCount
                    ? (motion.startTime + duration).nextUp
                    : motion.startTime + Double(tick) / sampleFramesPerSecond
                _ = driver.tickResult(in: fixture.workspaceId, at: time)
                fixture.handler.handleLiveEdgeScrollTick(in: fixture.workspaceId, at: time)
                if done() { return }
            }
            guard driver.edgeScroll(in: fixture.workspaceId) !== motion else {
                XCTFail("Edge scroll survived its calculated completion time")
                return
            }
        }
        XCTAssertFalse(
            driver.hasEdgeScroll(in: fixture.workspaceId),
            "Edge scroll motions exceeded the fixture's windows"
        )
    }

    private func scroll(_ fixture: Fixture, so token: WindowToken, showsAtTheLeftEdge visible: CGFloat) throws {
        let frame = try fixture.settledFrame(token)
        let edge = fixture.controller.insetWorkingFrame(for: fixture.monitor).minX
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.jumpOffset(to: state.viewOffset + frame.maxX - (edge + visible))
        }
        try fixture.confirmLayout()
        XCTAssertEqual(try fixture.settledFrame(token).maxX, edge + visible, accuracy: 1)
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

    func testPortraitDragReferenceUsesPhysicalHeightAndLeavesWidthUntouched() throws {
        let display = CGRect(x: -260, y: 180, width: 900, height: 1_500)
        let fixture = try makeFixture(pid: 938_501, portrait: true, displayFrame: display)
        let offset = display.height / 8
        fixture.handler.liveDragSession = .init(referenceOffset: offset)
        let centre = CGPoint(x: display.midX, y: display.midY)
        XCTAssertEqual(
            fixture.handler.liveDragReference(centre, orientation: .vertical),
            CGPoint(x: centre.x, y: centre.y + offset)
        )
        let nearEnd = CGPoint(x: display.midX, y: display.maxY - offset / 2)
        XCTAssertEqual(
            fixture.handler.liveDragReference(nearEnd, orientation: .vertical),
            CGPoint(x: nearEnd.x, y: display.maxY - 1)
        )
        XCTAssertEqual(fixture.handler.liveDragWindowMidX(nearEnd, orientation: .vertical), nearEnd.y + offset)
        let outside = CGPoint(x: display.maxX + display.width, y: display.midY)
        XCTAssertEqual(
            fixture.handler.liveDragReference(outside, orientation: .vertical),
            CGPoint(x: outside.x, y: outside.y + offset)
        )
    }

    func testPortraitEdgeHoldArmsOnlyAfterMovingTowardItsPhysicalEdge() throws {
        let display = CGRect(x: -260, y: 180, width: 900, height: 1_500)
        for edge in [MouseInputState.LiveEdge.leading, .trailing] {
            let fixture = try makeFixture(
                pid: edge == .leading ? 938_502 : 938_503,
                portrait: true,
                displayFrame: display
            )
            try fixture.startLiveDrag(fixture.tokens[1])
            let zone = MoveConfiguration.liveEdgeZoneWidth(forDisplayWidth: display.height)
            let start = CGPoint(
                x: display.midX,
                y: edge == .leading ? display.minY + zone / 2 : display.maxY - zone / 2
            )
            fixture.handler.clearLiveEdgeZone()
            fixture.handler.holdLiveEdgeZone(startingAt: start, monitorFrame: display, orientation: .vertical)
            XCTAssertEqual(fixture.handler.liveDragSession?.edgeZoneHold?.edge, edge)
            fixture.handler.trackLiveEdgeZone(
                at: CGPoint(x: start.x + zone, y: start.y), monitorFrame: display, orientation: .vertical
            )
            XCTAssertNil(fixture.handler.liveDragSession?.edgeScroll)
            let inward = CGPoint(x: start.x, y: start.y + (edge == .leading ? zone / 4 : -zone / 4))
            fixture.handler.trackLiveEdgeZone(at: inward, monitorFrame: display, orientation: .vertical)
            XCTAssertNil(fixture.handler.liveDragSession?.edgeScroll)
            let outward = CGPoint(x: start.x, y: start.y + (edge == .leading ? -zone / 4 : zone / 4))
            fixture.handler.trackLiveEdgeZone(at: outward, monitorFrame: display, orientation: .vertical)
            XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.edge, edge)
            XCTAssertNil(fixture.handler.liveDragSession?.edgeZoneHold)
            fixture.handler.cancelActiveMouseInteraction()
            XCTAssertNil(fixture.handler.liveDragSession)
        }
    }

    func testPortraitTopEdgeHopsAndCancellationRestoreTheOriginalRowsAndViewport() throws {
        let display = CGRect(x: -260, y: 180, width: 900, height: 1_500)
        let fixture = try makeFixture(pid: 938_504, windowCount: 6, portrait: true, displayFrame: display)
        _ = try addDisplay(rightOf: fixture)
        let clock = edgeClock(fixture)
        let viewport = fixture.manager.niriViewportState(for: fixture.workspaceId)
        try fixture.startLiveDrag(fixture.tokens[1])
        let zone = MoveConfiguration.liveEdgeZoneWidth(forDisplayWidth: display.height)
        let top = CGPoint(x: display.midX, y: display.maxY - zone / 2)
        fixture.drag(to: top)
        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.edge, .trailing)
        let held = try XCTUnwrap(fixture.controller.pointerEdgeBarrier.liveDragHold?.heldDirections)
        XCTAssertTrue(held.contains(.up))
        XCTAssertFalse(held.contains(.left))
        XCTAssertFalse(held.contains(.right))
        clock.now += MoveConfiguration.liveEdgeScrollDelay
        fixture.handler.startLiveEdgeScrollIfDue()
        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.hopping, true)
        XCTAssertNotEqual(fixture.landingOrder(), fixture.tokens)
        fixture.handler.cancelActiveMouseInteraction()
        XCTAssertEqual(fixture.order(), fixture.tokens)
        let restored = fixture.manager.niriViewportState(for: fixture.workspaceId)
        XCTAssertEqual(restored.viewOffset, viewport.viewOffset)
        XCTAssertEqual(restored.activeColumnIndex, viewport.activeColumnIndex)
        XCTAssertEqual(restored.selectedNodeId, viewport.selectedNodeId)
        XCTAssertNil(fixture.controller.pointerEdgeBarrier.liveDragHold)
    }

    func testPortraitCrossingHandsOverWhenTheDisplayHasNoEligibleStrip() throws {
        let fixture = try makeFixture(pid: 938_505, portrait: true)
        let right = try addDisplay(rightOf: fixture)
        let start = try fixture.frame(fixture.tokens[0])
        try fixture.startLiveDrag(fixture.tokens[0])
        let desired = try fixture.farHalf(of: fixture.tokens[1])
        fixture.drag(to: CGPoint(x: desired.x, y: desired.y + start.height / 2 - Fixture.titleBarInset))
        XCTAssertNotEqual(fixture.landingOrder(), fixture.tokens)
        fixture.drag(to: CGPoint(x: right.frame.midX, y: right.frame.midY))
        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertEqual(fixture.order(), fixture.tokens)
        XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.liveDragHandedOver, true)
        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
    }

    func testALoneColumnUsesAnotherNiriStripToBeginOnEitherAxis() throws {
        for portrait in [false, true] {
            let fixture = try makeFixture(pid: portrait ? 938_506 : 938_507, windowCount: 1, portrait: portrait)
            let other = try addDisplay(rightOf: fixture)
            fixture.controller.settings.workspaces.configurations.append(WorkspaceConfiguration(
                name: "2", monitorAssignment: .specificDisplay(OutputId(from: other)), layoutType: .niri
            ))
            fixture.manager.applySettings()
            _ = fixture.manager.focusWorkspace(named: "2")
            let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.workspaceId))
            XCTAssertTrue(fixture.handler.hasOtherLiveDisplay(than: context))
            try fixture.startLiveDrag(fixture.tokens[0])
            XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
            XCTAssertNotNil(fixture.engine.liveColumnMove)
            fixture.handler.cancelActiveMouseInteraction()
            XCTAssertEqual(fixture.order(), fixture.tokens)
        }
    }

    private func makeFixture(
        pid: pid_t,
        windowCount: Int = 4,
        stackFirstTwo: Bool = false,
        tabbedRuns: [ClosedRange<Int>] = [],
        animated: Bool = false,
        hoverDelay: TimeInterval = 0,
        layout: LayoutType = .niri,
        displayWidth: CGFloat? = nil,
        portrait: Bool = false,
        displayFrame suppliedDisplayFrame: CGRect? = nil
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
        var displayFrame = suppliedDisplayFrame ?? workingFrame
        displayFrame.size.width = displayWidth ?? displayFrame.width
        let monitor = Monitor(
            id: .init(displayId: 93_801),
            displayId: 93_801,
            frame: displayFrame,
            visibleFrame: displayFrame,
            hasNotch: false,
            name: "Live Title Bar Drag"
        )
        if portrait {
            controller.settings.monitors.updateOrientationSettings(
                MonitorOrientationSettings(
                    monitorName: monitor.name,
                    monitorDisplayId: monitor.displayId,
                    orientation: .vertical
                ),
                for: monitor
            )
        }
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
        controller.updateNiriConfig(edgePeekShare: controller.edgePeekShare)
        let engine = try XCTUnwrap(controller.niriEngine)
        engine.liveHoverDelay = hoverDelay
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
            if portrait {
                column.height = .proportion(1.0 / 3.0)
                column.cachedHeight = 0
            }
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
        controller.updateNiriConfig(edgePeekShare: controller.edgePeekShare)
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
        let drop = try fixture.farHalf(of: neighbour)
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

        let drop = try fixture.farHalf(of: fixture.tokens[3])
        fixture.drag(to: drop)
        fixture.handler.dispatchMouseUp(at: drop)
        _ = try fixture.frames(animationTime: .infinity)

        let returned = try railCommand(for: dragged, in: fixture)
        XCTAssertEqual(returned.tileFrame, dragged.renderedFrame)
        XCTAssertNotEqual(returned.visibleTileFrame, .null)
        XCTAssertEqual(Set(railOwners(fixture)), [.niriColumn(dragged.id), .niriColumn(other.id)])
    }

    func testEdgeHopsWithATabbedColumnMoveTheDropSpaceOnceEachUntilTheStripEnd() throws {
        let fixture = try makeFixture(pid: 938_062, windowCount: 8, tabbedRuns: [1 ... 3])
        let dragged = try column(holding: fixture.tokens[2], in: fixture)
        let landingIndex = { () -> Int? in
            let columns = fixture.engine.columns(in: fixture.workspaceId)
            return columns.filter { $0 !== dragged }.firstIndex { $0.isLiveDropSpace }
                ?? columns.firstIndex { $0 === dragged }
        }
        let homeIndex = try XCTUnwrap(landingIndex())
        try startEdgeScroll(.trailing, dragging: fixture.tokens[2], in: fixture)
        let firstHop = try XCTUnwrap(landingIndex())

        var indices = [firstHop]
        var hops = 0
        hopEdge(fixture) {
            if fixture.handler.liveDragSession?.edgeScroll?.hopsDone != true {
                hops += 1
            }
            if let index = landingIndex(), index != indices.last {
                indices.append(index)
            }
            return false
        }

        XCTAssertGreaterThan(firstHop, homeIndex)
        XCTAssertEqual(indices, Array(firstHop ... 5))
        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.hopsDone, true)
        XCTAssertEqual(hops, indices.count - 1)
        XCTAssertEqual(dragged.windowNodes.count, 3)
        XCTAssertTrue(dragged.isTabbed)
    }

    func testANewLiveDragFinishesAStackDropThatIsStillSettling() throws {
        let fixture = try makeFixture(pid: 938_312, windowCount: 5)
        let (dragged, target) = (fixture.tokens[1], fixture.tokens[2])
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.workspaceId))
        let window = try XCTUnwrap(fixture.engine.findNode(for: dragged, in: fixture.workspaceId))
        let targetFrame = try fixture.frame(target)
        let drop = CGPoint(x: targetFrame.midX, y: targetFrame.minY + targetFrame.height / 4)
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
            XCTAssertTrue(fixture.engine.liveColumnMoveBegin(
                windowId: window.id,
                windowToken: dragged,
                context: context,
                state: &state
            ))
            _ = fixture.engine.liveColumnMoveUpdate(cursor: drop, at: 0, context: context, state: &state)
            _ = fixture.engine.liveColumnMoveUpdate(cursor: drop, at: 1, context: context, state: &state)
            XCTAssertNotNil(fixture.engine.liveColumnMove?.landing)
            XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: context, state: &state))
        }
        XCTAssertTrue(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))

        try fixture.startLiveDrag(fixture.tokens[0])

        XCTAssertFalse(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))
        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains {
            $0.windowNodes.isEmpty && $0.isLiveHomeSpot
        })
    }

    func testAStackDropFinishesWhenItSettlesWhileAnotherWorkspaceHasALiveDrag() throws {
        let fixture = try makeFixture(pid: 938_313, windowCount: 5)
        let (dragged, target) = (fixture.tokens[1], fixture.tokens[2])
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.workspaceId))
        let window = try XCTUnwrap(fixture.engine.findNode(for: dragged, in: fixture.workspaceId))
        let targetFrame = try fixture.frame(target)
        let drop = CGPoint(x: targetFrame.midX, y: targetFrame.minY + targetFrame.height / 4)
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
            XCTAssertTrue(fixture.engine.liveColumnMoveBegin(
                windowId: window.id,
                windowToken: dragged,
                context: context,
                state: &state
            ))
            _ = fixture.engine.liveColumnMoveUpdate(cursor: drop, at: 0, context: context, state: &state)
            _ = fixture.engine.liveColumnMoveUpdate(cursor: drop, at: 1, context: context, state: &state)
            XCTAssertNotNil(fixture.engine.liveColumnMove?.landing)
            XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: context, state: &state))
        }
        XCTAssertTrue(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))

        let otherWorkspace = WorkspaceDescriptor.ID()
        let otherTokens = (0 ..< 3).map { WindowToken(pid: 938_314, windowId: 938_414 + $0) }
        var previous: NiriWindow?
        for token in otherTokens {
            previous = fixture.engine.addWindow(token: token, to: otherWorkspace, afterSelection: previous?.id)
        }
        let otherWindow = try XCTUnwrap(fixture.engine.findNode(for: otherTokens[1], in: otherWorkspace))
        let otherContext = NiriInteractionContext(
            workspaceId: otherWorkspace,
            motion: .disabled,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: .horizontal
        )
        var otherState = ViewportState(selectedNodeId: otherWindow.id)
        fixture.manager.withEngineMutationScope(in: otherWorkspace) {
            XCTAssertTrue(fixture.engine.liveColumnMoveBegin(
                windowId: otherWindow.id,
                windowToken: otherTokens[1],
                context: otherContext,
                state: &otherState
            ))
        }

        fixture.handler.handleNiriAnimationsSettled(in: fixture.workspaceId)

        XCTAssertFalse(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))
        XCTAssertEqual(fixture.engine.liveColumnMove?.workspaceId, otherWorkspace)
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.windowNodes.isEmpty })
    }

    private func dropOntoStackWhileAnimating(_ fixture: Fixture) throws {
        fixture.controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        let (dragged, target) = (fixture.tokens[1], fixture.tokens[2])
        let clock = DragClock()
        fixture.handler.liveDragClock = { clock.now }
        try fixture.startLiveDrag(dragged)
        let targetFrame = try fixture.frame(target)
        let drop = CGPoint(x: targetFrame.midX, y: targetFrame.minY + targetFrame.height / 4)
        fixture.drag(to: drop)
        clock.now += 0.2
        fixture.handler.liveDragSession?.hoverTimer?.fire()
        XCTAssertNotNil(fixture.engine.liveColumnMove?.landing)
        fixture.handler.dispatchMouseUp(at: drop)
        XCTAssertTrue(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))
        XCTAssertTrue(fixture.engine.isLiveColumnMoveActive(in: fixture.workspaceId))
    }

    func testAStackDropWhoseSettleIsCancelledFinishesAndLetsTheStripFollowFocus() throws {
        let fixture = try makeFixture(pid: 938_315, windowCount: 5, animated: true)
        try dropOntoStackWhileAnimating(fixture)

        fixture.controller.niriLayoutHandler.cancelAnimationMotion(for: fixture.workspaceId)

        XCTAssertFalse(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))
        XCTAssertFalse(fixture.engine.isLiveColumnMoveActive(in: fixture.workspaceId))
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.windowNodes.isEmpty })
    }

    func testAStackDropWhoseScrollAnimationStopsMidSettleFinishes() throws {
        let fixture = try makeFixture(pid: 938_316, windowCount: 5, animated: true)
        try dropOntoStackWhileAnimating(fixture)
        XCTAssertTrue(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.workspaceId))

        fixture.controller.layoutRefreshController.stopScrollAnimation(for: fixture.monitor.displayId)

        XCTAssertFalse(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.windowNodes.isEmpty })
    }

    func testAStackDropWhoseSettleEndsStillFinishesThroughTheSettledCallback() throws {
        let fixture = try makeFixture(pid: 938_317, windowCount: 5, animated: true)
        try dropOntoStackWhileAnimating(fixture)
        let handler = fixture.controller.niriLayoutHandler

        handler.tickScrollAnimation(targetTime: CACurrentMediaTime() + 60, displayId: fixture.monitor.displayId)

        XCTAssertFalse(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.windowNodes.isEmpty })
    }

    func testModifiedBodyPressesDoNotStartManagedMovesOnEitherStripAxis() throws {
        let presses: [(pid: pid_t, portrait: Bool, modifier: CGEventFlags, moves: Bool)] = [
            (938_073, false, .maskAlternate, false),
            (938_074, true, .maskAlternate, false),
            (938_075, true, .maskCommand, false)
        ]
        for press in presses {
            let fixture = try makeFixture(pid: press.pid, portrait: press.portrait)
            let token = fixture.tokens[1]
            let start = try fixture.frame(token)
            fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }

            XCTAssertFalse(fixture.handler.dispatchMouseDown(
                at: CGPoint(x: start.midX, y: start.midY),
                modifiers: press.modifier,
                windowIdUnderPointer: token.windowId
            ))

            XCTAssertEqual(fixture.handler.state.isMoving, press.moves, "\(press)")
            XCTAssertEqual(fixture.engine.interactiveMove != nil, press.moves, "\(press)")
            XCTAssertEqual(fixture.handler.tapInputs.capturedInteractionButton != nil, press.moves, "\(press)")
            XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.token, press.moves ? nil : token, "\(press)")
            fixture.handler.cancelActiveMouseInteraction()
        }
    }

    func testATitleBarDragStartedWithAModifierIsARegularLiveDrag() throws {
        for modifier in [CGEventFlags.maskAlternate, .maskCommand, .maskControl, .maskShift] {
            let fixture = try makeFixture(pid: 938_079)
            let token = fixture.tokens[1]
            let start = try fixture.frame(token)
            fixture.handler.retireNativeTitleBarDragAtInputBoundary()
            fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            fixture.reported.frame = start
            fixture.handler.nativeWindowFrameProvider = { [reported = fixture.reported] _ in reported.frame }
            let grab = CGPoint(x: start.midX, y: start.maxY - 10)

            XCTAssertFalse(fixture.handler.dispatchMouseDown(
                at: grab,
                modifiers: modifier,
                windowIdUnderPointer: token.windowId
            ))
            fixture.drag(to: CGPoint(x: grab.x + 5, y: grab.y))
            try fixture.macOSMoves(token, to: start.offsetBy(dx: 30, dy: 0))

            XCTAssertFalse(fixture.handler.state.isMoving, "\(modifier)")
            XCTAssertTrue(fixture.handler.isLiveColumnDragActive, "\(modifier)")
            fixture.handler.cancelActiveMouseInteraction()
        }
    }

    func testATabbedTargetShowsABlankRailEntryForTheDraggedWindow() throws {
        let fixture = try makeFixture(pid: 938_076, windowCount: 5, tabbedRuns: [2 ... 3])
        let tabbed = try column(holding: fixture.tokens[2], in: fixture)
        let clock = DragClock()
        fixture.handler.liveDragClock = { clock.now }
        try fixture.startLiveDrag(fixture.tokens[0])

        fixture.drag(to: try fixture.centre(of: fixture.tokens[3]))
        clock.now += 0.2
        fixture.handler.liveDragSession?.hoverTimer?.fire()
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

    func testATabPullStartingInsideTheEdgeZoneWaitsUntilPushedTowardTheEdge() throws {
        for portrait in [false, true] {
            let fixture = try makeFixture(pid: 938_318, windowCount: 5, tabbedRuns: [1 ... 2], portrait: portrait)
            let clock = edgeClock(fixture)
            let pulled = fixture.tokens[2]
            let rail = try railInfo(holding: pulled, in: fixture)
            let start = try fixture.frame(pulled)
            fixture.handler.nativeWindowFrameProvider = { _ in start }
            let frame = fixture.monitor.frame
            let zone = MoveConfiguration.liveEdgeZoneWidth(forDisplayWidth: portrait ? frame.height : frame.width)
            let inZone = portrait
                ? CGPoint(x: frame.midX, y: frame.minY + zone / 2)
                : CGPoint(x: frame.minX + zone / 2, y: frame.midY)

            tabPull(pulled, at: inZone, rail: rail, in: fixture)

            XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
            XCTAssertEqual(fixture.handler.liveDragSession?.edgeZoneHold?.edge, .leading)
            clock.now += MoveConfiguration.liveEdgeScrollDelay
            fixture.handler.startLiveEdgeScrollIfDue()
            XCTAssertNil(fixture.handler.liveDragSession?.edgeScroll)

            let outward = portrait
                ? CGPoint(x: inZone.x, y: inZone.y - zone / 4)
                : CGPoint(x: inZone.x - zone / 4, y: inZone.y)
            fixture.drag(to: outward)
            XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.edge, .leading)
            XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.enteredAt, clock.now)
            clock.now += MoveConfiguration.liveEdgeScrollDelay
            fixture.handler.startLiveEdgeScrollIfDue()
            XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.hopping, true)
        }
    }

    func testDraggingATabInTheRailPullsItOutAndTheWindowFollowsThePointer() throws {
        for portrait in [false, true] {
            let fixture = try makeFixture(pid: 938_080, windowCount: 5, tabbedRuns: [1 ... 2], portrait: portrait)
            let (kept, pulled, neighbour) = (fixture.tokens[1], fixture.tokens[2], fixture.tokens[3])
            let tabbed = try column(holding: pulled, in: fixture)
            XCTAssertTrue(tabbed.windowNodes[tabbed.activeTileIdx].token == pulled)
            let rail = try railInfo(holding: pulled, in: fixture)
            let start = try fixture.frame(pulled)
            fixture.handler.nativeWindowFrameProvider = { _ in start }
            let press = CGPoint(x: start.minX - Fixture.titleBarInset, y: start.midY)

            tabPull(pulled, at: press, rail: rail, in: fixture)
            XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
            XCTAssertEqual(fixture.engine.liveColumnMove?.pullsTab, true)
            XCTAssertEqual(tabbed.windowNodes.map(\.token), [kept])
            XCTAssertEqual(tabbed.displayMode, .normal)
            XCTAssertNil(fixture.controller.niriLayoutHandler.desiredTabRailInfos().first {
                $0.owner == .niriColumn(tabbed.id)
            })
            XCTAssertEqual(fixture.engine.liveFloatingFrame(for: pulled, in: fixture.workspaceId), start)

            let away = try fixture.farHalf(of: neighbour)
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
            XCTAssertEqual(try column(holding: pulled, in: fixture).windowNodes.map(\.token), [pulled])
        }
    }

    func testTheLayoutWritesTheFloatingFrameOfAPulledTab() throws {
        for portrait in [false, true] {
            let fixture = try makeFixture(pid: 938_081, windowCount: 4, tabbedRuns: [1 ... 2], portrait: portrait)
            let pulled = fixture.tokens[2]
            let rail = try railInfo(holding: pulled, in: fixture)
            let start = try fixture.frame(pulled)
            fixture.handler.nativeWindowFrameProvider = { _ in start }
            tabPull(pulled, at: CGPoint(x: start.minX - Fixture.titleBarInset, y: start.midY), rail: rail, in: fixture)
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
    }

    func testCancellingATabPullPutsTheTabBack() throws {
        for portrait in [false, true] {
            let fixture = try makeFixture(pid: 938_082, windowCount: 4, tabbedRuns: [1 ... 2], portrait: portrait)
            let pulled = fixture.tokens[2]
            let tabbed = try column(holding: pulled, in: fixture)
            let tabs = tabbed.windowNodes.map(\.token)
            let rail = try railInfo(holding: pulled, in: fixture)
            let start = try fixture.frame(pulled)
            fixture.handler.nativeWindowFrameProvider = { _ in start }
            tabPull(pulled, at: CGPoint(x: start.minX - Fixture.titleBarInset, y: start.midY), rail: rail, in: fixture)
            fixture.drag(to: try fixture.farHalf(of: fixture.tokens[3]))
            XCTAssertEqual(tabbed.windowNodes.count, 1)

            fixture.handler.cancelLiveColumnDrag()
            fixture.handler.dispatchMouseUp(at: try fixture.centre(of: fixture.tokens[3]))

            XCTAssertNil(fixture.engine.liveColumnMove)
            XCTAssertEqual(tabbed.windowNodes.map(\.token), tabs)
            XCTAssertTrue(tabbed.isTabbed)
            XCTAssertEqual(tabbed.windowNodes[tabbed.activeTileIdx].token, pulled)
        }
    }

    func testCancellingATabPullSpringsFromWhereTheStripIsShown() throws {
        let fixture = try makeFixture(pid: 938_096, windowCount: 4, tabbedRuns: [1 ... 2], animated: true)
        let pulled = fixture.tokens[2]
        let tabbed = try column(holding: pulled, in: fixture)
        let rail = try railInfo(holding: pulled, in: fixture)
        let start = try fixture.frame(pulled)
        fixture.handler.nativeWindowFrameProvider = { _ in start }
        let tabbedIndex = try XCTUnwrap(fixture.engine.columnIndex(of: tabbed, in: fixture.workspaceId))
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { $0.activeColumnIndex = tabbedIndex }
        tabPull(pulled, at: CGPoint(x: start.minX - 10, y: start.midY), rail: rail, in: fixture)
        XCTAssertEqual(tabbed.windowNodes.count, 1)
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.workspaceId))
        var state = fixture.manager.niriViewportState(for: fixture.workspaceId)
        state.clearOffsetTransition()
        func minX(_ state: ViewportState) throws -> CGFloat {
            try XCTUnwrap(fixture.engine.liveColumnStrip(context: context, state: state)
                .first { $0.column === tabbed }).minX
        }
        let shown = try minX(state)
        let offsetBefore = state.viewOffset

        fixture.manager.withEngineMutationScope(in: fixture.workspaceId) {
            XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: context, state: &state))
        }

        var springStart = state
        springStart.viewOffset = offsetBefore + state.offsetTransition.rebaseDelta
        XCTAssertEqual(try minX(springStart), shown, accuracy: 0.5)
    }

    func testPortraitRailPullDetachesTowardItsVerticalPointerMovement() throws {
        for trailing in [false, true] {
            let fixture = try makeFixture(pid: 938_086, windowCount: 4, tabbedRuns: [1 ... 2], portrait: true)
            let pulled = fixture.tokens[2]
            let rail = try railInfo(holding: pulled, in: fixture)
            let start = try fixture.frame(pulled)
            let press = CGPoint(x: start.minX - Fixture.titleBarInset, y: start.midY)
            let verticalDelta = (trailing ? 1.0 : -1.0) * start.height / 10
            let horizontalDelta = (trailing ? -1.0 : 1.0) * Fixture.titleBarInset / 4
            let location = CGPoint(x: press.x + horizontalDelta, y: press.y + verticalDelta)

            tabPull(pulled, at: location, rail: rail, pressedAt: press, in: fixture)

            XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
            XCTAssertEqual(
                fixture.order(),
                trailing
                    ? [fixture.tokens[0], fixture.tokens[1], pulled, fixture.tokens[3]]
                    : [fixture.tokens[0], pulled, fixture.tokens[1], fixture.tokens[3]]
            )
            XCTAssertEqual(fixture.engine.liveFloatingFrame(for: pulled, in: fixture.workspaceId), start)
            fixture.handler.cancelLiveColumnDrag()
            XCTAssertEqual(
                try column(holding: pulled, in: fixture).windowNodes.map(\.token),
                [fixture.tokens[1], pulled]
            )
        }
    }

    func testNiriRailsOnEitherAxisTakeDragsAndDwindleRailsDoNot() throws {
        let landscape = try makeFixture(pid: 938_083, windowCount: 4, tabbedRuns: [1 ... 2])
        let landscapeRail = try railInfo(holding: landscape.tokens[2], in: landscape)
        XCTAssertTrue(landscape.controller.tabRailManager.acceptsDrags(landscapeRail))
        XCTAssertFalse(landscape.controller.tabRailManager.acceptsDrags(TabRailInfo(
            workspaceId: landscapeRail.workspaceId,
            owner: .dwindleTile(DwindleTileId()),
            plannedSeq: landscapeRail.plannedSeq,
            tileFrame: landscapeRail.tileFrame,
            visibleTileFrame: landscapeRail.visibleTileFrame,
            tabCount: landscapeRail.tabCount,
            activeVisualIndex: landscapeRail.activeVisualIndex,
            activeWindowId: landscapeRail.activeWindowId,
            tabs: landscapeRail.tabs,
            orderingWindowId: landscapeRail.orderingWindowId,
            displayFrame: landscapeRail.displayFrame
        )))

        let portrait = try makeFixture(pid: 938_085, windowCount: 4, tabbedRuns: [1 ... 2], portrait: true)
        let pulled = portrait.tokens[2]
        let portraitRail = try railInfo(holding: pulled, in: portrait)
        XCTAssertTrue(portrait.controller.tabRailManager.acceptsDrags(portraitRail))
        let start = try portrait.frame(pulled)
        portrait.handler.nativeWindowFrameProvider = { _ in start }

        tabPull(
            pulled,
            at: CGPoint(x: start.minX - Fixture.titleBarInset, y: start.midY),
            rail: portraitRail,
            in: portrait
        )

        XCTAssertNotNil(portrait.engine.liveColumnMove)
        XCTAssertTrue(portrait.handler.isLiveColumnDragActive)
    }

    func testATabPullCarriesOnThroughTheMouseTapOnceTheRailIsGone() throws {
        for portrait in [false, true] {
            let fixture = try makeFixture(pid: 938_084, windowCount: 5, tabbedRuns: [1 ... 2], portrait: portrait)
            let (kept, pulled) = (fixture.tokens[1], fixture.tokens[2])
            let tabbed = try column(holding: pulled, in: fixture)
            let rail = try railInfo(holding: pulled, in: fixture)
            let start = try fixture.frame(pulled)
            fixture.handler.nativeWindowFrameProvider = { _ in start }
            fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            let press = CGPoint(x: start.minX - Fixture.titleBarInset, y: start.midY)
            tabPull(pulled, at: press, rail: rail, in: fixture)

            let away = try fixture.farHalf(of: fixture.tokens[3])
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
    }

    func testATabPullStartsFromTheLayoutFrameAtThePointerNotFromAStaleFrame() throws {
        for portrait in [false, true] {
            let fixture = try makeFixture(pid: 938_085, windowCount: 4, tabbedRuns: [1 ... 2], portrait: portrait)
            let pulled = fixture.tokens[2]
            let rail = try railInfo(holding: pulled, in: fixture)
            let layoutFrame = try fixture.frame(pulled)
            fixture.handler.nativeWindowFrameProvider = { _ in CGRect(x: -6000, y: -6000, width: 400, height: 300) }
            let press = CGPoint(x: layoutFrame.minX - Fixture.titleBarInset, y: layoutFrame.midY)
            let began = CGPoint(x: press.x + 12, y: press.y)

            tabPull(pulled, at: began, rail: rail, pressedAt: press, in: fixture)

            XCTAssertEqual(fixture.engine.liveFloatingFrame(for: pulled, in: fixture.workspaceId), layoutFrame)
            let translation = CGSize(width: 50, height: -20)
            let next = CGPoint(x: began.x + translation.width, y: began.y + translation.height)
            fixture.drag(to: next)
            XCTAssertEqual(
                fixture.engine.liveFloatingFrame(for: pulled, in: fixture.workspaceId),
                layoutFrame.offsetBy(dx: translation.width, dy: translation.height)
            )
        }
    }

    func testAChangeWithNothingToAnimateSchedulesOneFollowUpForTheNextTurn() throws {
        let fixture = try makeFixture(pid: 938_200)
        let counted = PassCounter()
        fixture.handler.liveDragClock = { counted.tick() }
        try fixture.startLiveDrag(fixture.tokens[1])
        let order = fixture.landingOrder()

        fixture.drag(to: try fixture.farHalf(of: fixture.tokens[2]))

        XCTAssertNotEqual(fixture.landingOrder(), order)
        let followUp = try XCTUnwrap(fixture.handler.liveDragSession?.followUp)
        XCTAssertTrue(followUp.isValid)
        let before = counted.calls

        followUp.fire()

        XCTAssertFalse(followUp.isValid)
        XCTAssertGreaterThan(counted.calls, before)
        XCTAssertFalse(fixture.handler.liveDragSession?.followUp === followUp)
        let afterFollowUp = counted.calls
        followUp.fire()
        XCTAssertEqual(counted.calls, afterFollowUp)
    }

    func testANewEventFoldsInThePendingFollowUpSoAtMostOneIsPending() throws {
        let fixture = try makeFixture(pid: 938_201, windowCount: 6)
        try fixture.startLiveDrag(fixture.tokens[1])
        let target = try fixture.farHalf(of: fixture.tokens[2])
        fixture.drag(to: target)
        let first = try XCTUnwrap(fixture.handler.liveDragSession?.followUp)

        fixture.drag(to: target)

        XCTAssertFalse(first.isValid)
        XCTAssertNil(fixture.handler.liveDragSession?.followUp)

        var timers = [first]
        for token in fixture.tokens.dropFirst(2) {
            fixture.drag(to: try fixture.farHalf(of: token))
            if let pending = fixture.handler.liveDragSession?.followUp, !timers.contains(where: { $0 === pending }) {
                timers.append(pending)
            }
            XCTAssertLessThanOrEqual(timers.filter(\.isValid).count, 1)
        }
    }

    func testNoFollowUpRunsAfterTheDragEnds() throws {
        for ending in ["release", "cancel"] {
            let fixture = try makeFixture(pid: ending == "release" ? 938_202 : 938_203)
            let counted = PassCounter()
            fixture.handler.liveDragClock = { counted.tick() }
            try fixture.startLiveDrag(fixture.tokens[1])
            let target = try fixture.farHalf(of: fixture.tokens[2])
            fixture.drag(to: target)
            let followUp = try XCTUnwrap(fixture.handler.liveDragSession?.followUp, ending)

            if ending == "release" {
                fixture.handler.dispatchMouseUp(at: target)
            } else {
                fixture.handler.cancelLiveColumnDrag()
            }

            XCTAssertFalse(followUp.isValid, ending)
            XCTAssertNil(fixture.handler.liveDragSession, ending)
            let order = fixture.order()
            let calls = counted.calls
            followUp.fire()
            XCTAssertEqual(counted.calls, calls, ending)
            XCTAssertEqual(fixture.order(), order, ending)
        }
    }

    func testReleasingWithoutADisplayForTheMovesWorkspaceCancelsTheMove() throws {
        let fixture = try makeFixture(pid: 938_204)
        let dragged = fixture.tokens[1]
        try fixture.startLiveDrag(dragged)
        fixture.drag(to: try fixture.farHalf(of: fixture.tokens[2]))
        let lost = WorkspaceDescriptor.ID()
        fixture.engine.liveColumnMove?.workspaceId = lost
        XCTAssertNil(fixture.handler.liveColumnContext(for: lost))

        XCTAssertFalse(fixture.handler.finishLiveColumnDrag(token: dragged))

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertNil(fixture.handler.liveDragSession)
        XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
    }
}

@MainActor
private final class PassCounter {
    private(set) var calls = 0

    func tick() -> TimeInterval {
        calls += 1
        return 1_000
    }
}

extension LayoutRefreshController {
    func dropQueuedRefreshes() {
        layoutState.activeRefreshTask?.cancel()
        layoutState.activeRefreshTask = nil
        layoutState.activeRefresh = nil
        layoutState.pendingRefresh = nil
        layoutState.pendingDebounceTask?.cancel()
        layoutState.pendingDebounceTask = nil
    }
}
