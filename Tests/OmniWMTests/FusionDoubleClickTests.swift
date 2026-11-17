// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class FusionDoubleClickTests: NiriInteractionTestCase {
    @MainActor
    private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let tokens: [WindowToken]

        var handler: MouseEventHandler {
            controller.mouseEventHandler
        }

        var engine: NiriLayoutEngine {
            controller.niriEngine!
        }

        func window(_ token: WindowToken) throws -> NiriWindow {
            try XCTUnwrap(engine.findNode(for: token, in: workspaceId))
        }

        func column(_ token: WindowToken) throws -> NiriContainer {
            try XCTUnwrap(engine.findColumn(containing: window(token), in: workspaceId))
        }

        func frame(_ token: WindowToken) throws -> CGRect {
            let window = try window(token)
            return try XCTUnwrap(window.renderedFrame ?? window.frame)
        }

        var orientation: Monitor.Orientation {
            handler.resolvedNiriOrientation(engine: engine, workspaceId: workspaceId, monitor: monitor)
        }

        var tolerance: CGFloat {
            1 / monitor.backingScale
        }

        var primarySides: ClosedRange<CGFloat> {
            let frame = controller.insetWorkingFrame(for: monitor)
            let gap = controller.innerGap(for: monitor)
            return orientation == .horizontal
                ? (frame.minX + gap) ... (frame.maxX - gap)
                : (frame.minY + gap) ... (frame.maxY - gap)
        }

        func primaryRange(_ token: WindowToken) throws -> ClosedRange<CGFloat> {
            let frame = try frame(token)
            return orientation == .horizontal ? frame.minX ... frame.maxX : frame.minY ... frame.maxY
        }

        func primaryEdge(_ token: WindowToken, trailing: Bool) throws -> CGPoint {
            if orientation == .horizontal { return try trailing ? rightEdge(token) : leftEdge(token) }
            return try trailing ? topEdge(token) : bottomEdge(token)
        }

        func relayout() {
            let gap = controller.innerGap(for: monitor)
            _ = engine.calculateLayoutWithVisibility(
                state: controller.workspaceManager.niriViewportState(for: workspaceId),
                workspaceId: workspaceId,
                monitorFrame: controller.insetWorkingFrame(for: monitor),
                gaps: (horizontal: gap, vertical: gap),
                orientation: orientation
            )
        }

        func sampleLayout(at time: TimeInterval) {
            let gap = controller.innerGap(for: monitor)
            _ = engine.calculateLayoutWithVisibility(
                state: controller.workspaceManager.niriViewportState(for: workspaceId),
                workspaceId: workspaceId,
                monitorFrame: controller.insetWorkingFrame(for: monitor),
                gaps: (horizontal: gap, vertical: gap),
                orientation: orientation,
                animationTime: time
            )
        }

        func secondaryEdge(_ token: WindowToken, trailing: Bool = true) throws -> CGPoint {
            if orientation == .horizontal { return try trailing ? topEdge(token) : bottomEdge(token) }
            return try trailing ? rightEdge(token) : leftEdge(token)
        }

        func secondarySpring(_ token: WindowToken) throws -> SpringAnimation {
            let window = try window(token)
            return try XCTUnwrap(orientation == .horizontal ? window.heightAnimation : window.widthAnimation).animation
        }

        @discardableResult
        func doubleClick(at point: CGPoint, modifiers: CGEventFlags = [], clickCount: Int64 = 2) -> Bool {
            let pressTaken = handler.dispatchAuthoritativeTap(
                type: .leftMouseDown,
                location: point,
                modifiers: modifiers,
                buttonNumber: 0,
                scrollPayload: nil,
                clickCount: clickCount
            )
            let releaseTaken = handler.dispatchAuthoritativeTap(
                type: .leftMouseUp,
                location: point,
                modifiers: modifiers,
                buttonNumber: 0,
                scrollPayload: nil
            )
            XCTAssertEqual(pressTaken, releaseTaken)
            XCTAssertNil(handler.tapInputs.capturedInteractionButton)
            relayout()
            return pressTaken
        }

        func topEdge(_ token: WindowToken) throws -> CGPoint {
            let frame = try frame(token)
            return CGPoint(x: frame.midX, y: frame.maxY - 1)
        }

        func bottomEdge(_ token: WindowToken) throws -> CGPoint {
            let frame = try frame(token)
            return CGPoint(x: frame.midX, y: frame.minY + 1)
        }

        func leftEdge(_ token: WindowToken) throws -> CGPoint {
            let frame = try frame(token)
            return CGPoint(x: frame.minX + 1, y: frame.midY)
        }

        var screenSides: (left: CGFloat, right: CGFloat) {
            let frame = controller.insetWorkingFrame(for: monitor)
            let gap = controller.innerGap(for: monitor)
            return (frame.minX + gap, frame.maxX - gap)
        }

        func settleStripStart() throws {
            let drift = try primaryRange(tokens[0]).lowerBound - primarySides.lowerBound
            controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
                state.jumpOffset(to: state.viewOffset + drift)
            }
            relayout()
        }

        func rightEdge(_ token: WindowToken) throws -> CGPoint {
            let frame = try frame(token)
            return CGPoint(x: frame.maxX - 1, y: frame.midY)
        }

        func titleBar(_ token: WindowToken) throws -> CGPoint {
            let frame = try frame(token)
            return CGPoint(x: frame.midX, y: frame.maxY - 20)
        }

        func select(_ token: WindowToken) throws {
            let handle = try XCTUnwrap(controller.workspaceManager.handle(for: token))
            controller.niriLayoutHandler.withNiriWindowContext(.window(handle)) { engine, window, context, state in
                state.selectedNodeId = window.id
                engine.ensureSelectionVisible(node: window, context: context, state: &state)
            }
            relayout()
        }
    }

    func testTheZoneIsAnEdgeBandInsideOrOutsideTheFrameButNeverACorner() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        func zone(_ x: CGFloat, _ y: CGFloat, gap: CGFloat = 16) -> FusionDoubleClickZone? {
            NiriLayoutEngine.fusionDoubleClickZone(at: CGPoint(x: x, y: y), in: frame, gap: gap, bounds: bounds)
        }

        XCTAssertEqual(zone(300, 399), .edge(.top))
        XCTAssertEqual(zone(300, 405), .edge(.top))
        XCTAssertEqual(zone(300, 101), .edge(.bottom))
        XCTAssertEqual(zone(300, 95), .edge(.bottom))
        XCTAssertEqual(zone(101, 250), .edge(.left))
        XCTAssertEqual(zone(95, 250), .edge(.left))
        XCTAssertEqual(zone(499, 250), .edge(.right))
        XCTAssertEqual(zone(505, 250), .edge(.right))
        XCTAssertNil(zone(300, 407))
        XCTAssertNil(zone(101, 399))
        XCTAssertNil(zone(95, 95))
    }

    func testTheOuterBandStopsHalfWayToTheNextWindowAndAtTheVisibleFrame() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let open = CGRect(x: 0, y: 0, width: 1000, height: 1000)

        XCTAssertEqual(
            NiriLayoutEngine.fusionDoubleClickZone(at: CGPoint(x: 300, y: 402), in: frame, gap: 6, bounds: open),
            .edge(.top)
        )
        XCTAssertNil(
            NiriLayoutEngine.fusionDoubleClickZone(at: CGPoint(x: 300, y: 404), in: frame, gap: 6, bounds: open)
        )
        XCTAssertNil(
            NiriLayoutEngine.fusionDoubleClickZone(at: CGPoint(x: 300, y: 402), in: frame, gap: 0, bounds: open)
        )
        XCTAssertNil(
            NiriLayoutEngine.fusionDoubleClickZone(
                at: CGPoint(x: 300, y: 402),
                in: frame,
                gap: 16,
                bounds: CGRect(x: 0, y: 0, width: 1000, height: 400)
            )
        )
    }

    func testTheTitleZoneIsBelowTheTopBandWithinItsDepthAndTheBodyIsNoZone() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        func zone(_ y: CGFloat) -> FusionDoubleClickZone? {
            NiriLayoutEngine.fusionDoubleClickZone(at: CGPoint(x: 300, y: y), in: frame, gap: 16, bounds: bounds)
        }

        XCTAssertEqual(zone(395), .titleBar)
        XCTAssertEqual(zone(400 - NiriLayoutEngine.doubleClickTitleBarDepth), .titleBar)
        XCTAssertNil(zone(400 - NiriLayoutEngine.doubleClickTitleBarDepth - 1))
        XCTAssertNil(zone(250))
    }

    func testTheTapAsksAboutPlainDoubleClicksArmedNearby() {
        let option = CGEventFlags.maskAlternate
        let point = CGPoint(x: 400, y: 300)
        func asks(_ clickCount: Int64, _ flags: CGEventFlags = [], armedAt: CGPoint? = point) -> Bool {
            MouseEventHandler.asksAboutFusionDoubleClick(
                clickCount: clickCount,
                flags: flags,
                armedAt: armedAt,
                location: point
            )
        }

        XCTAssertTrue(asks(2))
        XCTAssertTrue(asks(2, .maskNonCoalesced))
        XCTAssertFalse(asks(1))
        XCTAssertFalse(asks(3))
        XCTAssertFalse(asks(2, option))
        XCTAssertFalse(asks(2, .maskCommand))
        XCTAssertFalse(asks(2, .maskShift))
        XCTAssertFalse(asks(2, [.maskShift, .maskCommand]))
        XCTAssertFalse(asks(2, [.maskShift, option]))
        XCTAssertFalse(asks(2, .maskControl))
        XCTAssertFalse(asks(2, armedAt: nil))
        XCTAssertFalse(asks(2, armedAt: CGPoint(x: 420, y: 300)))
        XCTAssertTrue(asks(2, armedAt: CGPoint(x: 404, y: 303)))
    }

    func testAFirstClickOnADoubleClickZoneArmsTheTap() throws {
        let fixture = try makeFixture(pid: 941_027)
        let frame = try fixture.frame(fixture.tokens[1])
        let edge = try fixture.rightEdge(fixture.tokens[1])

        fixture.handler.receiveTapMouseDown(at: edge, modifiers: [], clickCount: 1)
        XCTAssertEqual(fixture.handler.inputTapThread.filterSnapshot.fusionDoubleClickArmedAt, edge)

        fixture.handler.receiveTapMouseDown(at: CGPoint(x: frame.midX, y: frame.midY), modifiers: [], clickCount: 1)
        XCTAssertNil(fixture.handler.inputTapThread.filterSnapshot.fusionDoubleClickArmedAt)

        fixture.handler.receiveTapMouseDown(at: edge, modifiers: .maskAlternate, clickCount: 1)
        XCTAssertNil(fixture.handler.inputTapThread.filterSnapshot.fusionDoubleClickArmedAt)
    }

    func testWithoutABarOnlyWindowBackgroundCountsAsTheTitleBar() {
        for role in ["AXWindow", "AXToolbar", "AXTabGroup", "AXGroup", "AXStaticText"] {
            XCTAssertTrue(TitleBarHitTest.isTitleBar(TitleBarHit(role: role)), role)
        }
        for role in ["AXButton", "AXTextField", "AXRadioButton", "AXPopUpButton", "AXWebArea", "AXScrollArea"] {
            XCTAssertFalse(TitleBarHitTest.isTitleBar(TitleBarHit(role: role)), role)
        }
        XCTAssertFalse(TitleBarHitTest.isTitleBar(TitleBarHit(role: nil)))
        XCTAssertFalse(TitleBarHitTest.isTitleBar(nil))
    }

    func testAnAppThatDoesntAnswerIsNotTreatedAsHavingNoBar() {
        for error in [AXError.cannotComplete, .failure, .apiDisabled, .notImplemented] {
            XCTAssertTrue(TitleBarHitTest.isFailedRead(error), "\(error.rawValue)")
        }
        for error in [AXError.success, .noValue, .attributeUnsupported] {
            XCTAssertFalse(TitleBarHitTest.isFailedRead(error), "\(error.rawValue)")
        }
    }

    func testBelowTheWindowsBarNothingCountsAsTheTitleBar() {
        for role in ["AXWindow", "AXGroup", "AXStaticText", "AXScrollArea", "AXButton"] {
            XCTAssertFalse(TitleBarHitTest.isTitleBar(TitleBarHit(role: role, placement: .outsideBar)), role)
        }
    }

    func testInsideTheWindowsBarAnythingButAControlWithinItCountsAsTheTitleBar() {
        for role in ["AXScrollArea", "AXWebArea", "AXSplitGroup", "AXImage", "AXGroup", "AXStaticText", "AXWindow"] {
            XCTAssertTrue(TitleBarHitTest.isTitleBar(inBar(role, elementWithinBar: false)), role)
            if TitleBarHitTest.isWindowBackground(role: role) {
                XCTAssertTrue(TitleBarHitTest.isTitleBar(inBar(role, elementWithinBar: true)), role)
            }
        }
        for role in ["AXButton", "AXRadioButton", "AXTextField", "AXPopUpButton", "AXCheckBox", "AXLink"] {
            XCTAssertFalse(TitleBarHitTest.isTitleBar(inBar(role, elementWithinBar: true)), role)
        }
    }

    func testATabInTheBarCountsAsTheTitleBar() {
        XCTAssertTrue(TitleBarHitTest.isTitleBar(inBar(
            "AXRadioButton",
            subrole: "AXTabButton",
            elementWithinBar: true
        )))
        XCTAssertFalse(TitleBarHitTest.isTitleBar(TitleBarHit(role: "AXRadioButton", subrole: "AXTabButton")))
    }

    func testAControlReachingBelowTheBarIsContentUnderItAndCountsAsTheTitleBar() {
        XCTAssertTrue(TitleBarHitTest.isTitleBar(inBar("AXTextArea", elementWithinBar: false)))
        XCTAssertFalse(TitleBarHitTest.isTitleBar(inBar("AXTextArea", elementWithinBar: true)))
        XCTAssertFalse(TitleBarHitTest.isTitleBar(TitleBarHit(role: "AXTextArea", placement: .outsideBar)))
    }

    private func inBar(_ role: String, subrole: String? = nil, elementWithinBar: Bool) -> TitleBarHit {
        TitleBarHit(role: role, subrole: subrole, placement: .insideBar(elementWithinBar: elementWithinBar))
    }

    func testALoneWindowKeepsAHeightItWasGiven() throws {
        let fixture = try makeFixture(pid: 941_001)
        let chosenHeight: CGFloat = 400
        try fixture.window(fixture.tokens[0]).height = .fixed(chosenHeight)
        fixture.relayout()

        XCTAssertEqual(try fixture.frame(fixture.tokens[0]).height, chosenHeight)
        XCTAssertGreaterThan(try fixture.frame(fixture.tokens[1]).height, chosenHeight)
    }

    func testAStackWithFixedHeightsFillsItsColumnInProportion() throws {
        let fixture = try makeFixture(pid: 941_150, stackFirstTwo: true)
        try fixture.window(fixture.tokens[0]).height = .fixed(200)
        try fixture.window(fixture.tokens[1]).height = .fixed(100)
        fixture.relayout()
        let upper = try fixture.frame(fixture.tokens[0])
        let lower = try fixture.frame(fixture.tokens[1])
        let lone = try fixture.frame(fixture.tokens[2])
        let gap = fixture.controller.innerGap(for: fixture.monitor)

        XCTAssertEqual(upper.height + lower.height + gap, lone.height, accuracy: 1)
        XCTAssertEqual(upper.height, 2 * lower.height, accuracy: 1)
    }

    func testExpellingAWindowFromAStackGrowsTheWindowLeftWithAnAnimation() throws {
        let fixture = try makeFixture(pid: 941_152, stackFirstTwo: true)
        let left = try fixture.window(fixture.tokens[0])
        let full = try fixture.frame(fixture.tokens[2]).height
        XCTAssertLessThan(try fixture.frame(fixture.tokens[0]).height, full - 1)
        fixture.controller.motionPolicy.animationsEnabled = true
        let handle = try XCTUnwrap(fixture.controller.workspaceManager.handle(for: fixture.tokens[1]))

        _ = fixture.controller.niriLayoutHandler.moveWindow(handle: handle, direction: .right)
        fixture.relayout()

        XCTAssertNotNil(left.heightAnimation)
        XCTAssertFalse(try fixture.column(fixture.tokens[0]).windowNodes.contains { $0.token == fixture.tokens[1] })
        left.heightAnimation = nil
        fixture.relayout()
        XCTAssertEqual(try fixture.frame(fixture.tokens[0]).height, full, accuracy: 1)
    }

    func testATopOrBottomEdgeDoubleClickOnALoneWindowIsTakenAndChangesNothing() throws {
        let fixture = try makeFixture(pid: 941_002)
        let lone = try fixture.window(fixture.tokens[0])
        let frame = try fixture.frame(fixture.tokens[0])

        XCTAssertTrue(fixture.doubleClick(at: try fixture.topEdge(fixture.tokens[0])))
        XCTAssertTrue(fixture.doubleClick(at: try fixture.bottomEdge(fixture.tokens[0])))

        XCTAssertTrue(lone.height.isAuto)
        XCTAssertEqual(try fixture.frame(fixture.tokens[0]), frame)
    }

    func testATakenDoubleClickCountsAsOneUserAction() throws {
        let fixture = try makeFixture(pid: 941_302)
        let before = fixture.controller.userActionCount

        XCTAssertTrue(fixture.doubleClick(at: try fixture.topEdge(fixture.tokens[0])))

        XCTAssertEqual(fixture.controller.userActionCount, before + 1)
    }

    func testTheBottomEdgeOfAStackedWindowActsLikeItsTopEdge() throws {
        let fixture = try makeFixture(pid: 941_003, stackFirstTwo: true)

        XCTAssertTrue(fixture.doubleClick(at: try fixture.bottomEdge(fixture.tokens[0])))

        XCTAssertTrue(try fixture.column(fixture.tokens[0]).isTabbed)
    }

    func testDoubleClickingAStackedWindowsTopEdgeMakesTheColumnTabbedWithThatWindowShown() throws {
        let fixture = try makeFixture(pid: 941_004, stackFirstTwo: true)
        let column = try fixture.column(fixture.tokens[1])
        let window = try fixture.window(fixture.tokens[1])

        XCTAssertTrue(fixture.doubleClick(at: try fixture.topEdge(fixture.tokens[1])))

        XCTAssertTrue(column.isTabbed)
        XCTAssertTrue(fixture.engine.projectedActiveWindow(in: column, workspaceId: fixture.workspaceId) === window)
        XCTAssertEqual(column.windowNodes.map(\.token), [fixture.tokens[0], fixture.tokens[1]])
    }

    func testDoubleClickingATabbedColumnsTopEdgeMakesItAStackAgain() throws {
        let fixture = try makeFixture(pid: 941_005, stackFirstTwo: true)
        let column = try fixture.column(fixture.tokens[0])
        let upper = try fixture.window(fixture.tokens[0])
        upper.height = .fixed(300)
        fixture.doubleClick(at: try fixture.topEdge(fixture.tokens[0]))
        XCTAssertTrue(column.isTabbed)

        XCTAssertTrue(fixture.doubleClick(at: try fixture.topEdge(fixture.tokens[0])))

        XCTAssertFalse(column.isTabbed)
        XCTAssertEqual(upper.height, .fixed(300))
    }

    func testATabbedColumnTurnedBackIntoAStackShrinksTheShownWindowAndSnapsTheOthersIn() throws {
        for (index, portrait) in [false, true].enumerated() {
            let fixture = try makeFixture(pid: pid_t(941_018 + index), stackFirstTwo: true, portrait: portrait)
            let column = try fixture.column(fixture.tokens[0])
            let stacked = try fixture.tokens[0 ..< 2].map { try fixture.frame($0) }
            XCTAssertTrue(fixture.doubleClick(at: try fixture.secondaryEdge(fixture.tokens[1])))
            XCTAssertTrue(column.isTabbed)
            let tabbed = try fixture.frame(fixture.tokens[1])

            fixture.controller.motionPolicy.animationsEnabled = true
            XCTAssertTrue(fixture.doubleClick(at: try fixture.secondaryEdge(fixture.tokens[1])))
            let spring = try fixture.secondarySpring(fixture.tokens[1])
            fixture.sampleLayout(at: spring.startTime)

            XCTAssertFalse(column.isTabbed)
            let shown = try fixture.frame(fixture.tokens[1])
            XCTAssertEqual(
                portrait ? shown.minX : shown.minY,
                portrait ? tabbed.minX : tabbed.minY,
                accuracy: fixture.tolerance
            )
            XCTAssertEqual(
                portrait ? shown.width : shown.height,
                portrait ? tabbed.width : tabbed.height,
                accuracy: fixture.tolerance
            )
            let other = try fixture.frame(fixture.tokens[0])
            XCTAssertEqual(
                portrait ? other.minX : other.minY,
                portrait ? stacked[0].minX : stacked[0].minY,
                accuracy: fixture.tolerance
            )
            XCTAssertEqual(
                portrait ? other.width : other.height,
                portrait ? stacked[0].width : stacked[0].height,
                accuracy: fixture.tolerance
            )
            XCTAssertFalse(try fixture.window(fixture.tokens[0]).hasAnyAnimationRunning)
            fixture.sampleLayout(at: .infinity)
            for (token, expected) in zip(fixture.tokens[0 ..< 2], stacked) {
                let frame = try fixture.frame(token)
                XCTAssertEqual(
                    portrait ? frame.minX : frame.minY,
                    portrait ? expected.minX : expected.minY,
                    accuracy: fixture.tolerance
                )
                XCTAssertEqual(
                    portrait ? frame.width : frame.height,
                    portrait ? expected.width : expected.height,
                    accuracy: fixture.tolerance
                )
            }
        }
    }

    func testTheTabbedCommandAlsoSnapsTheOtherWindowsIn() throws {
        for (index, portrait) in [false, true].enumerated() {
            let fixture = try makeFixture(pid: pid_t(941_026 + index), stackFirstTwo: true, portrait: portrait)
            let column = try fixture.column(fixture.tokens[0])
            let stacked = try fixture.tokens[0 ..< 2].map { try fixture.frame($0) }
            XCTAssertTrue(fixture.doubleClick(at: try fixture.secondaryEdge(fixture.tokens[1])))
            XCTAssertTrue(column.isTabbed)
            let tabbed = try fixture.frame(fixture.tokens[1])

            fixture.controller.motionPolicy.animationsEnabled = true
            let handle = try XCTUnwrap(fixture.controller.workspaceManager.handle(for: fixture.tokens[1]))
            XCTAssertTrue(fixture.controller.niriLayoutHandler.toggleColumnTabbed(target: .window(handle)))
            fixture.sampleLayout(at: try fixture.secondarySpring(fixture.tokens[1]).startTime)

            XCTAssertFalse(column.isTabbed)
            let shown = try fixture.frame(fixture.tokens[1])
            XCTAssertEqual(
                portrait ? shown.width : shown.height,
                portrait ? tabbed.width : tabbed.height,
                accuracy: fixture.tolerance
            )
            let other = try fixture.frame(fixture.tokens[0])
            XCTAssertEqual(
                portrait ? other.minX : other.minY,
                portrait ? stacked[0].minX : stacked[0].minY,
                accuracy: fixture.tolerance
            )
            XCTAssertEqual(
                portrait ? other.width : other.height,
                portrait ? stacked[0].width : stacked[0].height,
                accuracy: fixture.tolerance
            )
            XCTAssertFalse(try fixture.window(fixture.tokens[0]).hasAnyAnimationRunning)
        }
    }

    func testAStackTurnedTabbedStillMovesEachWindowFromItsStackedPlace() throws {
        for (index, portrait) in [false, true].enumerated() {
            let fixture = try makeFixture(pid: pid_t(941_019 + index), stackFirstTwo: true, portrait: portrait)
            let stacked = try fixture.tokens[0 ..< 2].map { try fixture.frame($0) }

            fixture.controller.motionPolicy.animationsEnabled = true
            XCTAssertTrue(fixture.doubleClick(at: try fixture.secondaryEdge(fixture.tokens[1])))
            let startTime = try XCTUnwrap(fixture.tokens[0 ..< 2].map { try fixture.secondarySpring($0).startTime }
                .min())
            fixture.sampleLayout(at: startTime)

            XCTAssertTrue(try fixture.column(fixture.tokens[0]).isTabbed)
            for (token, start) in zip(fixture.tokens[0 ..< 2], stacked) {
                let frame = try fixture.frame(token)
                XCTAssertEqual(
                    portrait ? frame.minX : frame.minY,
                    portrait ? start.minX : start.minY,
                    accuracy: fixture.tolerance
                )
                XCTAssertEqual(
                    portrait ? frame.width : frame.height,
                    portrait ? start.width : start.height,
                    accuracy: fixture.tolerance
                )
            }
        }
    }

    func testADoubleClickAlreadyPassedToTheAppIsLeftAlone() throws {
        let fixture = try makeFixture(pid: 941_090)
        let column = try fixture.column(fixture.tokens[1])
        let width = column.width
        let start = try fixture.frame(fixture.tokens[1])

        XCTAssertFalse(fixture.handler.receiveTapMouseDown(
            at: try fixture.rightEdge(fixture.tokens[1]),
            modifiers: [],
            clickCount: 2
        ))
        fixture.relayout()

        XCTAssertNil(fixture.handler.tapInputs.capturedInteractionButton)
        XCTAssertEqual(column.width, width)
        XCTAssertEqual(try fixture.frame(fixture.tokens[1]), start)
    }

    func testDoubleClickingTheRightEdgeStretchesItToTheScreenEdgeAndBack() throws {
        let fixture = try makeFixture(pid: 941_006)
        let column = try fixture.column(fixture.tokens[1])
        let width = column.width
        let start = try fixture.frame(fixture.tokens[1])
        XCTAssertLessThan(start.maxX, fixture.screenSides.right - 50)

        XCTAssertTrue(fixture.doubleClick(at: try fixture.rightEdge(fixture.tokens[1])))
        var frame = try fixture.frame(fixture.tokens[1])
        XCTAssertEqual(frame.minX, start.minX, accuracy: 1)
        XCTAssertEqual(frame.maxX, fixture.screenSides.right, accuracy: 1)
        XCTAssertFalse(column.isFullWidth)

        XCTAssertTrue(fixture.doubleClick(at: try fixture.rightEdge(fixture.tokens[1])))
        frame = try fixture.frame(fixture.tokens[1])
        XCTAssertEqual(frame.minX, start.minX, accuracy: 1)
        XCTAssertEqual(frame.maxX, start.maxX, accuracy: 1)
        XCTAssertEqual(column.width, width)
    }

    func testDoubleClickingTheLeftEdgeStretchesItToTheScreenEdgeAndBack() throws {
        let fixture = try makeFixture(pid: 941_021)
        try fixture.settleStripStart()
        let column = try fixture.column(fixture.tokens[1])
        let width = column.width
        let start = try fixture.frame(fixture.tokens[1])
        XCTAssertGreaterThan(start.minX, fixture.screenSides.left + 50)

        XCTAssertTrue(fixture.doubleClick(at: try fixture.leftEdge(fixture.tokens[1])))
        var frame = try fixture.frame(fixture.tokens[1])
        XCTAssertEqual(frame.maxX, start.maxX, accuracy: 1)
        XCTAssertEqual(frame.minX, fixture.screenSides.left, accuracy: 1)

        XCTAssertTrue(fixture.doubleClick(at: try fixture.leftEdge(fixture.tokens[1])))
        frame = try fixture.frame(fixture.tokens[1])
        XCTAssertEqual(frame.maxX, start.maxX, accuracy: 1)
        XCTAssertEqual(frame.minX, start.minX, accuracy: 1)
        XCTAssertEqual(column.width, width)
    }

    func testAWindowThatPacksItsWidthStillGetsItsEarlierWidthBack() throws {
        let fixture = try makeFixture(pid: 941_024)
        let column = try fixture.column(fixture.tokens[1])
        let width = column.width
        let start = try fixture.frame(fixture.tokens[1])
        let reach = fixture.screenSides.right - start.minX
        try fixture.window(fixture.tokens[1]).packingHints = ObservedPackingHints(
            width: ObservedAxisHint(requested: reach - 2, observed: reach + 20)
        )

        XCTAssertTrue(fixture.doubleClick(at: try fixture.rightEdge(fixture.tokens[1])))
        var frame = try fixture.frame(fixture.tokens[1])
        XCTAssertEqual(frame.width, reach + 20, accuracy: 1)
        XCTAssertEqual(frame.maxX, fixture.screenSides.right, accuracy: 1)

        XCTAssertTrue(fixture.doubleClick(at: try fixture.rightEdge(fixture.tokens[1])))
        frame = try fixture.frame(fixture.tokens[1])
        XCTAssertEqual(frame.minX, start.minX, accuracy: 1)
        XCTAssertEqual(frame.width, start.width, accuracy: 1)
        XCTAssertEqual(column.width, width)
    }

    func testTheOtherSideStaysPutWhicheverColumnIsActive() throws {
        for (offset, activeColumn) in [0, 2].enumerated() {
            for rightSide in [false, true] {
                let fixture = try makeFixture(pid: 941_030 + Int32(offset * 2 + (rightSide ? 1 : 0)))
                try fixture.settleStripStart()
                let shift = try fixture.frame(fixture.tokens[activeColumn]).minX - fixture.frame(fixture.tokens[0]).minX
                fixture.controller.workspaceManager.withNiriViewportState(for: fixture.workspaceId) { state in
                    state.activeColumnIndex = activeColumn
                    state.jumpOffset(to: state.viewOffset - shift)
                }
                fixture.relayout()
                let start = try fixture.frame(fixture.tokens[1])
                let label = "active \(activeColumn), \(rightSide ? "right" : "left") side"

                let edge = rightSide ? try fixture.rightEdge(fixture.tokens[1]) : try fixture
                    .leftEdge(fixture.tokens[1])
                XCTAssertTrue(fixture.doubleClick(at: edge), label)

                let frame = try fixture.frame(fixture.tokens[1])
                if rightSide {
                    XCTAssertEqual(frame.minX, start.minX, accuracy: 1, label)
                    XCTAssertEqual(frame.maxX, fixture.screenSides.right, accuracy: 1, label)
                } else {
                    XCTAssertEqual(frame.maxX, start.maxX, accuracy: 1, label)
                    XCTAssertEqual(frame.minX, fixture.screenSides.left, accuracy: 1, label)
                }
            }
        }
    }

    func testASideAlreadyAtTheScreenEdgeStaysPut() throws {
        let fixture = try makeFixture(pid: 941_022)
        try fixture.settleStripStart()
        let last = try fixture.frame(fixture.tokens[2])
        XCTAssertEqual(last.maxX, fixture.screenSides.right, accuracy: 1)
        let width = try fixture.column(fixture.tokens[2]).width

        XCTAssertTrue(fixture.doubleClick(at: try fixture.rightEdge(fixture.tokens[2])))

        XCTAssertEqual(try fixture.frame(fixture.tokens[2]), last)
        XCTAssertEqual(try fixture.column(fixture.tokens[2]).width, width)
    }

    func testAStackStretchesAsAWholeColumn() throws {
        let fixture = try makeFixture(pid: 941_023, stackFirstTwo: true)
        try fixture.settleStripStart()
        let starts = try fixture.tokens[0 ..< 2].map { try fixture.frame($0) }

        XCTAssertTrue(fixture.doubleClick(at: try fixture.rightEdge(fixture.tokens[1])))

        XCTAssertFalse(try fixture.column(fixture.tokens[0]).isTabbed)
        for (token, start) in zip(fixture.tokens[0 ..< 2], starts) {
            let frame = try fixture.frame(token)
            XCTAssertEqual(frame.minX, start.minX, accuracy: 1, "\(token)")
            XCTAssertEqual(frame.maxX, fixture.screenSides.right, accuracy: 1, "\(token)")
        }
    }

    func testDoubleClickingTheTitleBarGoesToFullWidthAndBack() throws {
        let fixture = try makeFixture(pid: 941_007)
        let token = fixture.tokens[1]
        let column = try fixture.column(token)
        let sides = fixture.screenSides
        let width = column.width
        try fixture.settleStripStart()
        let before = try fixture.frame(token)

        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
        XCTAssertEqual(column.width, .proportion(1))
        let full = try fixture.frame(token)
        XCTAssertEqual(full.width, sides.right - sides.left, accuracy: 1)
        XCTAssertEqual(full.minX, sides.left, accuracy: 1)

        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
        XCTAssertEqual(column.width, width)
        let back = try fixture.frame(token)
        XCTAssertEqual(back.width, before.width, accuracy: 1)
        XCTAssertEqual(back.midX, before.midX, accuracy: 1)
    }

    func testEachTitleBarDoubleClickIsOneUndoStep() throws {
        let fixture = try makeFixture(pid: 941_090)
        let token = fixture.tokens[1]
        let column = try fixture.column(token)
        try keepEdgeResize(of: token, in: fixture)
        let resized = column.width

        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
        XCTAssertEqual(column.width, resized)

        let history = fixture.controller.niriLayoutHandler
        XCTAssertTrue(history.stepLayoutHistory(.undo))
        XCTAssertEqual(column.width, .proportion(1))
        XCTAssertTrue(history.stepLayoutHistory(.undo))
        XCTAssertEqual(column.width, resized)
    }

    func testAWidthChangedAtFullWidthStartsAgainFromFullWidth() throws {
        let fixture = try makeFixture(pid: 941_120)
        let token = fixture.tokens[1]
        let column = try fixture.column(token)
        let width = column.width
        try fixture.select(token)

        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
        fixture.controller.niriLayoutHandler.cycleSize(forward: true)
        let changed = column.width
        XCTAssertNotEqual(changed, .proportion(1))

        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
        XCTAssertEqual(column.width, .proportion(1))
        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
        XCTAssertEqual(column.width, changed)
        XCTAssertNotEqual(column.width, width)
    }

    func testAtFullWidthWithNothingToGoBackToADoubleClickChangesNothing() throws {
        let fixture = try makeFixture(pid: 941_121)
        let token = fixture.tokens[1]
        let column = try fixture.column(token)
        let handle = try XCTUnwrap(fixture.controller.workspaceManager.handle(for: token))
        XCTAssertTrue(fixture.controller.niriLayoutHandler.toggleContainerFullPrimarySpan(target: .window(handle)))
        fixture.relayout()
        let width = column.width
        let frame = try fixture.frame(token)

        fixture.doubleClick(at: try fixture.titleBar(token))

        XCTAssertTrue(column.isFullWidth)
        XCTAssertEqual(column.width, width)
        XCTAssertEqual(try fixture.frame(token).width, frame.width, accuracy: 1)
    }

    func testAStackGoesToFullWidthAsAWholeColumn() throws {
        let fixture = try makeFixture(pid: 941_122, stackFirstTwo: true)
        let sides = fixture.screenSides

        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(fixture.tokens[1])))

        for token in fixture.tokens[0 ..< 2] {
            XCTAssertEqual(try fixture.frame(token).width, sides.right - sides.left, accuracy: 1)
        }
    }

    func testTheCycleSizeKeysOnlyCycleAfterAKeptEdgeResize() throws {
        for forward in [true, false] {
            let fixture = try makeFixture(pid: forward ? 941_127 : 941_128)
            let token = fixture.tokens[1]
            let column = try fixture.column(token)
            try keepEdgeResize(of: token, in: fixture)
            let resized = column.width
            try fixture.select(token)

            fixture.controller.niriLayoutHandler.cycleSize(forward: forward)
            XCTAssertNotEqual(column.width, resized, "\(forward)")
        }
    }

    func testATitleBarDoubleClickChangesOnlyTheClickedWindow() throws {
        let fixture = try makeFixture(pid: 941_091)
        let (resized, clicked) = (fixture.tokens[1], fixture.tokens[2])
        try keepEdgeResize(of: resized, in: fixture)
        let resizedWidth = try fixture.column(resized).width
        let clickedWidth = try fixture.column(clicked).width

        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(clicked)))

        XCTAssertNotEqual(try fixture.column(clicked).width, clickedWidth)
        XCTAssertEqual(try fixture.column(resized).width, resizedWidth)
    }

    func testATitleBarDoubleClickOnTheLastColumnShowsItWhole() throws {
        let fixture = try makeFixture(pid: 941_041)
        let last = fixture.tokens[2]
        let sides = fixture.screenSides
        let before = try fixture.frame(last)

        for step in 0 ..< 2 {
            XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(last)))
            let frame = try fixture.frame(last)
            XCTAssertGreaterThanOrEqual(frame.minX, sides.left - 1, "\(step)")
            XCTAssertLessThanOrEqual(frame.maxX, sides.right + 1, "\(step)")
        }
        XCTAssertEqual(try fixture.frame(last).width, before.width, accuracy: 1)
    }

    func testATitleBarDoubleClickKeepsAnAlwaysCentredColumnCentred() throws {
        let fixture = try makeFixture(pid: 941_042)
        let current = fixture.engine.effectiveSettings(in: fixture.workspaceId)
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.workspaceId) {
            fixture.engine.updateMonitorSettings(
                ResolvedNiriSettings(
                    visibleContainerCount: current.visibleContainerCount,
                    defaultContainerPrimarySpan: current.defaultContainerPrimarySpan,
                    centerFocusedColumn: .always,
                    alwaysCenterSingleColumn: current.alwaysCenterSingleColumn,
                    singleWindowFit: current.singleWindowFit,
                    infiniteLoop: current.infiniteLoop
                ),
                for: fixture.monitor.id
            )
        }
        let state = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        let token = try XCTUnwrap(fixture.tokens.first { token in
            (try? fixture.engine.isViewportAnchor(fixture.column(token), in: fixture.workspaceId, state: state)) == true
        })
        let middle = (fixture.screenSides.left + fixture.screenSides.right) / 2

        for step in 0 ..< 2 {
            XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
            XCTAssertEqual(try fixture.frame(token).midX, middle, accuracy: 1, "\(step)")
        }
    }

    func testAShiftDoubleClickOnTheTitleBarIsLeftToTheApp() throws {
        let fixture = try makeFixture(pid: 941_140)
        fixture.handler.titleBarHitProvider = { _, _ in TitleBarHit(role: "AXWindow") }
        let token = fixture.tokens[1]
        let column = try fixture.column(token)
        let width = column.width

        XCTAssertFalse(fixture.doubleClick(at: try fixture.titleBar(token), modifiers: .maskShift))
        XCTAssertFalse(fixture.doubleClick(at: try fixture.titleBar(token), modifiers: [.maskShift, .maskCommand]))
        XCTAssertEqual(column.width, width)
    }

    func testClicksRightAfterATitleBarDoubleClickReachTheApp() throws {
        let fixture = try makeFixture(pid: 941_141)
        let column = try fixture.column(fixture.tokens[1])
        let point = try fixture.titleBar(fixture.tokens[1])

        XCTAssertTrue(fixture.doubleClick(at: point))
        XCTAssertFalse(fixture.doubleClick(at: point, clickCount: 1))
        XCTAssertFalse(fixture.doubleClick(at: point, clickCount: 3))
        XCTAssertEqual(column.width, .proportion(1))
    }

    func testAModifierTitleBarPressPassesOnAsARegularDragWithItsModifier() throws {
        let fixture = try makeFixture(pid: 941_132)
        MouseEventHandler._instance = fixture.handler
        addTeardownBlock { @MainActor in MouseEventHandler._instance = nil }
        fixture.handler.syncTapFilterSnapshot()
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        let tap = fixture.handler.inputTapThread
        let titleBar = try fixture.titleBar(fixture.tokens[1])
        for modifier in [CGEventFlags.maskAlternate, .maskCommand, .maskControl, .maskShift] {
            let event = { (type: CGEventType, point: CGPoint) in
                let event = try XCTUnwrap(CGEvent(
                    mouseEventSource: nil,
                    mouseType: type,
                    mouseCursorPosition: ScreenCoordinateSpace.toWindowServer(point: point),
                    mouseButton: .left
                ))
                event.flags = modifier
                return event
            }
            let pressed = tap.evaluateTap(type: .leftMouseDown, event: try event(.leftMouseDown, titleBar))
            let dragged = tap.evaluateTap(
                type: .leftMouseDragged,
                event: try event(.leftMouseDragged, CGPoint(x: titleBar.x + 40, y: titleBar.y))
            )

            XCTAssertEqual(pressed?.flags.contains(modifier), true, "\(modifier)")
            XCTAssertNotNil(dragged, "\(modifier)")
            XCTAssertFalse(fixture.handler.state.isMoving, "\(modifier)")
            fixture.handler.cancelActiveMouseInteraction()
        }
    }

    func testOnALandscapeStripTheCycleSizeKeysResizeAroundTheCentre() throws {
        let fixture = try makeFixture(pid: 941_123)
        let token = fixture.tokens[1]
        let sides = fixture.screenSides
        try fixture.select(token)

        for forward in [true, true, false] {
            let before = try fixture.frame(token)
            fixture.controller.niriLayoutHandler.cycleSize(forward: forward)
            fixture.relayout()
            let after = try fixture.frame(token)

            XCTAssertNotEqual(after.width, before.width, accuracy: 1, "\(forward)")
            let leading = try after.minX - fixture.frame(fixture.tokens[0]).minX
            let trailing = try fixture.frame(fixture.tokens[2]).maxX - after.minX
            var expected = min(max(before.midX - after.width / 2, sides.left), sides.right - after.width)
            if leading + trailing >= sides.right - sides.left - 1 {
                expected = min(max(expected, sides.right - trailing), sides.left + leading)
            }
            XCTAssertEqual(after.minX, expected, accuracy: 1, "\(forward)")
        }
    }

    func testOnAPortraitStripTheCycleSizeKeysResizeAroundTheCentre() throws {
        let fixture = try makeFixture(pid: 941_124, portrait: true)
        let token = fixture.tokens[1]
        try fixture.select(token)
        let sides = fixture.primarySides
        for forward in [true, true, false] {
            let before = try fixture.primaryRange(token)
            fixture.controller.niriLayoutHandler.cycleSize(forward: forward)
            fixture.relayout()
            let after = try fixture.primaryRange(token)
            let span = after.upperBound - after.lowerBound
            XCTAssertNotEqual(span, before.upperBound - before.lowerBound, accuracy: fixture.tolerance)
            let leading = try after.lowerBound - fixture.primaryRange(fixture.tokens[0]).lowerBound
            let trailing = try fixture.primaryRange(fixture.tokens[2]).upperBound - after.lowerBound
            let center = (before.lowerBound + before.upperBound) / 2
            var expected = min(max(center - span / 2, sides.lowerBound), sides.upperBound - span)
            if leading + trailing >= sides.upperBound - sides.lowerBound - fixture.tolerance {
                expected = min(max(expected, sides.upperBound - trailing), sides.lowerBound + leading)
            }
            XCTAssertEqual(after.lowerBound, expected, accuracy: fixture.tolerance)
        }
    }

    func testAWidthApartFromThePresetsGoesToTheNextPresetAndIsNotComeBackTo() throws {
        let fixture = try makeFixture(pid: 941_130)
        fixture.engine.presetContainerPrimarySpans = [.proportion(1.0 / 3.0), .proportion(0.5), .proportion(2.0 / 3.0)]
        let token = fixture.tokens[1]
        let column = try fixture.column(token)
        column.width = .proportion(0.4)
        column.cachedWidth = 0
        fixture.relayout()
        try fixture.select(token)

        var widths: [CGFloat] = []
        for _ in 0 ..< 4 {
            pressCycleSizeForward(in: fixture)
            guard case let .proportion(width) = column.width else { return XCTFail("\(column.width)") }
            widths.append(width)
        }

        for (width, expected) in zip(widths, [0.5, 2.0 / 3.0, 1.0 / 3.0, 0.5]) {
            XCTAssertEqual(width, expected, accuracy: 0.001)
        }
    }

    func testScrollingTheStripBetweenStepsStartsANewCycleWhereTheWindowIs() throws {
        let fixture = try makeFixture(pid: 941_136)
        let token = fixture.tokens[1]
        try fixture.select(token)
        pressCycleSizeForward(in: fixture)
        fixture.controller.workspaceManager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.jumpOffset(to: state.viewOffset + 100)
        }
        fixture.relayout()
        let moved = try fixture.frame(token)

        pressCycleSizeForward(in: fixture)

        let after = try fixture.frame(token)
        XCTAssertNotEqual(after.width, moved.width, accuracy: 1)
        XCTAssertEqual(after.midX, moved.midX, accuracy: 1)
    }

    func testAFullLoopFromAPresetCyclesThePresetsOnly() throws {
        let fixture = try makeFixture(pid: 941_132)
        let token = fixture.tokens[1]
        try fixture.select(token)
        let presets = fixture.engine.presetContainerPrimarySpans.count
        for _ in 0 ..< presets {
            pressCycleSizeForward(in: fixture)
        }
        let start = try fixture.frame(token)

        for _ in 0 ..< presets {
            pressCycleSizeForward(in: fixture)
        }

        let end = try fixture.frame(token)
        XCTAssertEqual(end.width, start.width, accuracy: 1)
        XCTAssertEqual(end.minX, start.minX, accuracy: 1)
    }

    func testTheCycleSizeKeysGoRoundTheSameLoopBothWays() throws {
        let fixture = try makeFixture(pid: 941_133)
        let token = fixture.tokens[1]
        let column = try fixture.column(token)
        column.width = .proportion(0.5)
        column.cachedWidth = 0
        fixture.relayout()
        try fixture.select(token)
        let start = try fixture.frame(token)
        let stops = fixture.engine.presetContainerPrimarySpans.count

        for forward in [true, false] {
            var widths: [ProportionalSize] = []
            for _ in 0 ..< stops {
                fixture.controller.niriLayoutHandler.cycleSize(forward: forward)
                fixture.relayout()
                widths.append(column.width)
            }
            XCTAssertEqual(Set(widths.map { "\($0)" }).count, stops, "\(forward)")
            XCTAssertEqual(column.width, .proportion(0.5), "\(forward)")
            XCTAssertEqual(try fixture.frame(token).minX, start.minX, accuracy: 1, "\(forward)")
        }
    }

    func testTheCycleSizeKeysFollowThePresetsInTheUsersOrder() throws {
        let fixture = try makeFixture(pid: 941_134)
        let presets: [CGFloat] = [2.0 / 3.0, 0.5, 1.0 / 3.0]
        fixture.engine.presetContainerPrimarySpans = presets.map { .proportion($0) }
        let token = fixture.tokens[1]
        let column = try fixture.column(token)
        column.width = .proportion(presets[0])
        column.presetWidthIdx = 0
        column.cachedWidth = 0
        fixture.relayout()
        try fixture.select(token)

        fixture.controller.niriLayoutHandler.cycleSize(forward: true)
        fixture.relayout()

        XCTAssertEqual(column.width, .proportion(presets[1]))
    }

    func testBackwardsAWidthApartFromThePresetsGoesToTheWidestNarrowerPreset() throws {
        let fixture = try makeFixture(pid: 941_139)
        fixture.engine.presetContainerPrimarySpans = [.proportion(1.0 / 3.0), .proportion(0.5), .proportion(2.0 / 3.0)]
        let token = fixture.tokens[1]
        let column = try fixture.column(token)
        column.width = .proportion(0.4)
        column.cachedWidth = 0
        fixture.relayout()
        try fixture.select(token)

        fixture.controller.niriLayoutHandler.cycleSize(forward: false)
        fixture.relayout()

        guard case let .proportion(width) = column.width else { return XCTFail("\(column.width)") }
        XCTAssertEqual(width, 1.0 / 3.0, accuracy: 0.001)
    }

    func testAWidthCloseToAPresetCountsAsThatPresetBothWays() throws {
        for (forward, expected) in [(true, [1.0 / 3.0, 2.0 / 3.0, 0.5]), (false, [2.0 / 3.0, 1.0 / 3.0, 0.5])] {
            let fixture = try makeFixture(pid: forward ? 941_137 : 941_138)
            fixture.engine.presetContainerPrimarySpans = [
                .proportion(0.5),
                .proportion(1.0 / 3.0),
                .proportion(2.0 / 3.0)
            ]
            let token = fixture.tokens[1]
            let column = try fixture.column(token)
            column.width = .proportion(0.49)
            column.cachedWidth = 0
            fixture.relayout()
            try fixture.select(token)

            var widths: [CGFloat] = []
            for _ in 0 ..< 3 {
                fixture.controller.niriLayoutHandler.cycleSize(forward: forward)
                fixture.relayout()
                guard case let .proportion(width) = column.width else { return XCTFail("\(column.width)") }
                widths.append(width)
            }

            for (width, wanted) in zip(widths, expected) {
                XCTAssertEqual(width, wanted, accuracy: 0.001, "\(forward)")
            }
        }
    }

    func testAnEdgeDoubleClickOnAWindowCoveringTheEdgeIsLeftToThatWindow() throws {
        let fixture = try makeFixture(pid: 941_031)
        let column = try fixture.column(fixture.tokens[1])
        let width = column.width
        let edge = try fixture.rightEdge(fixture.tokens[1])

        fixture.handler.topmostWindowIdProvider = { _ in 999_999 }
        XCTAssertFalse(fixture.doubleClick(at: edge))
        XCTAssertEqual(column.width, width)

        fixture.handler.topmostWindowIdProvider = { _ in fixture.tokens[1].windowId }
        XCTAssertTrue(fixture.doubleClick(at: edge))
        XCTAssertNotEqual(column.width, width)
    }

    func testAFloatingPanelOverAnEdgeIsTheWindowOnTopButTheDockAndMenuBarAreNot() {
        func window(
            _ id: Int,
            layer: Int,
            pid: pid_t = 500,
            alpha: Double = 1,
            frame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 400)
        ) -> [String: Any] {
            [
                kCGWindowNumber as String: id,
                kCGWindowOwnerPID as String: pid,
                kCGWindowLayer as String: layer,
                kCGWindowAlpha as String: alpha,
                kCGWindowBounds as String: frame.dictionaryRepresentation
            ]
        }
        let point = CGPoint(x: 100, y: 100)
        let tiled = window(1, layer: 0)
        let topmost = { (windows: [[String: Any]]) in
            MouseEventHandler.topmostWindowId(in: windows, at: point, ownPid: 99)
        }

        XCTAssertEqual(topmost([window(2, layer: 3), tiled]), 2)
        XCTAssertEqual(topmost([window(3, layer: 8), tiled]), 3)
        XCTAssertEqual(topmost([window(4, layer: 20), window(5, layer: 24), window(6, layer: 25), tiled]), 1)
        XCTAssertEqual(topmost([window(7, layer: 3, pid: 99), window(8, layer: 3, alpha: 0), tiled]), 1)
        XCTAssertNil(topmost([window(9, layer: 3, frame: CGRect(x: 500, y: 500, width: 10, height: 10))]))
    }

    func testATitleBarDoubleClickOnAControlIsLeftToTheApp() throws {
        let fixture = try makeFixture(pid: 941_008)
        let column = try fixture.column(fixture.tokens[1])
        let width = column.width

        for role in ["AXTextField", "AXButton"] {
            fixture.handler.titleBarHitProvider = { _, _ in TitleBarHit(
                role: role,
                placement: .insideBar(elementWithinBar: true)
            ) }
            XCTAssertFalse(fixture.doubleClick(at: try fixture.titleBar(fixture.tokens[1])), role)
        }
        fixture.handler.titleBarHitProvider = { _, _ in TitleBarHit(role: "AXWebArea") }
        XCTAssertFalse(fixture.doubleClick(at: try fixture.titleBar(fixture.tokens[1])))
        fixture.handler.titleBarHitProvider = { _, _ in nil }
        XCTAssertFalse(fixture.doubleClick(at: try fixture.titleBar(fixture.tokens[1])))

        XCTAssertEqual(column.width, width)
    }

    func testATitleBarDoubleClickOverContentUnderTheBarMovesTheColumn() throws {
        let fixture = try makeFixture(pid: 941_017)
        let column = try fixture.column(fixture.tokens[1])
        var width = column.width

        for role in ["AXScrollArea", "AXTextArea"] {
            fixture.handler.titleBarHitProvider = { _, _ in
                TitleBarHit(role: role, placement: .insideBar(elementWithinBar: false))
            }
            XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(fixture.tokens[1])), role)
            XCTAssertNotEqual(column.width, width, role)
            width = column.width
        }
    }

    func testADoubleClickTargetsTheWindowUnderThePointerNotTheFocusedOne() throws {
        let fixture = try makeFixture(pid: 941_009)
        let focused = try fixture.column(fixture.tokens[0])
        let clicked = try fixture.column(fixture.tokens[2])
        let focusedWidth = focused.width
        let clickedWidth = clicked.width
        fixture.controller.workspaceManager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.selectedNodeId = try? fixture.window(fixture.tokens[0]).id
        }

        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(fixture.tokens[2])))

        XCTAssertEqual(focused.width, focusedWidth)
        XCTAssertNotEqual(clicked.width, clickedWidth)
    }

    func testAHandledDoubleClickAndItsReleaseDontReachTheApp() throws {
        let fixture = try makeFixture(pid: 941_012)
        let point = try fixture.titleBar(fixture.tokens[1])

        XCTAssertTrue(fixture.handler.dispatchAuthoritativeTap(
            type: .leftMouseDown, location: point, modifiers: [], buttonNumber: 0, scrollPayload: nil, clickCount: 2
        ))
        XCTAssertEqual(fixture.handler.tapInputs.capturedInteractionButton, .left)
        XCTAssertEqual(fixture.handler.inputTapThread.filterSnapshot.activeCapture, .left)
        XCTAssertTrue(fixture.handler.dispatchAuthoritativeTap(
            type: .leftMouseDragged, location: point, modifiers: [], buttonNumber: 0, scrollPayload: nil
        ))
        XCTAssertTrue(fixture.handler.dispatchAuthoritativeTap(
            type: .leftMouseUp, location: point, modifiers: [], buttonNumber: 0, scrollPayload: nil
        ))
        XCTAssertNil(fixture.handler.tapInputs.capturedInteractionButton)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
    }

    func testAnUnhandledDoubleClickReachesTheApp() throws {
        let fixture = try makeFixture(pid: 941_010)
        let column = try fixture.column(fixture.tokens[1])
        let width = column.width
        let frame = try fixture.frame(fixture.tokens[1])

        XCTAssertFalse(fixture.doubleClick(at: CGPoint(x: frame.midX, y: frame.midY)))
        XCTAssertFalse(fixture.doubleClick(at: CGPoint(x: frame.maxX - 1, y: frame.maxY - 1)))
        XCTAssertFalse(fixture.doubleClick(at: try fixture.titleBar(fixture.tokens[1]), modifiers: .maskCommand))
        XCTAssertFalse(fixture.doubleClick(at: try fixture.titleBar(fixture.tokens[1]), clickCount: 1))
        XCTAssertFalse(fixture.doubleClick(at: try fixture.titleBar(fixture.tokens[1]), clickCount: 3))

        XCTAssertEqual(column.width, width)
    }

    func testDoubleClicksAreIgnoredInDwindle() throws {
        let fixture = try makeFixture(pid: 941_011)
        let column = try fixture.column(fixture.tokens[1])
        let width = column.width
        fixture.controller.settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: fixture.monitor)),
                layoutType: .dwindle
            )
        ]
        fixture.controller.workspaceManager.applySettings()
        XCTAssertEqual(fixture.controller.workspaceManager.activeLayoutKind(for: fixture.workspaceId), .dwindle)
        XCTAssertFalse(fixture.doubleClick(at: try fixture.titleBar(fixture.tokens[1])))

        XCTAssertEqual(column.width, width)
    }

    func testPortraitTitleBarExpandsHeightAndRestoresItsSizeCenterAndUndoStep() throws {
        let display = CGRect(x: -380, y: 210, width: 900, height: 1600)
        let fixture = try makeFixture(pid: 941_201, portrait: true, frame: display)
        let token = fixture.tokens[1]
        let column = try fixture.column(token)
        try fixture.settleStripStart()
        let before = try fixture.primaryRange(token)
        let specification = column.height
        let manual = column.hasManualSingleWindowHeightOverride
        let width = column.width
        let sides = fixture.primarySides

        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
        XCTAssertEqual(column.height, .proportion(1))
        let expanded = try fixture.primaryRange(token)
        XCTAssertEqual(expanded.lowerBound, sides.lowerBound, accuracy: fixture.tolerance)
        XCTAssertEqual(expanded.upperBound, sides.upperBound, accuracy: fixture.tolerance)
        XCTAssertEqual(column.width, width)

        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
        XCTAssertEqual(column.height, specification)
        XCTAssertEqual(column.hasManualSingleWindowHeightOverride, manual)
        let restored = try fixture.primaryRange(token)
        XCTAssertEqual(restored.lowerBound, before.lowerBound, accuracy: fixture.tolerance)
        XCTAssertEqual(restored.upperBound, before.upperBound, accuracy: fixture.tolerance)
        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo))
        XCTAssertEqual(column.height, .proportion(1))
        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo))
        XCTAssertEqual(column.height, specification)
    }

    func testPortraitPrimaryEdgesReachTheScreenAndRestoreTheOppositeEdge() throws {
        for (index, trailing) in [false, true].enumerated() {
            let fixture = try makeFixture(pid: pid_t(941_210 + index), portrait: true)
            let token = fixture.tokens[1]
            try fixture.settleStripStart()
            let before = try fixture.primaryRange(token)
            let column = try fixture.column(token)
            let specification = column.height
            let width = column.width
            XCTAssertTrue(fixture.doubleClick(at: try fixture.primaryEdge(token, trailing: trailing)))
            let stretched = try fixture.primaryRange(token)
            XCTAssertEqual(
                trailing ? stretched.upperBound : stretched.lowerBound,
                trailing ? fixture.primarySides.upperBound : fixture.primarySides.lowerBound,
                accuracy: fixture.tolerance
            )
            XCTAssertEqual(
                trailing ? stretched.lowerBound : stretched.upperBound,
                trailing ? before.lowerBound : before.upperBound,
                accuracy: fixture.tolerance
            )
            XCTAssertEqual(column.width, width)
            XCTAssertFalse(column.isFullHeight)
            XCTAssertTrue(fixture.doubleClick(at: try fixture.primaryEdge(token, trailing: trailing)))
            let restored = try fixture.primaryRange(token)
            XCTAssertEqual(restored.lowerBound, before.lowerBound, accuracy: fixture.tolerance)
            XCTAssertEqual(restored.upperBound, before.upperBound, accuracy: fixture.tolerance)
            XCTAssertEqual(column.height, specification)
        }
    }

    func testPortraitEdgeExpansionRespectsTheMaximumHeight() throws {
        let fixture = try makeFixture(pid: 941_224, portrait: true)
        let token = fixture.tokens[1]
        let window = try fixture.window(token)
        let column = try fixture.column(token)
        let before = try fixture.primaryRange(token)
        let original = column.height
        let gap = fixture.controller.innerGap(for: fixture.monitor)
        let maximum = before.upperBound - before.lowerBound + gap
        window.constraints.maxSize.height = maximum
        XCTAssertTrue(fixture.doubleClick(at: try fixture.topEdge(token)))
        XCTAssertEqual(column.settledHeight, maximum, accuracy: fixture.tolerance)
        XCTAssertTrue(fixture.doubleClick(at: try fixture.topEdge(token)))
        XCTAssertEqual(column.height, original)
    }

    func testPortraitObservedHeightPackingStillRestoresTheEarlierHeight() throws {
        let fixture = try makeFixture(pid: 941_225, portrait: true)
        let token = fixture.tokens[1]
        let column = try fixture.column(token)
        let original = column.height
        let before = try fixture.primaryRange(token)
        let reach = fixture.primarySides.upperBound - before.lowerBound
        let gap = fixture.controller.innerGap(for: fixture.monitor)
        try fixture.window(token).packingHints = ObservedPackingHints(
            height: ObservedAxisHint(requested: reach - fixture.tolerance, observed: reach + gap)
        )
        XCTAssertTrue(fixture.doubleClick(at: try fixture.topEdge(token)))
        let stretched = try fixture.primaryRange(token)
        XCTAssertEqual(stretched.upperBound - stretched.lowerBound, reach + gap, accuracy: fixture.tolerance)
        XCTAssertEqual(stretched.upperBound, fixture.primarySides.upperBound, accuracy: fixture.tolerance)
        XCTAssertTrue(fixture.doubleClick(at: try fixture.topEdge(token)))
        let restored = try fixture.primaryRange(token)
        XCTAssertEqual(restored.lowerBound, before.lowerBound, accuracy: fixture.tolerance)
        XCTAssertEqual(restored.upperBound, before.upperBound, accuracy: fixture.tolerance)
        XCTAssertEqual(column.height, original)
    }

    func testPortraitTitleBarKeepsAnAlwaysCenteredColumnCentered() throws {
        let fixture = try makeFixture(pid: 941_226, portrait: true)
        let current = fixture.engine.effectiveSettings(in: fixture.workspaceId)
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.workspaceId) {
            fixture.engine.updateMonitorSettings(
                ResolvedNiriSettings(
                    visibleContainerCount: current.visibleContainerCount,
                    defaultContainerPrimarySpan: current.defaultContainerPrimarySpan,
                    centerFocusedColumn: .always,
                    alwaysCenterSingleColumn: current.alwaysCenterSingleColumn,
                    singleWindowFit: current.singleWindowFit,
                    infiniteLoop: current.infiniteLoop
                ),
                for: fixture.monitor.id
            )
        }
        let token = fixture.tokens[1]
        try fixture.select(token)
        let column = try fixture.column(token)
        let original = column.height
        let middle = (fixture.primarySides.lowerBound + fixture.primarySides.upperBound) / 2
        for specification in [ProportionalSize.proportion(1), original] {
            XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
            let span = try fixture.primaryRange(token)
            XCTAssertEqual((span.lowerBound + span.upperBound) / 2, middle, accuracy: fixture.tolerance)
            XCTAssertEqual(column.height, specification)
        }
    }

    func testPortraitSecondaryEdgesToggleTabsAndProtectedHitRegionsPassThrough() throws {
        let fixture = try makeFixture(pid: 941_220, stackFirstTwo: true, portrait: true)
        let token = fixture.tokens[1]
        let column = try fixture.column(token)
        let height = column.height
        XCTAssertTrue(fixture.doubleClick(at: try fixture.leftEdge(token)))
        XCTAssertTrue(column.isTabbed)
        XCTAssertTrue(fixture.engine
            .projectedActiveWindow(in: column, workspaceId: fixture.workspaceId) === (try fixture.window(token)))
        XCTAssertTrue(fixture.doubleClick(at: try fixture.rightEdge(token)))
        XCTAssertFalse(column.isTabbed)
        XCTAssertFalse(fixture.doubleClick(at: try fixture.titleBar(token), modifiers: .maskShift))
        let frame = try fixture.frame(token)
        XCTAssertFalse(fixture.doubleClick(at: CGPoint(x: frame.midX, y: frame.midY)))
        let inset = NiriLayoutEngine.doubleClickEdgeInset / 2
        XCTAssertFalse(fixture.doubleClick(at: CGPoint(x: frame.maxX - inset, y: frame.maxY - inset)))
        fixture.handler.titleBarHitProvider = { _, _ in TitleBarHit(role: "AXButton") }
        XCTAssertFalse(fixture.doubleClick(at: try fixture.titleBar(token)))
        fixture.handler.topmostWindowIdProvider = { _ in token.windowId + 1 }
        XCTAssertFalse(fixture.doubleClick(at: try fixture.topEdge(token)))
        XCTAssertEqual(column.height, height)
        XCTAssertNil(fixture.handler.inputTapThread.filterSnapshot.fusionDoubleClickArmedAt)
    }

    func testPortraitTabEdgesPreserveUnequalWidthsAndEachToggleHasOneUndo() throws {
        for (index, trailing) in [false, true].enumerated() {
            let fixture = try makeFixture(pid: pid_t(941_240 + index), stackFirstTwo: true, portrait: true)
            let token = fixture.tokens[1]
            let column = try fixture.column(token)
            let windows = try fixture.tokens[0 ..< 2].map { try fixture.window($0) }
            let total = try fixture.tokens[0 ..< 2].reduce(CGFloat.zero) { try $0 + fixture.frame($1).width }
            windows[0].windowWidth = .fixed(total / 3)
            windows[1].windowWidth = .fixed(total * 2 / 3)
            fixture.relayout()
            let frames = try fixture.tokens[0 ..< 2].map { try fixture.frame($0) }
            let widths = windows.map(\.windowWidth)
            XCTAssertTrue(fixture.doubleClick(at: try fixture.secondaryEdge(token, trailing: trailing)))
            XCTAssertTrue(column.isTabbed)
            XCTAssertTrue(fixture.engine
                .projectedActiveWindow(in: column, workspaceId: fixture.workspaceId) === windows[1])
            XCTAssertEqual(windows.map(\.windowWidth), widths)
            XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo))
            fixture.relayout()
            XCTAssertFalse(column.isTabbed)
            XCTAssertEqual(windows.map(\.windowWidth), widths)
            XCTAssertEqual(try fixture.tokens[0 ..< 2].map { try fixture.frame($0) }, frames)
            XCTAssertFalse(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo))
            XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.redo))
            fixture.relayout()
            XCTAssertTrue(column.isTabbed)
            XCTAssertTrue(fixture.doubleClick(at: try fixture.secondaryEdge(token, trailing: trailing)))
            XCTAssertFalse(column.isTabbed)
            XCTAssertEqual(windows.map(\.windowWidth), widths)
            XCTAssertEqual(try fixture.tokens[0 ..< 2].map { try fixture.frame($0) }, frames)
        }
    }

    func testPortraitTitleBarRespectsThePeekAndHeightConstraints() throws {
        let fixture = try makeFixture(pid: 941_221, portrait: true)
        let token = fixture.tokens[1]
        let column = try fixture.column(token)
        let width = column.width
        let percent: Double = 5
        fixture.controller.settings.niri.edgePeekPercent = percent
        fixture.controller.updateNiriConfig(edgePeekShare: fixture.controller.edgePeekShare)
        try fixture.select(token)
        let gap = fixture.controller.innerGap(for: fixture.monitor)
        let peek = fixture.monitor.frame.height * CGFloat(percent) / 100
        let cap = fixture.monitor.frame.height - 2 * (peek + gap)
        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
        XCTAssertEqual(column.settledHeight, cap, accuracy: fixture.tolerance)
        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
        let minimum = cap + gap
        let window = try fixture.window(token)
        window.constraints.minSize.height = minimum
        column.invalidateCachedPrimarySpan(orientation: .vertical)
        fixture.relayout()
        try fixture.select(token)
        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
        XCTAssertGreaterThanOrEqual(column.settledHeight, minimum)
        XCTAssertEqual(column.width, width)
    }

    func testPortraitCycleUsesItsPresetsAndReturnsThroughThemInReverse() throws {
        let fixture = try makeFixture(pid: 941_222, portrait: true)
        let token = fixture.tokens[1]
        let column = try fixture.column(token)
        let width = column.width
        let presets: [CGFloat] = [1.0 / 3.0, 0.5, 2.0 / 3.0]
        fixture.engine.presetContainerPrimarySpans = presets.map { .proportion(Double($0)) }
        let expectedSpecs = fixture.engine.presetContainerPrimarySpans.map {
            NiriSizeChange($0).primarySpanSpec(
                currentPixels: column.settledHeight,
                axisSpan: fixture.controller.insetWorkingFrame(for: fixture.monitor).height,
                gaps: fixture.controller.innerGap(for: fixture.monitor)
            )
        }
        column.height = .proportion((presets[0] + presets[1]) / 2)
        column.invalidateCachedPrimarySpan(orientation: .vertical)
        fixture.relayout()
        try fixture.select(token)
        for expected in [expectedSpecs[1], expectedSpecs[2], expectedSpecs[0]] {
            fixture.controller.niriLayoutHandler.cycleSize(forward: true)
            fixture.relayout()
            XCTAssertEqual(column.height, expected)
        }
        for expected in [expectedSpecs[2], expectedSpecs[1], expectedSpecs[0]] {
            fixture.controller.niriLayoutHandler.cycleSize(forward: false)
            fixture.relayout()
            XCTAssertEqual(column.height, expected)
        }
        XCTAssertEqual(column.width, width)
    }

    func testRotationCannotUseAWidthRestoreAsAHeightRestore() throws {
        let fixture = try makeFixture(pid: 941_223)
        let token = fixture.tokens[1]
        let column = try fixture.column(token)
        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
        let before = try XCTUnwrap(column.spanBeforeFull)
        XCTAssertEqual(before.orientation, .horizontal)
        fixture.controller.settings.monitors.updateOrientationSettings(
            MonitorOrientationSettings(
                monitorName: fixture.monitor.name, monitorDisplayId: fixture.monitor.displayId, orientation: .vertical
            ),
            for: fixture.monitor
        )
        column.height = .proportion(1)
        column.invalidateCachedPrimarySpan(orientation: .vertical)
        fixture.relayout()
        try fixture.select(token)
        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
        XCTAssertEqual(column.height, .proportion(1))
        XCTAssertEqual(column.spanBeforeFull, before)
    }

    private func pressCycleSizeForward(in fixture: Fixture) {
        fixture.controller.niriLayoutHandler.cycleSize(forward: true)
        fixture.relayout()
    }

    private func keepEdgeResize(of token: WindowToken, in fixture: Fixture) throws {
        let start = try XCTUnwrap(fixture.controller.niriLayoutHandler.layoutChangeStart(in: fixture.workspaceId))
        let column = try fixture.column(token)
        column.width = .fixed(700)
        column.presetWidthIdx = nil
        column.hasManualSingleWindowWidthOverride = true
        column.cachedWidth = 0
        fixture.controller.niriLayoutHandler.recordLayoutChange(since: start)
        fixture.relayout()
    }

    func testARightEdgeStretchFromACentredRowStillReachesThePeek() async throws {
        for keepsStripEnds in [false, true] {
            try await checkARightEdgeStretchFromACentredRow(keepsStripEnds: keepsStripEnds)
        }
    }

    private func checkARightEdgeStretchFromACentredRow(keepsStripEnds: Bool) async throws {
        let fixture = try await makeCentredRowFixture(
            pid: keepsStripEnds ? 941_162 : 941_160, keepsStripEnds: keepsStripEnds
        )
        let (first, last) = (fixture.tokens[0], fixture.tokens[1])
        let start = try fixture.frame(first)
        let sides = centredRowSides(fixture)
        XCTAssertGreaterThan(start.minX, sides.left + 100)

        XCTAssertTrue(fixture.doubleClick(at: try fixture.rightEdge(first)))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(try fixture.frame(first).minX, sides.left, accuracy: 1)
        XCTAssertEqual(try fixture.frame(first).maxX, sides.rightPeek, accuracy: 1)
        XCTAssertEqual(try fixture.frame(last).minX, fixture.monitor.frame.maxX - sides.peek, accuracy: 1)

        XCTAssertTrue(fixture.doubleClick(at: try fixture.rightEdge(first)))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(try fixture.frame(first).minX, start.minX, accuracy: 1)
        XCTAssertEqual(try fixture.frame(first).width, start.width, accuracy: 1)
    }

    func testALeftEdgeStretchFromACentredRowStillReachesThePeek() async throws {
        for keepsStripEnds in [false, true] {
            try await checkALeftEdgeStretchFromACentredRow(keepsStripEnds: keepsStripEnds)
        }
    }

    private func checkALeftEdgeStretchFromACentredRow(keepsStripEnds: Bool) async throws {
        let fixture = try await makeCentredRowFixture(
            pid: keepsStripEnds ? 941_163 : 941_161, selecting: 1, keepsStripEnds: keepsStripEnds
        )
        let (first, last) = (fixture.tokens[0], fixture.tokens[1])
        let start = try fixture.frame(last)
        let sides = centredRowSides(fixture)
        XCTAssertLessThan(start.maxX, sides.right - 100)

        XCTAssertTrue(fixture.doubleClick(at: try fixture.leftEdge(last)))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(try fixture.frame(last).maxX, sides.right, accuracy: 1)
        XCTAssertEqual(try fixture.frame(last).minX, sides.leftPeek, accuracy: 1)
        XCTAssertEqual(try fixture.frame(first).maxX, fixture.monitor.frame.minX + sides.peek, accuracy: 1)

        XCTAssertTrue(fixture.doubleClick(at: try fixture.leftEdge(last)))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(try fixture.frame(last).maxX, start.maxX, accuracy: 1)
        XCTAssertEqual(try fixture.frame(last).width, start.width, accuracy: 1)
    }

    private func makeCentredRowFixture(
        pid: pid_t,
        selecting index: Int = 0,
        keepsStripEnds: Bool
    ) async throws -> Fixture {
        let fixture = try makeFixture(pid: pid, windowCount: 2)
        let settings = fixture.controller.settings
        settings.niri.alwaysCenterSingleColumn = true
        settings.niri.centerFocusedColumn = .onOverflow
        settings.niri.edgeGaps = false
        settings.niri.edgePeekPercent = 2
        settings.niri.keepStripEndsOnScreen = keepsStripEnds
        fixture.controller.workspaceManager.applySettings()
        fixture.controller.updateNiriConfig(edgePeekShare: fixture.controller.edgePeekShare)
        fixture.controller.applyNiriStripPolicies()
        try fixture.select(fixture.tokens[index])
        fixture.controller.layoutRefreshController.requestRelayout(reason: .workspaceConfigChanged)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        return fixture
    }

    private func centredRowSides(
        _ fixture: Fixture
    ) -> (left: CGFloat, right: CGFloat, leftPeek: CGFloat, rightPeek: CGFloat, peek: CGFloat) {
        let frame = fixture.controller.niriWorkingFrame(for: fixture.monitor)
        let display = fixture.monitor.frame
        let gap = fixture.controller.innerGap(for: fixture.monitor)
        let peek = fixture.engine.edgePeekSpans(in: fixture.workspaceId)?.trailing ?? 0
        return (frame.minX + gap, frame.maxX - gap, display.minX + peek + gap, display.maxX - peek - gap, peek)
    }

    private func makeFixture(
        pid: pid_t,
        windowCount: Int = 3,
        stackFirstTwo: Bool = false,
        portrait: Bool = false,
        frame: CGRect? = nil
    ) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "FusionDoubleClickTests")
        addTeardownBlock { @MainActor [controller] in
            controller.hasStartedServices = false
            controller.layoutRefreshController.resetState()
            controller.mouseEventHandler.cleanup()
            controller.surfaceReconciler.cleanup()
            controller.axManager.cleanup()
        }
        controller.motionPolicy.animationsEnabled = false
        let displayFrame = frame ?? (portrait
            ? CGRect(x: workingFrame.minX, y: workingFrame.minY, width: workingFrame.height, height: workingFrame.width)
            : workingFrame)
        let monitor = Monitor(
            id: .init(displayId: 94_101),
            displayId: 94_101,
            frame: displayFrame,
            visibleFrame: displayFrame,
            hasNotch: false,
            name: "Fusion Double Click"
        )
        controller.settings.niri.edgePeekPercent = 0
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
                layoutType: .niri
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
        controller.enableNiriLayout()
        controller.updateNiriConfig(edgePeekShare: controller.edgePeekShare)
        let engine = try XCTUnwrap(controller.niriEngine)
        var previous: NiriWindow?
        for (index, token) in tokens.enumerated() {
            if stackFirstTwo, index == 1, let top = previous {
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
                continue
            }
            previous = engine.addWindow(token: token, to: workspaceId, afterSelection: previous?.id)
        }
        for column in engine.columns(in: workspaceId) {
            if portrait {
                column.height = .proportion(1.0 / 3.0)
            } else {
                column.width = .proportion(1.0 / 3.0)
            }
            column.invalidateCachedPrimarySpan(orientation: portrait ? .vertical : .horizontal)
        }
        controller.mouseEventHandler
            .titleBarHitProvider = { _, _ in TitleBarHit(role: "AXWindow") }
        controller.mouseEventHandler.topmostWindowIdProvider = { _ in nil }
        controller.layoutRefreshController.resetState()
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        controller.hasStartedServices = true
        let fixture = Fixture(controller: controller, workspaceId: workspaceId, monitor: monitor, tokens: tokens)
        fixture.relayout()
        return fixture
    }
}
