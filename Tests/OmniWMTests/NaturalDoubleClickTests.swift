// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
private final class ClickClock {
    var now: TimeInterval = 100
}

@MainActor
final class NaturalDoubleClickTests: NiriInteractionTestCase {
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

        func relayout() {
            let gap = controller.innerGap(for: monitor)
            _ = engine.calculateLayoutWithVisibility(
                state: controller.workspaceManager.niriViewportState(for: workspaceId),
                workspaceId: workspaceId,
                monitorFrame: controller.insetWorkingFrame(for: monitor),
                gaps: (horizontal: gap, vertical: gap),
                orientation: .horizontal
            )
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
            XCTAssertNil(handler.state.capturedInteractionButton)
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
            let drift = try frame(tokens[0]).minX - screenSides.left
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
        func zone(_ x: CGFloat, _ y: CGFloat, gap: CGFloat = 16) -> NaturalDoubleClickZone? {
            NiriLayoutEngine.naturalDoubleClickZone(at: CGPoint(x: x, y: y), in: frame, gap: gap, bounds: bounds)
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
            NiriLayoutEngine.naturalDoubleClickZone(at: CGPoint(x: 300, y: 402), in: frame, gap: 6, bounds: open),
            .edge(.top)
        )
        XCTAssertNil(
            NiriLayoutEngine.naturalDoubleClickZone(at: CGPoint(x: 300, y: 404), in: frame, gap: 6, bounds: open)
        )
        XCTAssertNil(
            NiriLayoutEngine.naturalDoubleClickZone(at: CGPoint(x: 300, y: 402), in: frame, gap: 0, bounds: open)
        )
        XCTAssertNil(
            NiriLayoutEngine.naturalDoubleClickZone(
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
        func zone(_ y: CGFloat) -> NaturalDoubleClickZone? {
            NiriLayoutEngine.naturalDoubleClickZone(at: CGPoint(x: 300, y: y), in: frame, gap: 16, bounds: bounds)
        }

        XCTAssertEqual(zone(395), .titleBar)
        XCTAssertEqual(zone(400 - NiriLayoutEngine.doubleClickTitleBarDepth), .titleBar)
        XCTAssertNil(zone(400 - NiriLayoutEngine.doubleClickTitleBarDepth - 1))
        XCTAssertNil(zone(250))
    }

    func testTheTapAsksAboutPlainDoubleClicksOnlyWithNaturalDragOn() {
        let option = CGEventFlags.maskAlternate
        let point = CGPoint(x: 400, y: 300)
        func asks(
            _ clickCount: Int64,
            _ flags: CGEventFlags = [],
            naturalWindowDrag: Bool = true,
            armedAt: CGPoint? = point
        ) -> Bool {
            MouseEventHandler.asksAboutNaturalDoubleClick(
                clickCount: clickCount,
                flags: flags,
                naturalWindowDrag: naturalWindowDrag,
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
        XCTAssertFalse(asks(2, naturalWindowDrag: false))
        XCTAssertFalse(asks(2, armedAt: nil))
        XCTAssertFalse(asks(2, armedAt: CGPoint(x: 420, y: 300)))
        XCTAssertTrue(asks(2, armedAt: CGPoint(x: 404, y: 303)))
    }

    func testAFirstClickOnADoubleClickZoneArmsTheTap() throws {
        let fixture = try makeFixture(pid: 941_027)
        let frame = try fixture.frame(fixture.tokens[1])
        let edge = try fixture.rightEdge(fixture.tokens[1])

        fixture.handler.receiveTapMouseDown(at: edge, modifiers: [], clickCount: 1)
        XCTAssertEqual(fixture.handler.inputTapThread.filterSnapshot.naturalDoubleClickArmedAt, edge)

        fixture.handler.receiveTapMouseDown(at: CGPoint(x: frame.midX, y: frame.midY), modifiers: [], clickCount: 1)
        XCTAssertNil(fixture.handler.inputTapThread.filterSnapshot.naturalDoubleClickArmedAt)

        fixture.handler.receiveTapMouseDown(at: edge, modifiers: .maskAlternate, clickCount: 1)
        XCTAssertNil(fixture.handler.inputTapThread.filterSnapshot.naturalDoubleClickArmedAt)
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

    func testDoubleClickingALoneWindowsTopEdgeGivesItTheFullColumnHeight() throws {
        let fixture = try makeFixture(pid: 941_001)
        let lone = try fixture.window(fixture.tokens[0])
        lone.height = .fixed(400)
        fixture.relayout()

        XCTAssertTrue(fixture.doubleClick(at: try fixture.topEdge(fixture.tokens[0])))

        XCTAssertTrue(lone.height.isAuto)
        XCTAssertEqual(try fixture.frame(fixture.tokens[0]).height, try fixture.frame(fixture.tokens[1]).height)
    }

    func testASecondDoubleClickGivesTheLoneWindowItsHeightBack() throws {
        let fixture = try makeFixture(pid: 941_002)
        let lone = try fixture.window(fixture.tokens[0])
        lone.height = .fixed(400)
        fixture.relayout()

        fixture.doubleClick(at: try fixture.topEdge(fixture.tokens[0]))
        XCTAssertTrue(fixture.doubleClick(at: try fixture.topEdge(fixture.tokens[0])))

        XCTAssertEqual(lone.height, .fixed(400))

        let neverResized = try fixture.window(fixture.tokens[1])
        XCTAssertTrue(fixture.doubleClick(at: try fixture.topEdge(fixture.tokens[1])))
        XCTAssertTrue(neverResized.height.isAuto)
    }

    func testAHeightChangedSinceTheFirstDoubleClickIsntReplaced() throws {
        let fixture = try makeFixture(pid: 941_025)
        let lone = try fixture.window(fixture.tokens[0])
        lone.height = .fixed(400)
        fixture.relayout()

        fixture.doubleClick(at: try fixture.topEdge(fixture.tokens[0]))
        lone.height = .fixed(300)
        let handle = try XCTUnwrap(fixture.controller.workspaceManager.handle(for: fixture.tokens[0]))
        fixture.controller.niriLayoutHandler.resetWindowSecondarySpan(target: .window(handle))
        fixture.relayout()
        XCTAssertTrue(lone.height.isAuto)

        XCTAssertTrue(fixture.doubleClick(at: try fixture.topEdge(fixture.tokens[0])))
        XCTAssertTrue(lone.height.isAuto)
    }

    func testTheBottomEdgeActsLikeTheTopEdge() throws {
        let fixture = try makeFixture(pid: 941_003, stackFirstTwo: true)
        let lone = try fixture.window(fixture.tokens[2])
        lone.height = .fixed(400)
        fixture.relayout()

        XCTAssertTrue(fixture.doubleClick(at: try fixture.bottomEdge(fixture.tokens[2])))
        XCTAssertTrue(lone.height.isAuto)

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
        let fixture = try makeFixture(pid: 941_018, stackFirstTwo: true)
        let column = try fixture.column(fixture.tokens[0])
        let stacked = try fixture.tokens[0 ..< 2].map { try fixture.frame($0) }
        fixture.doubleClick(at: try fixture.topEdge(fixture.tokens[1]))
        XCTAssertTrue(column.isTabbed)
        let tabbed = try fixture.frame(fixture.tokens[1])

        fixture.controller.motionPolicy.animationsEnabled = true
        XCTAssertTrue(fixture.doubleClick(at: try fixture.topEdge(fixture.tokens[1])))

        XCTAssertFalse(column.isTabbed)
        let shown = try fixture.frame(fixture.tokens[1])
        XCTAssertEqual(shown.minY, tabbed.minY, accuracy: 4)
        XCTAssertEqual(shown.height, tabbed.height, accuracy: 4)
        let other = try fixture.frame(fixture.tokens[0])
        XCTAssertEqual(other.minY, stacked[0].minY, accuracy: 4)
        XCTAssertEqual(other.height, stacked[0].height, accuracy: 4)
    }

    func testTheTabbedCommandAlsoSnapsTheOtherWindowsInWithNaturalDragOn() throws {
        let fixture = try makeFixture(pid: 941_026, stackFirstTwo: true)
        let column = try fixture.column(fixture.tokens[0])
        let stacked = try fixture.tokens[0 ..< 2].map { try fixture.frame($0) }
        fixture.doubleClick(at: try fixture.topEdge(fixture.tokens[1]))
        XCTAssertTrue(column.isTabbed)
        let tabbed = try fixture.frame(fixture.tokens[1])

        fixture.controller.motionPolicy.animationsEnabled = true
        let handle = try XCTUnwrap(fixture.controller.workspaceManager.handle(for: fixture.tokens[1]))
        XCTAssertTrue(fixture.controller.niriLayoutHandler.toggleColumnTabbed(target: .window(handle)))
        fixture.relayout()

        XCTAssertFalse(column.isTabbed)
        XCTAssertEqual(try fixture.frame(fixture.tokens[1]).height, tabbed.height, accuracy: 4)
        let other = try fixture.frame(fixture.tokens[0])
        XCTAssertEqual(other.minY, stacked[0].minY, accuracy: 4)
        XCTAssertEqual(other.height, stacked[0].height, accuracy: 4)
    }

    func testAStackTurnedTabbedStillMovesEachWindowFromItsStackedPlace() throws {
        let fixture = try makeFixture(pid: 941_019, stackFirstTwo: true)
        let stacked = try fixture.tokens[0 ..< 2].map { try fixture.frame($0) }

        fixture.controller.motionPolicy.animationsEnabled = true
        XCTAssertTrue(fixture.doubleClick(at: try fixture.topEdge(fixture.tokens[1])))

        XCTAssertTrue(try fixture.column(fixture.tokens[0]).isTabbed)
        for (token, start) in zip(fixture.tokens[0 ..< 2], stacked) {
            let frame = try fixture.frame(token)
            XCTAssertEqual(frame.minY, start.minY, accuracy: 4, "\(token)")
            XCTAssertEqual(frame.height, start.height, accuracy: 4, "\(token)")
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

        XCTAssertNil(fixture.handler.state.capturedInteractionButton)
        XCTAssertEqual(column.width, width)
        XCTAssertEqual(try fixture.frame(fixture.tokens[1]), start)
    }

    func testWithTheStackModifierOffTheTapStillAsksAboutDoubleClicks() throws {
        let fixture = try makeFixture(pid: 941_091)
        fixture.controller.settings.niri.naturalWindowDragModifier = .off
        fixture.handler.syncTapFilterSnapshot()
        let snapshot = fixture.handler.inputTapThread.filterSnapshot
        XCTAssertNil(snapshot.naturalDragModifier)
        XCTAssertTrue(snapshot.naturalWindowDrag)
        let edge = try fixture.rightEdge(fixture.tokens[1])

        XCTAssertTrue(MouseEventHandler.asksAboutNaturalDoubleClick(
            clickCount: 2,
            flags: [],
            naturalWindowDrag: snapshot.naturalWindowDrag,
            armedAt: edge,
            location: edge
        ))
        XCTAssertTrue(fixture.doubleClick(at: edge))
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

    func testDoubleClickingTheTitleBarMovesTheColumnToTheNextPreset() throws {
        let fixture = try makeFixture(pid: 941_007)
        let column = try fixture.column(fixture.tokens[1])
        let presets = fixture.engine.presetContainerPrimarySpans.count
        XCTAssertGreaterThan(presets, 1)

        var widths: [ProportionalSize] = []
        for _ in 0 ..< presets {
            XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(fixture.tokens[1])))
            widths.append(column.width)
        }
        XCTAssertEqual(Set(widths.map { "\($0)" }).count, presets)
        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(fixture.tokens[1])))
        XCTAssertEqual(column.width, widths[0])
    }

    func testATitleBarDoubleClickUndoesAKeptEdgeResizeBeforeCyclingWidths() throws {
        let fixture = try makeFixture(pid: 941_090)
        let token = fixture.tokens[1]
        let column = try fixture.column(token)
        let width = column.width
        try keepEdgeResize(of: token, in: fixture)

        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
        XCTAssertEqual(column.width, width)
        XCTAssertFalse(column.hasManualSingleWindowWidthOverride)

        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
        XCTAssertNotEqual(column.width, width)
    }

    func testWithNaturalDragTheCycleSizeKeysUndoAKeptEdgeResizeFirst() throws {
        for forward in [true, false] {
            let fixture = try makeFixture(pid: forward ? 941_127 : 941_128)
            let token = fixture.tokens[1]
            let column = try fixture.column(token)
            let width = column.width
            try keepEdgeResize(of: token, in: fixture)
            try fixture.select(token)

            fixture.controller.niriLayoutHandler.cycleSize(forward: forward)
            XCTAssertEqual(column.width, width, "\(forward)")
            XCTAssertNil(fixture.handler.state.nativeResizeUndos[token], "\(forward)")

            fixture.controller.niriLayoutHandler.cycleSize(forward: forward)
            XCTAssertNotEqual(column.width, width, "\(forward)")
        }
    }

    func testATitleBarDoubleClickUndoesOnlyTheClickedWindowsResize() throws {
        let fixture = try makeFixture(pid: 941_091)
        let (resized, clicked) = (fixture.tokens[1], fixture.tokens[2])
        try keepEdgeResize(of: resized, in: fixture)
        let resizedWidth = try fixture.column(resized).width
        let clickedWidth = try fixture.column(clicked).width

        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(clicked)))

        XCTAssertNotEqual(try fixture.column(clicked).width, clickedWidth)
        XCTAssertEqual(try fixture.column(resized).width, resizedWidth)
        XCTAssertNotNil(fixture.handler.state.nativeResizeUndos[resized])
    }

    func testATitleBarDoubleClickResizesTheWindowAroundItsCentre() throws {
        let fixture = try makeFixture(pid: 941_040)
        let token = fixture.tokens[1]
        let sides = fixture.screenSides
        let presets = fixture.engine.presetContainerPrimarySpans.count

        for step in 0 ..< presets {
            let before = try fixture.frame(token)
            XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
            let after = try fixture.frame(token)

            XCTAssertNotEqual(after.width, before.width, accuracy: 1, "\(step)")
            let leading = try after.minX - fixture.frame(fixture.tokens[0]).minX
            let trailing = try fixture.frame(fixture.tokens[2]).maxX - after.minX
            var expected = min(max(before.midX - after.width / 2, sides.left), sides.right - after.width)
            if leading + trailing >= sides.right - sides.left - 1 {
                expected = min(max(expected, sides.right - trailing), sides.left + leading)
            }
            XCTAssertEqual(after.minX, expected, accuracy: 1, "\(step)")
            XCTAssertGreaterThanOrEqual(after.minX, sides.left - 1, "\(step)")
            XCTAssertLessThanOrEqual(after.maxX, sides.right + 1, "\(step)")
        }
    }

    func testATitleBarDoubleClickOnTheLastColumnLeavesNoEmptyScreenBesideIt() throws {
        let fixture = try makeFixture(pid: 941_041)
        let (first, last) = (fixture.tokens[0], fixture.tokens[2])
        let sides = fixture.screenSides

        for step in 0 ..< fixture.engine.presetContainerPrimarySpans.count {
            XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(last)))
            let hidesTheStart = try fixture.frame(first).minX < sides.left - 1
            let leavesEmptyScreen = try fixture.frame(last).maxX < sides.right - 1
            XCTAssertFalse(hidesTheStart && leavesEmptyScreen, "\(step)")
        }
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

        for step in 0 ..< fixture.engine.presetContainerPrimarySpans.count {
            XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
            XCTAssertEqual(try fixture.frame(token).midX, middle, accuracy: 1, "\(step)")
        }
    }

    func testSingleClicksRightAfterATitleBarDoubleClickKeepCycling() throws {
        let fixture = try makeFixture(pid: 941_120)
        let column = try fixture.column(fixture.tokens[1])
        let point = try fixture.titleBar(fixture.tokens[1])
        let presets = fixture.engine.presetContainerPrimarySpans.count

        XCTAssertTrue(fixture.doubleClick(at: point))
        XCTAssertNotNil(fixture.handler.inputTapThread.filterSnapshot.naturalClickChain)
        var widths = [column.width]
        for _ in 1 ..< presets {
            XCTAssertTrue(fixture.doubleClick(at: point, clickCount: 1))
            widths.append(column.width)
        }

        XCTAssertEqual(Set(widths.map { "\($0)" }).count, presets)
    }

    func testTheClickChainEndsAfterASecond() throws {
        let fixture = try makeFixture(pid: 941_121)
        let clock = ClickClock()
        fixture.handler.naturalClickClock = { clock.now }
        let column = try fixture.column(fixture.tokens[1])
        let point = try fixture.titleBar(fixture.tokens[1])
        XCTAssertTrue(fixture.doubleClick(at: point))
        let width = column.width

        clock.now += MouseEventHandler.naturalClickChainWindow + 0.1

        XCTAssertFalse(fixture.doubleClick(at: point, clickCount: 1))
        XCTAssertEqual(column.width, width)
    }

    func testAClickElsewhereOrOnAControlEndsTheClickChain() throws {
        let fixture = try makeFixture(pid: 941_122)
        let column = try fixture.column(fixture.tokens[1])
        let point = try fixture.titleBar(fixture.tokens[1])
        let other = try fixture.frame(fixture.tokens[0])

        XCTAssertTrue(fixture.doubleClick(at: point))
        XCTAssertFalse(fixture.doubleClick(at: CGPoint(x: other.midX, y: other.midY), clickCount: 1))
        XCTAssertNil(fixture.handler.inputTapThread.filterSnapshot.naturalClickChain)
        let width = column.width
        XCTAssertFalse(fixture.doubleClick(at: point, clickCount: 1))
        XCTAssertEqual(column.width, width)

        XCTAssertTrue(fixture.doubleClick(at: point))
        let afterDoubleClick = column.width
        fixture.handler.titleBarHitProvider = { _, _ in TitleBarHit(
            role: "AXButton",
            placement: .insideBar(elementWithinBar: true)
        ) }
        XCTAssertFalse(fixture.doubleClick(at: point, clickCount: 1))
        fixture.handler.titleBarHitProvider = { _, _ in TitleBarHit(role: "AXWindow") }
        XCTAssertFalse(fixture.doubleClick(at: point, clickCount: 1))
        XCTAssertEqual(column.width, afterDoubleClick)
    }

    func testOnlyATiledWindowsTitleBarHoldsADragStill() throws {
        let fixture = try makeFixture(pid: 941_131)
        let titleBar = try fixture.titleBar(fixture.tokens[1])
        let frame = try fixture.frame(fixture.tokens[1])

        XCTAssertTrue(fixture.handler.holdsTitleBarDragStill(at: titleBar))
        XCTAssertFalse(fixture.handler.holdsTitleBarDragStill(at: CGPoint(x: frame.midX, y: frame.midY)))
        fixture.handler.titleBarHitProvider = { _, _ in TitleBarHit(
            role: "AXButton",
            placement: .insideBar(elementWithinBar: true)
        ) }
        XCTAssertFalse(fixture.handler.holdsTitleBarDragStill(at: titleBar))
    }

    func testATabOrAWindowOverTheTitleBarDoesNotHoldADragStill() throws {
        let fixture = try makeFixture(pid: 941_137)
        let token = fixture.tokens[1]
        let titleBar = try fixture.titleBar(token)
        XCTAssertTrue(fixture.handler.holdsTitleBarDragStill(at: titleBar, windowIdUnderPointer: token.windowId))

        XCTAssertFalse(fixture.handler.holdsTitleBarDragStill(at: titleBar, windowIdUnderPointer: token.windowId + 900))

        fixture.handler.titleBarHitProvider = { _, _ in TitleBarHit(
            role: "AXRadioButton",
            subrole: TitleBarHitTest.tabButtonSubrole,
            placement: .insideBar(elementWithinBar: true)
        ) }
        XCTAssertFalse(fixture.handler.holdsTitleBarDragStill(at: titleBar, windowIdUnderPointer: token.windowId))
    }

    func testAnAppsOwnDrawnTitleBarDoesNotHoldADragStill() throws {
        let fixture = try makeFixture(pid: 941_139)
        let token = fixture.tokens[1]
        let titleBar = try fixture.titleBar(token)
        for role in ["AXGroup", "AXTabGroup"] {
            fixture.handler.titleBarHitProvider = { _, _ in TitleBarHit(
                role: role,
                placement: .insideBar(elementWithinBar: true)
            ) }
            XCTAssertFalse(
                fixture.handler.holdsTitleBarDragStill(at: titleBar, windowIdUnderPointer: token.windowId),
                role
            )
        }
        fixture.handler.titleBarHitProvider = { _, _ in TitleBarHit(
            role: "AXToolbar",
            placement: .insideBar(elementWithinBar: true)
        ) }
        XCTAssertTrue(fixture.handler.holdsTitleBarDragStill(at: titleBar, windowIdUnderPointer: token.windowId))
    }

    func testTheTapAsksAboutAChainClickOnlyAtTheSameSpotWithinASecond() {
        let chain = NaturalClickChain(location: CGPoint(x: 100, y: 100), deadline: 10)
        func asks(_ chain: NaturalClickChain?, flags: CGEventFlags = [], at point: CGPoint, now: TimeInterval) -> Bool {
            MouseEventHandler.continuesNaturalClickChain(chain, flags: flags, location: point, now: now)
        }

        XCTAssertTrue(asks(chain, at: CGPoint(x: 104, y: 100), now: 9.5))
        XCTAssertFalse(asks(chain, at: CGPoint(x: 104, y: 100), now: 10.5))
        XCTAssertFalse(asks(chain, at: CGPoint(x: 120, y: 100), now: 9.5))
        XCTAssertFalse(asks(chain, flags: .maskCommand, at: CGPoint(x: 100, y: 100), now: 9.5))
        XCTAssertFalse(asks(nil, at: CGPoint(x: 100, y: 100), now: 9.5))
    }

    func testWithNaturalDragTheCycleSizeKeysResizeAroundTheCentre() throws {
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

    func testWithoutNaturalDragTheCycleSizeKeysKeepUpstreamsResize() throws {
        let keyed = try makeFixture(pid: 941_124)
        let upstream = try makeFixture(pid: 941_125)
        for fixture in [keyed, upstream] {
            fixture.controller.settings.niri.naturalWindowDrag = false
            try fixture.select(fixture.tokens[1])
        }

        keyed.controller.niriLayoutHandler.cycleSize(forward: true)
        upstream.controller.niriLayoutHandler.cycleContainerPrimarySpan(forward: true)
        keyed.relayout()
        upstream.relayout()

        for index in 0 ..< 3 {
            XCTAssertEqual(try keyed.frame(keyed.tokens[index]), try upstream.frame(upstream.tokens[index]), "\(index)")
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
        let point = try fixture.titleBar(token)

        var widths: [CGFloat] = []
        for _ in 0 ..< 4 {
            XCTAssertTrue(fixture.doubleClick(at: point))
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
        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))
        fixture.controller.workspaceManager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.jumpOffset(to: state.viewOffset + 100)
        }
        fixture.relayout()
        let moved = try fixture.frame(token)

        XCTAssertTrue(fixture.doubleClick(at: try fixture.titleBar(token)))

        let after = try fixture.frame(token)
        XCTAssertNotEqual(after.width, moved.width, accuracy: 1)
        XCTAssertEqual(after.midX, moved.midX, accuracy: 1)
    }

    func testAFullLoopFromAPresetCyclesThePresetsOnly() throws {
        let fixture = try makeFixture(pid: 941_132)
        let token = fixture.tokens[1]
        try fixture.select(token)
        let point = try fixture.titleBar(token)
        let presets = fixture.engine.presetContainerPrimarySpans.count
        for _ in 0 ..< presets {
            XCTAssertTrue(fixture.doubleClick(at: point))
        }
        let start = try fixture.frame(token)

        for _ in 0 ..< presets {
            XCTAssertTrue(fixture.doubleClick(at: point))
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
        for naturalWindowDrag in [true, false] {
            let fixture = try makeFixture(pid: naturalWindowDrag ? 941_134 : 941_135)
            fixture.controller.settings.niri.naturalWindowDrag = naturalWindowDrag
            fixture.engine.presetContainerPrimarySpans = [
                .proportion(2.0 / 3.0),
                .proportion(0.5),
                .proportion(1.0 / 3.0)
            ]
            let token = fixture.tokens[1]
            let column = try fixture.column(token)
            column.width = .proportion(2.0 / 3.0)
            column.presetWidthIdx = 0
            column.cachedWidth = 0
            fixture.relayout()
            try fixture.select(token)

            fixture.controller.niriLayoutHandler.cycleSize(forward: true)
            fixture.relayout()

            XCTAssertEqual(column.width, .proportion(0.5), "\(naturalWindowDrag)")
        }
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
        XCTAssertEqual(fixture.handler.state.capturedInteractionButton, .left)
        XCTAssertEqual(fixture.handler.inputTapThread.filterSnapshot.activeCapture, .left)
        XCTAssertTrue(fixture.handler.dispatchAuthoritativeTap(
            type: .leftMouseDragged, location: point, modifiers: [], buttonNumber: 0, scrollPayload: nil
        ))
        XCTAssertTrue(fixture.handler.dispatchAuthoritativeTap(
            type: .leftMouseUp, location: point, modifiers: [], buttonNumber: 0, scrollPayload: nil
        ))
        XCTAssertNil(fixture.handler.state.capturedInteractionButton)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
    }

    func testAnUnhandledDoubleClickReachesTheApp() throws {
        let fixture = try makeFixture(pid: 941_010)
        let column = try fixture.column(fixture.tokens[1])
        let width = column.width
        let frame = try fixture.frame(fixture.tokens[1])

        XCTAssertFalse(fixture.doubleClick(at: CGPoint(x: frame.midX, y: frame.midY)))
        XCTAssertFalse(fixture.doubleClick(at: CGPoint(x: frame.maxX - 1, y: frame.maxY - 1)))
        XCTAssertFalse(fixture.doubleClick(at: try fixture.titleBar(fixture.tokens[1]), modifiers: .maskAlternate))
        XCTAssertFalse(fixture.doubleClick(at: try fixture.titleBar(fixture.tokens[1]), modifiers: .maskCommand))
        XCTAssertFalse(fixture.doubleClick(at: try fixture.titleBar(fixture.tokens[1]), clickCount: 1))
        XCTAssertFalse(fixture.doubleClick(at: try fixture.titleBar(fixture.tokens[1]), clickCount: 3))

        XCTAssertEqual(column.width, width)
    }

    func testDoubleClicksAreIgnoredWithTheSettingOffAndInDwindle() throws {
        let fixture = try makeFixture(pid: 941_011)
        let column = try fixture.column(fixture.tokens[1])
        let width = column.width

        fixture.controller.settings.niri.naturalWindowDrag = false
        XCTAssertFalse(fixture.doubleClick(at: try fixture.titleBar(fixture.tokens[1])))
        XCTAssertFalse(fixture.doubleClick(at: try fixture.rightEdge(fixture.tokens[1])))

        fixture.controller.settings.niri.naturalWindowDrag = true
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

    private func keepEdgeResize(of token: WindowToken, in fixture: Fixture) throws {
        let start = try XCTUnwrap(fixture.handler.nativeResizeUndoStart(
            for: fixture.window(token),
            in: fixture.workspaceId
        ))
        let column = try fixture.column(token)
        column.width = .fixed(700)
        column.presetWidthIdx = nil
        column.hasManualSingleWindowWidthOverride = true
        column.cachedWidth = 0
        fixture.handler.rememberNativeResize(of: token, edges: .right, in: fixture.workspaceId, from: start)
        fixture.relayout()
    }

    private func makeFixture(pid: pid_t, windowCount: Int = 3, stackFirstTwo: Bool = false) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "NaturalDoubleClickTests")
        addTeardownBlock { @MainActor [controller] in
            controller.hasStartedServices = false
            controller.layoutRefreshController.resetState()
            controller.mouseEventHandler.cleanup()
            controller.surfaceReconciler.cleanup()
            controller.axManager.cleanup()
        }
        controller.motionPolicy.animationsEnabled = false
        let monitor = Monitor(
            id: .init(displayId: 94_101),
            displayId: 94_101,
            frame: workingFrame,
            visibleFrame: workingFrame,
            hasNotch: false,
            name: "Natural Double Click"
        )
        controller.settings.niri.naturalWindowDrag = true
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
            column.width = .proportion(1.0 / 3.0)
            column.cachedWidth = 0
        }
        controller.mouseEventHandler
            .titleBarHitProvider = { _, _ in TitleBarHit(role: "AXWindow") }
        controller.layoutRefreshController.resetState()
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        controller.hasStartedServices = true
        let fixture = Fixture(controller: controller, workspaceId: workspaceId, monitor: monitor, tokens: tokens)
        fixture.relayout()
        return fixture
    }
}
