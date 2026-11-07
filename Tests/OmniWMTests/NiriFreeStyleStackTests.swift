// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class NiriFreeStyleStackTests: XCTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let frame: CGRect
        let gap: CGFloat
        let tokens: [WindowToken]
        var state: ViewportState
        var motion = MotionSnapshot.disabled

        var context: NiriInteractionContext {
            .init(workspaceId: workspaceId, motion: motion, workingFrame: frame, gaps: gap, orientation: .horizontal)
        }

        var hintHeight: CGFloat {
            max(frame.height * 0.05, 40)
        }

        var move: LiveColumnMove? {
            engine.liveColumnMove
        }

        func window(_ index: Int) -> NiriWindow {
            engine.findNode(for: tokens[index], in: workspaceId)!
        }

        func column(_ index: Int) -> NiriContainer {
            engine.findColumn(containing: window(index), in: workspaceId)!
        }

        func stripColumn(_ column: NiriContainer) -> LiveColumnMove.StripColumn {
            engine.liveColumnStrip(context: context, state: state).first { $0.column === column }!
        }

        func span(of index: Int) -> LiveColumnMove.WindowSpan {
            engine.liveWindowSpans(in: column(index), context: context).first { $0.window === window(index) }!
        }

        func height(of index: Int) -> CGFloat {
            let span = span(of: index)
            return span.maxY - span.minY
        }

        func centre(of index: Int, upper: Bool) -> CGPoint {
            let span = span(of: index)
            let quarter = (span.maxY - span.minY) / 4
            return CGPoint(x: stripColumn(column(index)).midX, y: upper ? span.maxY - quarter : span.minY + quarter)
        }

        func side(of index: Int, leading: Bool) -> CGPoint {
            let placed = stripColumn(column(index))
            let span = span(of: index)
            let x = leading ? placed.minX + placed.width / 6 : placed.maxX - placed.width / 6
            return CGPoint(x: x, y: (span.minY + span.maxY) / 2)
        }

        mutating func begin(_ index: Int) -> Bool {
            engine.liveColumnMoveBegin(
                windowId: window(index).id,
                windowToken: tokens[index],
                context: context,
                state: &state
            )
        }

        mutating func move(
            to cursor: CGPoint,
            windowMidX: CGFloat? = nil,
            at time: TimeInterval
        ) -> LiveColumnMove.Step {
            let step = engine.liveColumnMoveUpdate(
                cursor: cursor,
                windowMidX: windowMidX,
                at: time,
                context: context,
                state: &state
            )
            if step == .changed {
                engine.liveColumnMoveSettled()
            }
            return step
        }

        mutating func setStackMode(_ held: Bool, at cursor: CGPoint) -> LiveColumnMove.Step {
            let step = engine.liveColumnMoveStackModeChanged(
                held: held,
                cursor: cursor,
                context: context,
                state: &state
            )
            if step == .changed {
                engine.liveColumnMoveSettled()
            }
            return step
        }

        mutating func openHint(over index: Int, upper: Bool) {
            _ = move(to: centre(of: index, upper: upper), at: 1)
            _ = move(to: centre(of: index, upper: upper), at: 2)
        }

        mutating func stack(_ index: Int, onto target: Int) {
            let moved = window(index)
            let column = column(index)
            moved.detach()
            column.remove()
            engine.attachTransferredWindow(
                moved,
                stackedWith: window(target),
                after: true,
                in: workspaceId,
                state: &state
            )
            engine.resolvePrimaryContainerSpans(
                in: workspaceId,
                workingFrame: frame,
                gaps: gap,
                orientation: .horizontal
            )
        }

        func frames(at time: TimeInterval) -> [WindowToken: CGRect] {
            engine.calculateLayoutWithVisibility(
                state: state,
                workspaceId: workspaceId,
                monitorFrame: frame,
                gaps: (gap, gap),
                orientation: .horizontal,
                animationTime: time
            ).frames
        }

        mutating func end(stacking: Bool = false) -> Bool {
            engine.liveColumnMoveEnd(stacking: stacking, context: context, state: &state)
        }

        mutating func finish() -> Bool {
            engine.liveStackDropFinish(context: context, state: &state)
        }
    }

    private func makeFixture(widths: [CGFloat] = Array(repeating: 1.0 / 3.0, count: 5)) -> Fixture {
        let engine = NiriLayoutEngine()
        engine.moveConfiguration.liveHoverDelay = 0
        engine.applyMacOSFusion(.init(enabled: true, edgePeekShare: nil))
        let workspaceId = WorkspaceDescriptor.ID()
        let frame = CGRect(x: 0, y: 0, width: 1_500, height: 900)
        let monitor = Monitor(
            id: Monitor.ID(displayId: 96), displayId: 96, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Free-style stacking"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )
        let tokens = widths.indices.map { WindowToken(pid: 961, windowId: $0 + 1) }
        for token in tokens {
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        for (column, width) in zip(engine.columns(in: workspaceId), widths) {
            column.width = .proportion(width)
        }
        let gap: CGFloat = 12
        engine.resolvePrimaryContainerSpans(in: workspaceId, workingFrame: frame, gaps: gap, orientation: .horizontal)
        let active = engine.findNode(for: tokens[1], in: workspaceId)!
        var state = ViewportState(selectedNodeId: active.id)
        state.activeColumnIndex = 1
        state.jumpOffset(to: -gap)
        return Fixture(engine: engine, workspaceId: workspaceId, frame: frame, gap: gap, tokens: tokens, state: state)
    }

    func testTheCentreOpensAThinHintAboveOrBelowAfterItsDelay() {
        for upper in [true, false] {
            var fixture = makeFixture()
            XCTAssertTrue(fixture.begin(1))
            let target = fixture.centre(of: 3, upper: upper)
            _ = fixture.move(to: target, at: 1)

            XCTAssertEqual(fixture.move(to: target, at: 1), .hovering(until: 1 + 0.2))
            XCTAssertNil(fixture.move?.landing)
            XCTAssertEqual(fixture.move(to: target, at: 1.25), .changed)

            XCTAssertEqual(fixture.move?.landingIsHint, true)
            XCTAssertEqual(fixture.move?.landing?.above, upper)
            XCTAssertTrue(fixture.window(1).parent === fixture.column(3))
            XCTAssertEqual(fixture.height(of: 1), fixture.hintHeight, accuracy: 0.5)
            XCTAssertEqual(
                fixture.height(of: 3),
                fixture.frame.height - 3 * fixture.gap - fixture.hintHeight,
                accuracy: 0.5
            )
        }
    }

    func testMovesWithinTheCentreDontRestartItsDelayAndLeavingDoes() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        let target = fixture.centre(of: 3, upper: true)
        _ = fixture.move(to: target, at: 1)
        XCTAssertEqual(fixture.move(to: target, at: 1), .hovering(until: 1 + 0.2))
        let nudged = CGPoint(x: target.x + 10, y: target.y)
        XCTAssertEqual(fixture.move(to: nudged, at: 1.1), .hovering(until: 1 + 0.2))

        _ = fixture.move(to: fixture.side(of: 3, leading: false), at: 1.12)
        XCTAssertNil(fixture.move?.centreWait)
        _ = fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state)

        var again = makeFixture()
        XCTAssertTrue(again.begin(1))
        let centre = again.centre(of: 3, upper: true)
        _ = again.move(to: centre, at: 1)
        _ = again.move(to: again.side(of: 3, leading: true), at: 1.05)
        XCTAssertEqual(again.move(to: again.centre(of: 3, upper: true), at: 1.2), .hovering(until: 1.2 + 0.2))
    }

    func testTheSideThirdsKeepTheSwapRules() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))

        XCTAssertEqual(fixture.move(to: fixture.side(of: 3, leading: false), at: 1), .changed)

        XCTAssertNil(fixture.move?.landing)
        XCTAssertFalse(fixture.move?.landingIsHint ?? true)
        XCTAssertEqual(fixture.column(3).windowNodes.count, 1)
    }

    func testAWindowNarrowerThanTheCentreWidthHasNoCentre() {
        var fixture = makeFixture(widths: [0.3, 0.3, 0.3, 280.0 / 1_500, 0.3])
        XCTAssertTrue(fixture.begin(1))

        _ = fixture.move(to: fixture.centre(of: 3, upper: true), at: 1)
        _ = fixture.move(to: fixture.centre(of: 3, upper: true), at: 2)

        XCTAssertNil(fixture.move?.landing)
        XCTAssertEqual(fixture.column(3).windowNodes.count, 1)
    }

    func testTheHintTakesItsRoomOnlyFromTheWindowNextToIt() {
        var fixture = makeFixture()
        fixture.stack(4, onto: 3)
        fixture.stack(0, onto: 4)
        let heights = (top: fixture.height(of: 0), middle: fixture.height(of: 4), bottom: fixture.height(of: 3))
        XCTAssertTrue(fixture.begin(1))

        fixture.openHint(over: 0, upper: true)

        XCTAssertEqual(fixture.move?.landingIsHint, true)
        XCTAssertEqual(fixture.height(of: 0), heights.top - fixture.hintHeight - fixture.gap, accuracy: 0.5)
        XCTAssertEqual(fixture.height(of: 4), heights.middle, accuracy: 0.5)
        XCTAssertEqual(fixture.height(of: 3), heights.bottom, accuracy: 0.5)
    }

    func testReleasingOverTheHintStacksAndTheColumnTakesItsFinalShares() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: false)

        XCTAssertTrue(fixture.end())
        XCTAssertTrue(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))
        XCTAssertTrue(fixture.finish())

        XCTAssertEqual(fixture.column(3).windowNodes.map(\.token), [fixture.tokens[1], fixture.tokens[3]])
        XCTAssertTrue(fixture.column(3).windowNodes.allSatisfy { $0.liveSpanOverride == nil })
        XCTAssertEqual(fixture.height(of: 1), fixture.height(of: 3), accuracy: 0.5)
    }

    func testLettingGoBeforeTheCentreDelayIsASwap() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        _ = fixture.move(to: fixture.centre(of: 3, upper: true), at: 1)

        XCTAssertTrue(fixture.end())

        XCTAssertFalse(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))
        XCTAssertEqual(fixture.column(3).windowNodes.count, 1)
        XCTAssertEqual(fixture.column(1).windowNodes.count, 1)
    }

    func testAnImmediateUpdateOpensNoHint() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))

        _ = fixture.engine.liveColumnMoveUpdate(
            cursor: fixture.centre(of: 3, upper: true),
            at: 5,
            immediate: true,
            context: fixture.context,
            state: &fixture.state
        )

        XCTAssertNil(fixture.move?.landing)
    }

    func testTheModifierTurnsTheHintIntoTheFullGapAndBack() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)
        let cursor = fixture.centre(of: 3, upper: true)

        XCTAssertEqual(fixture.setStackMode(true, at: cursor), .changed)
        XCTAssertEqual(fixture.move?.landingIsHint, false)
        XCTAssertEqual(fixture.height(of: 1), fixture.height(of: 3), accuracy: 0.5)

        XCTAssertEqual(fixture.setStackMode(false, at: cursor), .changed)
        XCTAssertEqual(fixture.move?.landingIsHint, true)
        XCTAssertEqual(fixture.height(of: 1), fixture.hintHeight, accuracy: 0.5)
    }

    func testReleasingTheModifierOverASideThirdClosesTheGap() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.setStackMode(true, at: fixture.side(of: 3, leading: true)), .changed)
        XCTAssertNotNil(fixture.move?.landing)

        XCTAssertEqual(fixture.setStackMode(false, at: fixture.side(of: 3, leading: true)), .changed)

        XCTAssertNil(fixture.move?.landing)
        XCTAssertEqual(fixture.column(3).windowNodes.count, 1)
    }

    func testTheHintHoldsAShortWayPastTheCentre() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)
        let placed = fixture.stripColumn(fixture.column(3))
        let y = fixture.centre(of: 3, upper: true).y

        _ = fixture.move(to: CGPoint(x: placed.minX + placed.width / 3 - 10, y: y), at: 3)
        XCTAssertEqual(fixture.move?.landingIsHint, true)

        _ = fixture.move(to: CGPoint(x: placed.minX + placed.width / 3 - 30, y: y), at: 3.1)
        XCTAssertEqual(fixture.move?.landingIsHint, false)
        XCTAssertTrue(fixture.window(1).parent !== fixture.column(3))
    }

    func testTheEdgeScrollClosesTheHint() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)

        XCTAssertTrue(fixture.engine.liveColumnMoveCloseLandingForEdgeScroll(
            context: fixture.context,
            state: &fixture.state
        ))

        XCTAssertNil(fixture.move?.landing)
        XCTAssertEqual(fixture.move?.landingIsHint, false)
        XCTAssertTrue(fixture.column(3).windowNodes.allSatisfy { $0.liveSpanOverride == nil })
    }

    func testCancellingWithAHintOpenRestoresTheColumn() {
        var fixture = makeFixture()
        let height = fixture.height(of: 3)
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)

        XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))

        XCTAssertEqual(fixture.column(3).windowNodes.count, 1)
        XCTAssertNil(fixture.window(3).liveSpanOverride)
        XCTAssertNil(fixture.window(1).liveSpanOverride)
        XCTAssertFalse(fixture.window(1).defersMinimumWidth)
        XCTAssertEqual(fixture.height(of: 3), height, accuracy: 0.5)
    }

    func testADragCutOffWithAHintOpenLeavesNoHintBehind() {
        var fixture = makeFixture()
        let narrow = fixture.stripColumn(fixture.column(3)).width
        fixture.window(1).constraints = WindowSizeConstraints(
            minSize: CGSize(width: narrow + 150, height: 1),
            maxSize: .zero,
            isFixed: false
        )
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)

        fixture.engine.cancelInteractions(for: [fixture.window(1).id], in: fixture.workspaceId)

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertFalse(fixture.window(1).defersMinimumWidth)
        XCTAssertTrue(fixture.column(1).windowNodes.allSatisfy { $0.liveSpanOverride == nil })
        XCTAssertGreaterThanOrEqual(fixture.column(1).cachedWidth, narrow + 150 - 0.5)
    }

    func testTheCentreAloneDoesntStopTheEdgeScroll() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.move(to: fixture.side(of: 3, leading: false), at: 1), .changed)
        let placed = fixture.stripColumn(fixture.column(3))
        let centre = CGPoint(x: placed.midX + 5, y: fixture.side(of: 3, leading: false).y)

        XCTAssertFalse(fixture.engine.liveColumnMoveWouldChange(
            cursor: centre,
            strip: fixture.engine.liveColumnStrip(context: fixture.context, state: fixture.state),
            context: fixture.context
        ))
    }

    func testASideThirdWaitsItsDelayAgainAfterTheCentre() {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 0.12
        XCTAssertTrue(fixture.begin(1))
        let side = fixture.side(of: 3, leading: false)
        _ = fixture.move(to: side, at: 1)
        XCTAssertEqual(fixture.move(to: side, at: 1), .hovering(until: 1.12))
        _ = fixture.move(to: fixture.centre(of: 3, upper: true), at: 1.05)

        XCTAssertEqual(fixture.move(to: side, at: 1.3), .hovering(until: 1.3 + 0.12))
    }

    func testUndoAfterAWideningDropRestoresTheStack() {
        var fixture = makeFixture()
        let narrow = fixture.stripColumn(fixture.column(3)).width
        fixture.window(1).constraints = WindowSizeConstraints(
            minSize: CGSize(width: narrow + 150, height: 1),
            maxSize: .zero,
            isFixed: false
        )
        let before = fixture.engine.layoutSnapshot(in: fixture.workspaceId, focused: nil)!
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)
        XCTAssertTrue(fixture.end())
        XCTAssertTrue(fixture.finish())
        XCTAssertEqual(fixture.stripColumn(fixture.column(3)).width, narrow + 150, accuracy: 0.5)

        XCTAssertTrue(fixture.engine.restoreLayoutSnapshot(before, in: fixture.workspaceId))

        XCTAssertEqual(fixture.column(3).windowNodes.count, 1)
        XCTAssertEqual(fixture.stripColumn(fixture.column(3)).width, narrow, accuracy: 0.5)
    }

    func testWithoutCentreStackingTheCentreNeverStacks() {
        var fixture = makeFixture()
        fixture.engine.stacksOnWindowCentres = false
        XCTAssertTrue(fixture.begin(1))

        fixture.openHint(over: 3, upper: true)

        XCTAssertNil(fixture.move?.landing)
    }

    func testTheGapLeftBehindClosesWithTheWindowAndOpensAgainOnTheWayBack() {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        fixture.engine.moveConfiguration.liveCentreStackDelay = 10
        let home = fixture.column(1)
        let full = fixture.stripColumn(home).width
        let start = fixture.stripColumn(home).midX
        let y = fixture.frame.midY
        XCTAssertTrue(fixture.begin(1))
        _ = fixture.move(to: CGPoint(x: start, y: y), at: 1)

        var widths: [CGFloat] = []
        for step in 1 ... 14 {
            _ = fixture.move(to: CGPoint(x: start + CGFloat(step) * 40, y: y), at: 1)
            widths.append(fixture.stripColumn(home).width)
        }

        XCTAssertEqual(widths, widths.sorted(by: >))
        XCTAssertEqual(widths.last ?? .nan, -fixture.gap, accuracy: 0.5)
        let left = fixture.stripColumn(fixture.column(0))
        let right = fixture.stripColumn(fixture.column(2))
        XCTAssertEqual(right.minX - left.maxX, fixture.gap, accuracy: 0.5)
        XCTAssertTrue(zip(widths, widths.dropFirst()).allSatisfy { $0 - $1 <= 40.5 })

        _ = fixture.move(to: CGPoint(x: start + 200, y: y), at: 1)
        XCTAssertGreaterThan(fixture.stripColumn(home).width, 0)
        _ = fixture.move(to: CGPoint(x: start, y: y), at: 1)
        XCTAssertEqual(fixture.stripColumn(home).width, full, accuracy: 0.5)
    }

    func testEveryLandingIsADropSpaceAndTheHomeSpotStaysPut() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        let order = fixture.engine.columns(in: fixture.workspaceId).map(\.id)

        _ = fixture.move(to: fixture.side(of: 3, leading: false), at: 1)

        XCTAssertNotNil(fixture.move?.dropSpaceId)
        let columns = fixture.engine.columns(in: fixture.workspaceId).filter { !$0.isLiveDropSpace }.map(\.id)
        XCTAssertEqual(columns, order)
    }

    func testLettingGoWithNoLandingPutsTheWindowBackAtItsFullWidth() {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        fixture.engine.moveConfiguration.liveCentreStackDelay = 10
        let home = fixture.column(1)
        let full = fixture.stripColumn(home).width
        let start = fixture.stripColumn(home).midX
        XCTAssertTrue(fixture.begin(1))
        _ = fixture.move(to: CGPoint(x: start, y: fixture.frame.midY), at: 1)
        _ = fixture.move(to: CGPoint(x: start + full + 60, y: fixture.frame.midY), at: 1)
        XCTAssertLessThan(fixture.stripColumn(home).width, 0)

        XCTAssertTrue(fixture.end())

        XCTAssertEqual(fixture.stripColumn(fixture.column(1)).width, full, accuracy: 0.5)
        XCTAssertEqual(fixture.column(1).windowNodes.map(\.token), [fixture.tokens[1]])
    }

    func testAQuickFlickClosesTheGapOnTheFirstUpdate() {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        fixture.engine.moveConfiguration.liveCentreStackDelay = 10
        let home = fixture.column(1)
        let placed = fixture.stripColumn(home)
        XCTAssertTrue(fixture.begin(1))

        _ = fixture.move(to: CGPoint(x: placed.midX + placed.width + fixture.gap + 60, y: fixture.frame.midY), at: 1)

        XCTAssertEqual(fixture.stripColumn(home).width, -fixture.gap, accuracy: 0.5)
    }

    func testTheGapFollowsTheWindowItselfNotTheReferencePoint() {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        fixture.engine.moveConfiguration.liveCentreStackDelay = 10
        let home = fixture.column(1)
        let placed = fixture.stripColumn(home)
        let overHome = CGPoint(x: placed.midX, y: fixture.frame.midY)
        XCTAssertTrue(fixture.begin(1))

        _ = fixture.move(to: overHome, windowMidX: placed.midX + placed.width / 2, at: 1)
        XCTAssertEqual(fixture.stripColumn(home).width, placed.width / 2, accuracy: 0.5)

        _ = fixture.move(to: overHome, windowMidX: placed.midX + placed.width + fixture.gap, at: 1)
        XCTAssertEqual(fixture.stripColumn(home).width, -fixture.gap, accuracy: 0.5)
    }

    func testThePlaceStaysAsWideAsTheWindowCoversItWhenScrolledOffScreen() {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        fixture.engine.moveConfiguration.liveCentreStackDelay = 10
        let home = fixture.column(1)
        XCTAssertTrue(fixture.begin(1))
        fixture.state.jumpOffset(to: fixture.state.viewOffset + fixture.stripColumn(home).maxX + 40)
        let placed = fixture.stripColumn(home)
        XCTAssertLessThanOrEqual(placed.maxX, fixture.frame.minX)

        _ = fixture.move(
            to: CGPoint(x: fixture.frame.minX + 20, y: fixture.frame.midY),
            windowMidX: placed.midX + placed.width / 4,
            at: 1
        )

        XCTAssertEqual(fixture.stripColumn(home).width, placed.width * 3 / 4, accuracy: 0.5)
    }

    func testOnlyTheWindowsOwnPlaceClosesThatWay() throws {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        let move = try XCTUnwrap(fixture.move)
        XCTAssertTrue(fixture.engine.isClosingOrigin(move))
        fixture.engine.closesOriginGap = false
        XCTAssertFalse(fixture.engine.isClosingOrigin(move))
    }

    func testAWindowLeavingAStackKeepsItsNarrowLandingGap() throws {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        fixture.engine.moveConfiguration.liveCentreStackDelay = 10
        fixture.stack(3, onto: 2)
        let stack = fixture.column(2)
        let y = fixture.frame.midY
        XCTAssertTrue(fixture.begin(3))
        XCTAssertFalse(try fixture.engine.isClosingOrigin(XCTUnwrap(fixture.move)))

        _ = fixture.move(to: CGPoint(x: fixture.stripColumn(stack).maxX + 20, y: y), at: 1)
        let left = try XCTUnwrap(fixture.move)
        XCTAssertFalse(left.inStack)
        XCTAssertFalse(fixture.engine.isClosingOrigin(left))
        let home = try XCTUnwrap(fixture.engine.liveDraggedColumn(for: left))
        XCTAssertFalse(home === stack)

        _ = fixture.move(to: CGPoint(x: fixture.stripColumn(stack).maxX + 400, y: y), at: 1)
        XCTAssertGreaterThan(fixture.stripColumn(home).width, 0)
    }

    func testATabPulledOutKeepsItsNarrowLandingGap() throws {
        var fixture = makeFixture()
        fixture.engine.moveConfiguration.liveHoverDelay = 10
        fixture.engine.moveConfiguration.liveCentreStackDelay = 10
        fixture.stack(3, onto: 2)
        let tabs = fixture.column(2)
        tabs.displayMode = .tabbed
        fixture.engine.updateTabbedColumnVisibility(column: tabs)
        let pulled = fixture.window(3)
        let y = fixture.frame.midY
        XCTAssertTrue(fixture.engine.liveColumnMoveBegin(
            windowId: pulled.id,
            windowToken: pulled.token,
            pullsTab: true,
            context: fixture.context,
            state: &fixture.state
        ))
        XCTAssertFalse(try fixture.engine.isClosingOrigin(XCTUnwrap(fixture.move)))

        _ = fixture.move(to: CGPoint(x: fixture.stripColumn(tabs).maxX + 20, y: y), at: 1)
        let pulledOut = try XCTUnwrap(fixture.move)
        XCTAssertFalse(fixture.engine.isClosingOrigin(pulledOut))
        let home = try XCTUnwrap(fixture.engine.liveDraggedColumn(for: pulledOut))

        _ = fixture.move(to: CGPoint(x: fixture.stripColumn(tabs).maxX + 400, y: y), at: 1)
        XCTAssertGreaterThan(fixture.stripColumn(home).width, 0)
    }

    func testMacOSFusionTurnsCentreStackingOnAndOff() {
        let engine = NiriLayoutEngine()
        engine.applyMacOSFusion(.init(enabled: true, edgePeekShare: nil))
        XCTAssertTrue(engine.stacksOnWindowCentres)
        XCTAssertTrue(engine.animatesLearnedMinimumWidths)
        XCTAssertTrue(engine.closesOriginGap)
        engine.applyMacOSFusion(.init(enabled: false, edgePeekShare: nil))
        XCTAssertFalse(engine.stacksOnWindowCentres)
        XCTAssertFalse(engine.animatesLearnedMinimumWidths)
    }

    func testANarrowStackTakesAWiderWindowAndWidensOnlyOnTheDrop() {
        for withModifier in [false, true] {
            var fixture = makeFixture()
            let narrow = fixture.stripColumn(fixture.column(3)).width
            let minimum = narrow + 150
            fixture.window(1).constraints = WindowSizeConstraints(
                minSize: CGSize(width: minimum, height: 1),
                maxSize: .zero,
                isFixed: false
            )
            XCTAssertTrue(fixture.begin(1))
            if withModifier {
                XCTAssertEqual(fixture.setStackMode(true, at: fixture.centre(of: 3, upper: true)), .changed)
            } else {
                fixture.openHint(over: 3, upper: true)
            }
            XCTAssertNotNil(fixture.move?.landing, "\(withModifier)")
            XCTAssertEqual(fixture.stripColumn(fixture.column(3)).width, narrow, accuracy: 0.5, "\(withModifier)")

            XCTAssertTrue(fixture.end(stacking: withModifier))
            XCTAssertEqual(fixture.stripColumn(fixture.column(3)).width, minimum, accuracy: 0.5, "\(withModifier)")
            XCTAssertTrue(fixture.finish())
            XCTAssertEqual(fixture.stripColumn(fixture.column(3)).width, minimum, accuracy: 0.5, "\(withModifier)")
            XCTAssertFalse(fixture.window(1).defersMinimumWidth)
        }
    }

    func testAStackWidensTowardTheSideTheWindowCameFrom() {
        var fixture = makeFixture()
        let narrow = fixture.stripColumn(fixture.column(3)).width
        fixture.window(1).constraints = WindowSizeConstraints(
            minSize: CGSize(width: narrow + 150, height: 1),
            maxSize: .zero,
            isFixed: false
        )
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)
        let rightEdge = fixture.stripColumn(fixture.column(3)).maxX

        XCTAssertTrue(fixture.end())

        XCTAssertEqual(fixture.stripColumn(fixture.column(3)).maxX, rightEdge, accuracy: 0.5)
    }

    func testWithAnimationsTheStackSpringsOutFromItsOldWidth() {
        var fixture = makeFixture()
        let narrow = fixture.stripColumn(fixture.column(3)).width
        fixture.window(1).constraints = WindowSizeConstraints(
            minSize: CGSize(width: narrow + 150, height: 1),
            maxSize: .zero,
            isFixed: false
        )
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)
        fixture.motion = .enabled

        XCTAssertTrue(fixture.end())

        let column = fixture.column(3)
        XCTAssertTrue(column.hasWidthAnimationRunning)
        XCTAssertEqual(column.cachedWidth, narrow, accuracy: 0.5)
        XCTAssertEqual(column.targetWidth ?? 0, narrow + 150, accuracy: 0.5)
    }

    func testADropFromPartlyOffScreenStartsWhereTheWindowWasAndEachEdgeMovesOneWay() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)
        let placed = fixture.stripColumn(fixture.column(3))
        let release = CGRect(x: placed.minX - 100, y: -300, width: placed.width, height: 876)
        fixture.motion = .enabled

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(
            releasedFrame: release,
            context: fixture.context,
            state: &fixture.state
        ))

        let now = CACurrentMediaTime()
        let samples = (0 ... 12).compactMap { step in
            fixture.frames(at: now + Double(step) * 0.05)[fixture.tokens[1]]
        }
        XCTAssertEqual(samples.first?.minY ?? -1, fixture.frame.minY, accuracy: 1)
        XCTAssertEqual(samples.first?.maxY ?? -1, release.maxY, accuracy: 1)
        for (earlier, later) in zip(samples, samples.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.minY, earlier.minY - 0.5)
            XCTAssertGreaterThanOrEqual(later.maxY, earlier.maxY - 0.5)
        }
    }

    func testWhileTheStackSpringsOutTheWiderWindowStaysOffTheStillNeighbour() {
        var fixture = makeFixture()
        let narrow = fixture.stripColumn(fixture.column(3)).width
        let minimum = narrow + 150
        fixture.window(1).constraints = WindowSizeConstraints(
            minSize: CGSize(width: minimum, height: 1),
            maxSize: .zero,
            isFixed: false
        )
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)
        fixture.motion = .enabled

        XCTAssertTrue(fixture.end())

        let now = CACurrentMediaTime()
        for step in 0 ... 12 {
            let frames = fixture.frames(at: now + Double(step) * 0.05)
            guard let dropped = frames[fixture.tokens[1]], let neighbour = frames[fixture.tokens[4]] else {
                return XCTFail("no frames at step \(step)")
            }
            XCTAssertGreaterThanOrEqual(dropped.width, minimum - 0.5, "step \(step)")
            XCTAssertLessThanOrEqual(dropped.maxX, neighbour.minX - fixture.gap + 0.5, "step \(step)")
        }
    }

    func testAStackWideEnoughForTheWindowKeepsItsWidth() {
        var fixture = makeFixture()
        let width = fixture.stripColumn(fixture.column(3)).width
        fixture.window(1).constraints = WindowSizeConstraints(
            minSize: CGSize(width: width - 100, height: 1),
            maxSize: .zero,
            isFixed: false
        )
        XCTAssertTrue(fixture.begin(1))
        fixture.openHint(over: 3, upper: true)

        XCTAssertTrue(fixture.end())
        XCTAssertTrue(fixture.finish())

        XCTAssertEqual(fixture.stripColumn(fixture.column(3)).width, width, accuracy: 0.5)
    }

    func testALearnedMinimumWidensItsColumnWithAnAnimation() {
        for animates in [true, false] {
            let fixture = makeFixture()
            fixture.engine.animatesLearnedMinimumWidths = animates
            let column = fixture.column(3)
            let width = column.cachedWidth

            fixture.engine.updateWindowConstraints(
                for: fixture.tokens[3],
                constraints: WindowSizeConstraints(
                    minSize: CGSize(width: width + 200, height: 1),
                    maxSize: .zero,
                    isFixed: false
                ),
                in: fixture.workspaceId,
                motion: .enabled
            )

            XCTAssertEqual(column.hasWidthAnimationRunning, animates)
            XCTAssertEqual(animates ? column.targetWidth ?? 0 : column.cachedWidth, width + 200, accuracy: 0.5)
        }
    }
}
