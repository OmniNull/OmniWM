// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriLiveStackModeTests: XCTestCase {
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

        func window(_ index: Int) -> NiriWindow {
            engine.findNode(for: tokens[index], in: workspaceId)!
        }

        func column(_ index: Int) -> NiriContainer {
            engine.findColumn(containing: window(index), in: workspaceId)!
        }

        func columnOrder() -> [[WindowToken]] {
            engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) }
        }

        func strip() -> [LiveColumnMove.StripColumn] {
            engine.liveColumnStrip(context: context, state: state)
        }

        func stripColumn(_ column: NiriContainer) -> LiveColumnMove.StripColumn {
            strip().first { $0.column === column }!
        }

        func spans(_ column: NiriContainer) -> [LiveColumnMove.WindowSpan] {
            engine.liveWindowSpans(in: column, context: context)
        }

        func span(of index: Int) -> LiveColumnMove.WindowSpan {
            spans(column(index)).first { $0.window === window(index) }!
        }

        func point(inColumnOf index: Int, y: CGFloat) -> CGPoint {
            CGPoint(x: stripColumn(column(index)).midX, y: y)
        }

        func lowerHalf(of index: Int) -> CGPoint {
            let span = span(of: index)
            return point(inColumnOf: index, y: span.minY + (span.maxY - span.minY) / 4)
        }

        func upperHalf(of index: Int) -> CGPoint {
            let span = span(of: index)
            return point(inColumnOf: index, y: span.maxY - (span.maxY - span.minY) / 4)
        }

        func frames() -> [WindowToken: CGRect] {
            engine.calculateLayout(
                state: state,
                workspaceId: workspaceId,
                monitorFrame: frame,
                gaps: (gap, gap),
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

        mutating func begin(_ index: Int) -> Bool {
            engine.liveColumnMoveBegin(
                windowId: window(index).id,
                windowToken: tokens[index],
                context: context,
                state: &state
            )
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

        mutating func move(to cursor: CGPoint, at time: TimeInterval = 0) -> LiveColumnMove.Step {
            let step = engine.liveColumnMoveUpdate(cursor: cursor, at: time, context: context, state: &state)
            if step == .changed {
                engine.liveColumnMoveSettled()
            }
            return step
        }

        mutating func stack(_ index: Int, onto target: Int, after: Bool = true) {
            let moved = window(index)
            let column = column(index)
            moved.detach()
            column.remove()
            engine.attachTransferredWindow(
                moved,
                stackedWith: window(target),
                after: after,
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

        mutating func makeTabbed(_ index: Int, tabCount: Int = 3, activeTab: Int = 1) -> NiriContainer {
            var last = window(index)
            for tab in 1 ..< tabCount {
                let tabWindow = NiriWindow(token: WindowToken(pid: 942, windowId: index * 10 + tab))
                engine.attachTransferredWindow(
                    tabWindow,
                    stackedWith: last,
                    after: true,
                    in: workspaceId,
                    state: &state
                )
                last = tabWindow
            }
            let column = column(index)
            column.displayMode = .tabbed
            column.setActiveTileIdx(activeTab)
            engine.updateTabbedColumnVisibility(column: column)
            engine.renderStyle.tabIndicatorWidth = 24
            column.cachedWidth = 0
            engine.resolvePrimaryContainerSpans(
                in: workspaceId,
                workingFrame: frame,
                gaps: gap,
                orientation: .horizontal
            )
            return column
        }

        mutating func scrollSoThat(_ column: NiriContainer, startsAt x: CGFloat) {
            state.jumpOffset(to: state.viewOffset + stripColumn(column).minX - x)
        }

        mutating func beginPull(_ window: NiriWindow) -> Bool {
            engine.liveColumnMoveBegin(
                windowId: window.id,
                windowToken: window.token,
                pullsTab: true,
                context: context,
                state: &state
            )
        }

        func storage(_ column: NiriContainer) -> [WindowToken] {
            column.windowNodes.map(\.token)
        }

        func middle(of index: Int) -> CGPoint {
            let span = span(of: index)
            return point(inColumnOf: index, y: (span.minY + span.maxY) / 2)
        }

        mutating func endStacking() -> Bool {
            engine.liveColumnMoveEnd(stacking: true, context: context, state: &state)
        }

        mutating func finishStackDrop() -> Bool {
            engine.liveStackDropFinish(context: context, state: &state)
        }
    }

    private func makeFixture(
        widths: [CGFloat] = Array(repeating: 1.0 / 3.0, count: 5),
        activeIndex: Int = 1
    ) -> Fixture {
        let engine = NiriLayoutEngine()
        engine.moveConfiguration.liveHoverDelay = 0
        let workspaceId = WorkspaceDescriptor.ID()
        let frame = CGRect(x: 0, y: 0, width: 1_500, height: 900)
        let monitor = Monitor(
            id: Monitor.ID(displayId: 94), displayId: 94, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Live stack mode"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )
        let tokens = widths.indices.map { WindowToken(pid: 941, windowId: $0 + 1) }
        for token in tokens {
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        for (column, width) in zip(engine.columns(in: workspaceId), widths) {
            column.width = .proportion(width)
        }
        let gap: CGFloat = 12
        engine.resolvePrimaryContainerSpans(in: workspaceId, workingFrame: frame, gaps: gap, orientation: .horizontal)
        let active = engine.findNode(for: tokens[activeIndex], in: workspaceId)!
        var state = ViewportState(selectedNodeId: active.id)
        state.activeColumnIndex = activeIndex
        state.jumpOffset(to: -gap)
        return Fixture(engine: engine, workspaceId: workspaceId, frame: frame, gap: gap, tokens: tokens, state: state)
    }

    func testWindowSpansMatchTheLayoutFrames() {
        var fixture = makeFixture()
        fixture.stack(3, onto: 2)
        let frames = fixture.frames()
        for index in [2, 3] {
            let span = fixture.span(of: index)
            XCTAssertEqual(span.minY, frames[fixture.tokens[index]]?.minY ?? .nan, accuracy: 1, "\(index)")
            XCTAssertEqual(span.maxY, frames[fixture.tokens[index]]?.maxY ?? .nan, accuracy: 1, "\(index)")
        }
        XCTAssertLessThan(fixture.span(of: 2).maxY, fixture.span(of: 3).minY)
    }

    func testStackBelowOpensTheGapBelowTheTargetAndStacksOnRelease() {
        var fixture = makeFixture()
        let target = fixture.column(2)
        let columnsBefore = fixture.strip().map(\.minX)
        let offsetBefore = fixture.state.viewOffset
        XCTAssertTrue(fixture.begin(1))

        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 2)), .changed)

        XCTAssertTrue(fixture.window(1).parent === target)
        XCTAssertLessThan(fixture.span(of: 1).maxY, fixture.span(of: 2).minY)
        XCTAssertEqual(fixture.strip().map(\.minX), columnsBefore)
        XCTAssertEqual(fixture.state.viewOffset, offsetBefore, accuracy: 0.5)

        XCTAssertTrue(fixture.endStacking())
        XCTAssertTrue(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))
        XCTAssertEqual(fixture.strip().map(\.minX), columnsBefore)
        XCTAssertTrue(fixture.finishStackDrop())

        XCTAssertEqual(fixture.columnOrder(), [
            [fixture.tokens[0]],
            [fixture.tokens[1], fixture.tokens[2]],
            [fixture.tokens[3]],
            [fixture.tokens[4]]
        ])
        XCTAssertLessThan(fixture.span(of: 1).maxY, fixture.span(of: 2).minY)
        XCTAssertEqual(fixture.state.selectedNodeId, fixture.window(1).id)
        XCTAssertFalse(fixture.engine.isLiveColumnMoveActive(in: fixture.workspaceId))
    }

    func testLeavingAStackWhoseOtherWindowIsHiddenKeepsTheStripInPlace() {
        var fixture = makeFixture()
        fixture.stack(4, onto: 1)
        let home = fixture.column(1)
        let target = fixture.column(2)
        fixture.engine.setProjectionExclusions([fixture.tokens[4]], in: fixture.workspaceId)
        let placesBefore = fixture.strip().map { ($0.column.id, $0.minX) }
        XCTAssertTrue(fixture.begin(1))
        let cursor = fixture.lowerHalf(of: 2)

        XCTAssertEqual(fixture.setStackMode(true, at: cursor), .changed)

        XCTAssertTrue(fixture.window(1).parent === target)
        XCTAssertTrue(fixture.strip().contains { $0.column === home })
        XCTAssertEqual(
            fixture.stripColumn(target).minX,
            placesBefore.first { $0.0 == target.id }?.1 ?? .nan,
            accuracy: 0.5
        )
        XCTAssertEqual(fixture.move(to: cursor), .unchanged)
        XCTAssertTrue(fixture.window(1).parent === target)
    }

    func testStackAbovePutsTheWindowAboveTheTarget() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))

        XCTAssertEqual(fixture.setStackMode(true, at: fixture.upperHalf(of: 2)), .changed)
        XCTAssertGreaterThan(fixture.span(of: 1).minY, fixture.span(of: 2).maxY)

        XCTAssertTrue(fixture.endStacking())
        XCTAssertTrue(fixture.finishStackDrop())
        XCTAssertEqual(fixture.columnOrder()[1], [fixture.tokens[2], fixture.tokens[1]])
        XCTAssertGreaterThan(fixture.span(of: 1).minY, fixture.span(of: 2).maxY)
    }

    func testOnlyTheHoveredColumnMakesRoomAndReturnsToNormal() {
        var fixture = makeFixture()
        let columns = (0 ..< 5).map { fixture.column($0) }
        let stripBefore = fixture.strip().map(\.minX)
        let spansBefore = columns.map { column in fixture.spans(column).map(\.minY) }
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 2)), .changed)

        for index in [3, 4] {
            XCTAssertEqual(fixture.move(to: fixture.lowerHalf(of: index)), .changed, "\(index)")
            XCTAssertTrue(fixture.window(1).parent === columns[index], "\(index)")
            for other in columns.indices where other != index && other != 1 {
                XCTAssertEqual(fixture.spans(columns[other]).map(\.minY), spansBefore[other], "\(index) \(other)")
            }
            XCTAssertEqual(fixture.strip().map(\.minX), stripBefore, "\(index)")
        }

        XCTAssertEqual(fixture.move(to: CGPoint(x: fixture.stripColumn(columns[1]).midX, y: 450)), .changed)
        XCTAssertTrue(fixture.window(1).parent === columns[1])
        for index in columns.indices {
            XCTAssertEqual(fixture.spans(columns[index]).map(\.minY), spansBefore[index], "\(index)")
        }
        XCTAssertEqual(fixture.columnOrder().map(\.count), [1, 1, 1, 1, 1])
    }

    func testAMovePastAColumnBeforeStackModeStays() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.move(to: fixture.point(inColumnOf: 2, y: 450)), .changed)
        XCTAssertEqual(fixture.engine.liveColumnMove?.swapCount, 1)

        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 3)), .changed)
        XCTAssertTrue(fixture.endStacking())
        XCTAssertTrue(fixture.finishStackDrop())

        XCTAssertEqual(fixture.columnOrder(), [
            [fixture.tokens[0]],
            [fixture.tokens[2]],
            [fixture.tokens[1], fixture.tokens[3]],
            [fixture.tokens[4]]
        ])
    }

    func testReleasingTheModifierClosesTheGapAndWaitsForThePointerToMove() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        let cursor = fixture.lowerHalf(of: 2)
        XCTAssertEqual(fixture.setStackMode(true, at: cursor), .changed)

        XCTAssertEqual(fixture.setStackMode(false, at: cursor), .changed)
        XCTAssertTrue(fixture.window(1).parent === fixture.column(1))
        XCTAssertEqual(fixture.columnOrder().map(\.count), [1, 1, 1, 1, 1])
        XCTAssertFalse(fixture.engine.liveColumnMoveWouldChange(
            cursor: cursor,
            strip: fixture.strip(),
            context: fixture.context
        ))
        XCTAssertEqual(fixture.move(to: cursor), .unchanged)
        XCTAssertEqual(fixture.columnOrder(), (0 ..< 5).map { [fixture.tokens[$0]] })

        XCTAssertEqual(fixture.move(to: CGPoint(x: cursor.x + 1, y: cursor.y)), .changed)
        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
        XCTAssertEqual(fixture.columnOrder(), [0, 2, 1, 3, 4].map { [fixture.tokens[$0]] })
    }

    func testAReleaseWithoutTheModifierDropsTheWindowAsUsual() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 2)), .changed)

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))

        XCTAssertFalse(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))
        XCTAssertEqual(fixture.columnOrder(), (0 ..< 5).map { [fixture.tokens[$0]] })
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.isLiveHomeSpot })
    }

    func testAThirdWindowSharesTheColumnEqually() {
        var fixture = makeFixture()
        fixture.stack(3, onto: 2)
        XCTAssertTrue(fixture.begin(1))

        XCTAssertEqual(fixture.setStackMode(true, at: fixture.upperHalf(of: 2)), .changed)
        XCTAssertTrue(fixture.endStacking())
        XCTAssertTrue(fixture.finishStackDrop())

        let heights = fixture.spans(fixture.column(2)).map { $0.maxY - $0.minY }
        XCTAssertEqual(heights.count, 3)
        for height in heights {
            XCTAssertEqual(height, heights[0], accuracy: 0.5)
        }
        XCTAssertEqual(fixture.column(2).windowNodes.map(\.token), [2, 1, 3].map { fixture.tokens[$0] })
    }

    func testAPartlyVisibleTargetStaysWhileTheWindowLandsThenTheOldColumnCloses() {
        var fixture = makeFixture()
        let target = fixture.column(3)
        let home = fixture.column(1)
        let span = fixture.stripColumn(target).maxX - fixture.stripColumn(target).minX
        fixture.scrollSoThat(target, startsAt: fixture.frame.maxX - span / 2)
        XCTAssertTrue(fixture.begin(1))
        let targetX = fixture.stripColumn(target).minX
        let homeSpan = fixture.stripColumn(home).maxX - fixture.stripColumn(home).minX
        let cursor = CGPoint(x: fixture.frame.maxX - span / 4, y: fixture.lowerHalf(of: 3).y)

        XCTAssertEqual(fixture.setStackMode(true, at: cursor), .changed)
        XCTAssertEqual(fixture.stripColumn(target).minX, targetX, accuracy: 0.5)
        XCTAssertTrue(fixture.endStacking())
        XCTAssertEqual(fixture.stripColumn(target).minX, targetX, accuracy: 0.5)

        XCTAssertTrue(fixture.finishStackDrop())
        let placed = fixture.stripColumn(target)
        XCTAssertEqual(placed.minX, targetX - homeSpan - fixture.gap, accuracy: 0.5)
        XCTAssertLessThanOrEqual(placed.maxX, fixture.frame.maxX - fixture.gap + 0.5)
    }

    func testTheStripScrollsOnlyAsFarAsNeededWhenClosingTheOldColumnIsNotEnough() {
        var fixture = makeFixture(widths: [1.0 / 3.0, 0.1, 1.0 / 3.0, 1.0 / 3.0, 2.0 / 3.0, 1.0 / 3.0], activeIndex: 1)
        let target = fixture.column(4)
        let span = fixture.stripColumn(target).maxX - fixture.stripColumn(target).minX
        fixture.scrollSoThat(target, startsAt: fixture.frame.maxX - span / 3)
        XCTAssertTrue(fixture.begin(1))
        let cursor = CGPoint(x: fixture.frame.maxX - span / 6, y: fixture.lowerHalf(of: 4).y)

        XCTAssertEqual(fixture.setStackMode(true, at: cursor), .changed)
        XCTAssertTrue(fixture.endStacking())
        XCTAssertTrue(fixture.finishStackDrop())

        XCTAssertEqual(fixture.stripColumn(target).maxX, fixture.frame.maxX - fixture.gap, accuracy: 0.5)
    }

    func testAStackOfTheOnlyTwoColumnsKeepsTheTargetsWidthDuringTheDragAndAfterTheDrop() {
        var fixture = makeFixture(widths: [0.3, 0.4], activeIndex: 0)
        let width = fixture.stripColumn(fixture.column(1)).width
        XCTAssertTrue(fixture.begin(0))

        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 1)), .changed)
        XCTAssertTrue(fixture.window(0).parent === fixture.column(1))
        XCTAssertEqual(fixture.stripColumn(fixture.column(1)).width, width, accuracy: 0.5)

        XCTAssertTrue(fixture.endStacking())
        XCTAssertTrue(fixture.finishStackDrop())
        XCTAssertEqual(fixture.columnOrder(), [[fixture.tokens[0], fixture.tokens[1]]])
        XCTAssertEqual(fixture.stripColumn(fixture.column(1)).width, width, accuracy: 0.5)
    }

    func testGoingHomeFromAStackGapGivesTheColumnsBackTheirFit() {
        var fixture = makeFixture(widths: [0.3, 0.4], activeIndex: 0)
        XCTAssertTrue(fixture.begin(0))
        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 1)), .changed)
        XCTAssertNotNil(fixture.engine.ensureState(for: fixture.workspaceId).manualWidthColumnCount)

        XCTAssertEqual(fixture.setStackMode(false, at: fixture.lowerHalf(of: 1)), .changed)

        XCTAssertNil(fixture.engine.ensureState(for: fixture.workspaceId).manualWidthColumnCount)
        XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))
        XCTAssertNil(fixture.engine.ensureState(for: fixture.workspaceId).manualWidthColumnCount)
    }

    func testCancelInStackModeRestoresTheLayoutFromBeforeTheDrag() {
        var fixture = makeFixture()
        let order = fixture.columnOrder()
        let original = fixture.state
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.move(to: fixture.point(inColumnOf: 2, y: 450)), .changed)
        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 3)), .changed)

        XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))

        XCTAssertEqual(fixture.columnOrder(), order)
        XCTAssertEqual(fixture.state.viewOffset, original.viewOffset, accuracy: 0.5)
        XCTAssertEqual(fixture.state.selectedNodeId, original.selectedNodeId)
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.windowNodes.isEmpty })
        XCTAssertEqual(fixture.column(1).width, .proportion(1.0 / 3.0))
    }

    func testTheGapKeepsTheHomeSpotInPlaceAtItsWidthEvenWithHiddenWindows() {
        var fixture = makeFixture()
        fixture.engine.setProjectionExclusions([fixture.tokens[4]], in: fixture.workspaceId)
        let home = fixture.column(1)
        let homeBefore = fixture.stripColumn(home)
        XCTAssertTrue(fixture.begin(1))

        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 2)), .changed)

        XCTAssertTrue(home.windowNodes.isEmpty)
        XCTAssertTrue(home.isLiveHomeSpot)
        let homeNow = fixture.stripColumn(home)
        XCTAssertEqual(homeNow.minX, homeBefore.minX, accuracy: 0.5)
        XCTAssertEqual(homeNow.maxX, homeBefore.maxX, accuracy: 0.5)
        XCTAssertTrue(fixture.engine.isLiveDraggedColumn(home))
    }

    func testAColumnThatCannotHoldTheWindowOpensNoGapAndTheDropIsNormal() {
        var fixture = makeFixture()
        fixture.window(2).constraints = WindowSizeConstraints(
            minSize: CGSize(width: 1, height: 880),
            maxSize: .zero,
            isFixed: false
        )
        XCTAssertTrue(fixture.begin(1))

        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 2)), .unchanged)
        XCTAssertTrue(fixture.window(1).parent === fixture.column(1))

        XCTAssertTrue(fixture.endStacking())
        XCTAssertFalse(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))
        XCTAssertEqual(fixture.columnOrder(), (0 ..< 5).map { [fixture.tokens[$0]] })
    }

    func testTheLockHoldsTheGapUntilThePointerMovesThirtyPoints() {
        var fixture = makeFixture()
        fixture.stack(3, onto: 2)
        XCTAssertTrue(fixture.begin(1))
        let cursor = fixture.lowerHalf(of: 2)
        XCTAssertEqual(fixture.setStackMode(true, at: cursor), .changed)
        let landing = fixture.engine.liveColumnMove?.landing
        fixture.engine.liveColumnMove?.stackSuppressPoint = cursor
        let elsewhere = fixture.upperHalf(of: 3)

        XCTAssertEqual(fixture.move(to: CGPoint(x: cursor.x, y: cursor.y + 29)), .unchanged)
        XCTAssertEqual(fixture.engine.liveColumnMove?.landing, landing)
        XCTAssertEqual(fixture.move(to: elsewhere), .changed)
        XCTAssertNotEqual(fixture.engine.liveColumnMove?.landing, landing)
        XCTAssertNil(fixture.engine.liveColumnMove?.stackSuppressPoint)
    }

    func testAPointerLeftOutsideTheGapSetsTheLockAndOneInsideDoesNot() {
        var fixture = makeFixture()
        fixture.stack(3, onto: 2)
        XCTAssertTrue(fixture.begin(1))
        let inside = fixture.lowerHalf(of: 4)
        XCTAssertEqual(fixture.setStackMode(true, at: inside), .changed)
        XCTAssertTrue(fixture.span(of: 1).contains(y: inside.y))
        XCTAssertNil(fixture.engine.liveColumnMove?.stackSuppressPoint)

        let lower = fixture.span(of: 2)
        let outside = fixture.point(inColumnOf: 2, y: lower.minY + (lower.maxY - lower.minY) * 0.6)
        XCTAssertEqual(fixture.move(to: outside), .changed)
        XCTAssertEqual(fixture.column(2).windowNodes.map(\.token), [2, 1, 3].map { fixture.tokens[$0] })
        XCTAssertFalse(fixture.span(of: 1).contains(y: outside.y))
        XCTAssertEqual(fixture.engine.liveColumnMove?.stackSuppressPoint, outside)
    }

    func testATabbedTargetGainsANewTabAfterTheActiveOneAndShowsItOnRelease() {
        var fixture = makeFixture()
        let column = fixture.makeTabbed(3)
        let shown = column.windowNodes[1]
        let frames = fixture.frames()
        XCTAssertTrue(fixture.begin(1))

        XCTAssertEqual(fixture.setStackMode(true, at: fixture.point(inColumnOf: 3, y: 100)), .changed)
        XCTAssertEqual(column.windowNodes.count, 4)
        XCTAssertTrue(column.windowNodes[1] === fixture.window(1))
        XCTAssertTrue(column.windowNodes[column.activeTileIdx] === shown)
        let visualIndex = { (window: NiriWindow) in
            column.windowNodes.count - 1 - column.windowNodes.firstIndex { $0 === window }!
        }
        XCTAssertEqual(visualIndex(fixture.window(1)), visualIndex(shown) + 1)
        XCTAssertEqual(fixture.frames()[shown.token], frames[shown.token])
        XCTAssertEqual(fixture.move(to: fixture.point(inColumnOf: 3, y: 800)), .unchanged)

        XCTAssertTrue(fixture.endStacking())
        XCTAssertTrue(fixture.finishStackDrop())
        XCTAssertTrue(column.isTabbed)
        XCTAssertTrue(column.windowNodes[column.activeTileIdx] === fixture.window(1))
        XCTAssertFalse(fixture.window(1).isHiddenInTabbedMode)
        XCTAssertTrue(shown.isHiddenInTabbedMode)
    }

    func testATabbedColumnTakesTheFullHeightWithNaturalDragOn() {
        var fixture = makeFixture()
        let column = makeTabbedColumnWithAResizedTab(&fixture)
        fixture.engine.tabbedColumnsFillHeight = true

        let frames = fixture.frames()

        for window in column.windowNodes {
            XCTAssertEqual(frames[window.token]?.height ?? .nan, fullTabHeight(fixture), accuracy: 1)
        }
    }

    func testATabbedColumnKeepsAFixedTabHeightWithNaturalDragOff() {
        var fixture = makeFixture()
        let column = makeTabbedColumnWithAResizedTab(&fixture)

        let frames = fixture.frames()

        for window in column.windowNodes {
            XCTAssertEqual(frames[window.token]?.height ?? .nan, 400, accuracy: 1)
        }
    }

    func testTurningTheFlagOnRelaysOutCachedTabbedColumns() {
        var fixture = makeFixture()
        let column = makeTabbedColumnWithAResizedTab(&fixture)
        let shown = column.windowNodes[column.activeTileIdx]
        XCTAssertEqual(fixture.frames()[shown.token]?.height ?? .nan, 400, accuracy: 1)

        fixture.engine.updateConfiguration(tabbedColumnsFillHeight: true)

        XCTAssertEqual(fixture.frames()[shown.token]?.height ?? .nan, fullTabHeight(fixture), accuracy: 1)
    }

    func testATabbedColumnTurnedNormalGetsItsResizedHeightBack() {
        var fixture = makeFixture()
        let column = makeTabbedColumnWithAResizedTab(&fixture)
        fixture.engine.tabbedColumnsFillHeight = true
        XCTAssertEqual(fixture.frames()[fixture.tokens[2]]?.height ?? .nan, fullTabHeight(fixture), accuracy: 1)

        column.displayMode = .normal
        fixture.engine.updateTabbedColumnVisibility(column: column)

        XCTAssertEqual(fixture.frames()[fixture.tokens[2]]?.height ?? .nan, 400, accuracy: 1)
    }

    private func makeTabbedColumnWithAResizedTab(_ fixture: inout Fixture) -> NiriContainer {
        fixture.window(2).height = .fixed(400)
        fixture.stack(3, onto: 2)
        let column = fixture.column(2)
        column.displayMode = .tabbed
        column.setActiveTileIdx(0)
        fixture.engine.updateTabbedColumnVisibility(column: column)
        return column
    }

    private func fullTabHeight(_ fixture: Fixture) -> CGFloat {
        fixture.frame.height - 2 * fixture.gap
    }

    func testTheLandingGapFollowsThePointerWhileSettling() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.setStackMode(true, at: fixture.upperHalf(of: 2)), .changed)
        XCTAssertEqual(
            fixture.engine.liveColumnMoveUpdate(
                cursor: fixture.middle(of: 3),
                at: 0,
                context: fixture.context,
                state: &fixture.state
            ),
            .changed
        )
        XCTAssertEqual(fixture.engine.liveColumnMove?.phase, .settling)

        XCTAssertEqual(
            fixture.engine.liveColumnMoveUpdate(
                cursor: fixture.upperHalf(of: 4),
                at: 0,
                context: fixture.context,
                state: &fixture.state
            ),
            .changed
        )
        XCTAssertEqual(fixture.engine.liveColumnMove?.landing?.columnId, fixture.column(4).id)
    }

    func testStackingOntoALoneWindowSharesTheColumnEvenly() {
        var fixture = makeFixture()
        fixture.window(2).height = .auto(weight: 4.8)
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.setStackMode(true, at: fixture.upperHalf(of: 2)), .changed)

        XCTAssertTrue(fixture.endStacking())
        XCTAssertTrue(fixture.finishStackDrop())

        let frames = fixture.frames()
        XCTAssertEqual(
            frames[fixture.tokens[1]]?.height ?? .nan,
            frames[fixture.tokens[2]]?.height ?? .nan,
            accuracy: 1
        )
    }

    func testStackingOntoALoneResizedWindowSharesTheColumnEvenlyToo() {
        var fixture = makeFixture()
        fixture.window(2).height = .fixed(fixture.frame.height - 2 * fixture.gap)
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.setStackMode(true, at: fixture.upperHalf(of: 2)), .changed)

        XCTAssertTrue(fixture.endStacking())
        XCTAssertTrue(fixture.finishStackDrop())

        let frames = fixture.frames()
        XCTAssertEqual(
            frames[fixture.tokens[1]]?.height ?? .nan,
            frames[fixture.tokens[2]]?.height ?? .nan,
            accuracy: 1
        )
    }

    func testALoneWindowGetsItsHeightBackWhenTheLandingGapLeaves() {
        var fixture = makeFixture()
        fixture.window(2).height = .fixed(300)
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.setStackMode(true, at: fixture.upperHalf(of: 2)), .changed)
        XCTAssertEqual(fixture.window(2).height, .default)

        XCTAssertEqual(fixture.move(to: fixture.middle(of: 3)), .changed)
        XCTAssertEqual(fixture.window(2).height, .fixed(300))

        XCTAssertEqual(fixture.move(to: fixture.upperHalf(of: 2)), .changed)
        XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))
        XCTAssertEqual(fixture.window(2).height, .fixed(300))
    }

    func testAFreeAreaIsFoundAboveAResizedWindow() throws {
        var fixture = makeFixture()
        fixture.window(2).height = .fixed(400)
        XCTAssertTrue(fixture.begin(1))
        let move = try XCTUnwrap(fixture.engine.liveColumnMove)

        let area = fixture.engine.liveFreeArea(
            at: fixture.point(inColumnOf: 2, y: 700),
            strip: fixture.strip(),
            move: move,
            context: fixture.context
        )

        XCTAssertEqual(
            area?.landing,
            .init(columnId: fixture.column(2).id, targetWindowId: fixture.window(2).id, above: true)
        )
        XCTAssertEqual(area?.height ?? .nan, freeAreaHeight(fixture, below: 400), accuracy: 0.5)
        XCTAssertNil(fixture.engine.liveFreeArea(
            at: fixture.point(inColumnOf: 2, y: 200),
            strip: fixture.strip(),
            move: move,
            context: fixture.context
        ))
    }

    func testRoomUnderTheMinimumIsNotAFreeArea() throws {
        var fixture = makeFixture()
        let height = fixture.frame.height - 4 * fixture.gap - 60
        fixture.window(2).height = .fixed(height)
        XCTAssertTrue(fixture.begin(1))
        let move = try XCTUnwrap(fixture.engine.liveColumnMove)

        XCTAssertNil(fixture.engine.liveFreeArea(
            at: fixture.point(inColumnOf: 2, y: fixture.frame.maxY - fixture.gap - 10),
            strip: fixture.strip(),
            move: move,
            context: fixture.context
        ))
    }

    func testTabbedColumnsAndTheHomeColumnHaveNoFreeArea() throws {
        var fixture = makeFixture()
        fixture.window(2).height = .fixed(400)
        let tabbed = fixture.makeTabbed(3, tabCount: 2, activeTab: 0)
        for window in tabbed.windowNodes {
            window.height = .fixed(400)
        }
        XCTAssertTrue(fixture.begin(2))
        let move = try XCTUnwrap(fixture.engine.liveColumnMove)

        for index in [2, 3] {
            XCTAssertNil(fixture.engine.liveFreeArea(
                at: fixture.point(inColumnOf: index, y: 700),
                strip: fixture.strip(),
                move: move,
                context: fixture.context
            ), "\(index)")
        }
    }

    func testHoveringAFreeAreaChangesNothing() {
        var fixture = makeFixture()
        fixture.window(2).height = .fixed(400)
        let order = fixture.columnOrder()
        XCTAssertTrue(fixture.begin(1))

        XCTAssertEqual(fixture.move(to: fixture.point(inColumnOf: 2, y: 700), at: 1), .unchanged)
        XCTAssertEqual(fixture.move(to: fixture.point(inColumnOf: 2, y: 710), at: 2), .unchanged)

        XCTAssertEqual(fixture.columnOrder(), order)
        XCTAssertNil(fixture.engine.liveColumnMove?.dropSpaceId)
        XCTAssertFalse(fixture.engine.liveColumnMoveWouldChange(
            cursor: fixture.point(inColumnOf: 2, y: 720),
            strip: fixture.strip(),
            context: fixture.context
        ))
    }

    func testInStackModeAFreeAreaClosesTheLandingGapElsewhere() {
        var fixture = makeFixture()
        fixture.window(2).height = .fixed(400)
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.setStackMode(true, at: fixture.middle(of: 3)), .changed)
        XCTAssertTrue(fixture.window(1).parent === fixture.column(3))

        XCTAssertEqual(fixture.move(to: fixture.point(inColumnOf: 2, y: 700)), .changed)

        XCTAssertNil(fixture.engine.liveColumnMove?.landing)
        XCTAssertFalse(fixture.window(1).parent === fixture.column(3))
        XCTAssertEqual(fixture.move(to: fixture.point(inColumnOf: 2, y: 710)), .unchanged)
    }

    func testReleasingOverAFreeAreaStacksIntoIt() {
        var fixture = makeFixture()
        fixture.window(2).height = .fixed(400)
        let resizedFrame = fixture.frames()[fixture.tokens[2]]
        let columnCount = fixture.columnOrder().count
        XCTAssertTrue(fixture.begin(1))
        let release = fixture.point(inColumnOf: 2, y: 700)
        XCTAssertEqual(fixture.move(to: release, at: 1), .unchanged)

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(
            releasedAt: release,
            context: fixture.context,
            state: &fixture.state
        ))
        XCTAssertTrue(fixture.finishStackDrop())

        assertStackedIntoTheFreeArea(fixture, resizedFrame: resizedFrame, columnCount: columnCount)
    }

    func testReleasingOverAFreeAreaWithOptionStacksTheSameWay() {
        var fixture = makeFixture()
        fixture.window(2).height = .fixed(400)
        let resizedFrame = fixture.frames()[fixture.tokens[2]]
        let columnCount = fixture.columnOrder().count
        XCTAssertTrue(fixture.begin(1))
        let release = fixture.point(inColumnOf: 2, y: 700)
        _ = fixture.setStackMode(true, at: release)

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(
            releasedAt: release,
            stacking: true,
            context: fixture.context,
            state: &fixture.state
        ))
        XCTAssertTrue(fixture.finishStackDrop())

        assertStackedIntoTheFreeArea(fixture, resizedFrame: resizedFrame, columnCount: columnCount)
    }

    func testCancellingAfterHoveringAFreeAreaRestoresTheLayout() {
        var fixture = makeFixture()
        fixture.window(2).height = .fixed(400)
        let order = fixture.columnOrder()
        let height = fixture.window(1).height
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.move(to: fixture.point(inColumnOf: 2, y: 700), at: 1), .unchanged)

        XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))

        XCTAssertEqual(fixture.columnOrder(), order)
        XCTAssertEqual(fixture.window(1).height, height)
    }

    func testAWholeTabbedColumnReleasedOverAFreeAreaStaysWhole() throws {
        var fixture = makeFixture()
        fixture.window(2).height = .fixed(400)
        let tabbed = fixture.makeTabbed(1, tabCount: 2, activeTab: 0)
        let tabs = tabbed.windowNodes.map(\.token)
        XCTAssertTrue(fixture.begin(1))
        let move = try XCTUnwrap(fixture.engine.liveColumnMove)
        XCTAssertTrue(move.isWholeColumn)
        let release = fixture.point(inColumnOf: 2, y: 700)
        XCTAssertNil(fixture.engine.liveFreeArea(
            at: release,
            strip: fixture.strip(),
            move: move,
            context: fixture.context
        ))

        _ = fixture.move(to: release, at: 1)
        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(
            releasedAt: release,
            context: fixture.context,
            state: &fixture.state
        ))

        XCTAssertFalse(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))
        XCTAssertEqual(tabbed.windowNodes.map(\.token), tabs)
        XCTAssertEqual(fixture.column(2).windowNodes.map(\.token), [fixture.tokens[2]])
    }

    func testAFreeAreaDropKeepsTheLoneWindowsHeightAndFrame() {
        var fixture = makeFixture()
        fixture.motion = .enabled
        fixture.window(2).height = .fixed(400)
        let resizedFrame = fixture.frames()[fixture.tokens[2]]
        XCTAssertTrue(fixture.begin(1))
        let release = fixture.point(inColumnOf: 2, y: 700)
        XCTAssertEqual(fixture.move(to: release, at: 1), .unchanged)

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(
            releasedAt: release,
            context: fixture.context,
            state: &fixture.state
        ))

        XCTAssertNil(fixture.window(2).heightAnimation)
        XCTAssertEqual(
            fixture.frames(at: CACurrentMediaTime())[fixture.tokens[2]]?.height ?? 0,
            resizedFrame?.height ?? 0,
            accuracy: 1
        )
        XCTAssertTrue(fixture.finishStackDrop())
        XCTAssertEqual(fixture.window(2).height, .fixed(400))
    }

    func testALoneWindowGetsItsHeightBackWhenTheDragIsCutOff() {
        var fixture = makeFixture()
        fixture.window(2).height = .fixed(300)
        XCTAssertTrue(fixture.begin(1))
        _ = fixture.setStackMode(true, at: fixture.upperHalf(of: 2))
        XCTAssertNotNil(fixture.engine.liveColumnMove?.landing)
        XCTAssertEqual(fixture.window(2).height, .default)

        fixture.engine.cancelInteractions(for: [fixture.window(1).id], in: fixture.workspaceId)

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertEqual(fixture.window(2).height, .fixed(300))
    }

    func testASecondStackDropBeforeTheFirstSettlesLeavesNoBlankColumn() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 2)), .changed)
        XCTAssertTrue(fixture.endStacking())
        XCTAssertTrue(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))

        if fixture.begin(3) {
            XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 4)), .changed)
            XCTAssertTrue(fixture.endStacking())
        }
        _ = fixture.finishStackDrop()

        XCTAssertFalse(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.windowNodes.isEmpty })
    }

    func testAColumnWhoseOnlyMateIsHiddenMovesAsAWholeColumn() {
        var fixture = makeFixture()
        fixture.stack(3, onto: 2)
        fixture.engine.setProjectionExclusions([fixture.tokens[3]], in: fixture.workspaceId)
        let column = fixture.column(2)
        XCTAssertEqual(column.windowNodes.count, 2)

        XCTAssertTrue(fixture.begin(2))
        XCTAssertEqual(fixture.engine.liveColumnMove?.inStack, false)
        _ = fixture.move(to: fixture.lowerHalf(of: 1), at: 1)
        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))

        XCTAssertEqual(fixture.column(2).windowNodes.map(\.token), [fixture.tokens[2], fixture.tokens[3]])
    }

    func testGoingHomeBesideAHiddenMateKeepsTheStackOrder() {
        var fixture = makeFixture()
        fixture.stack(3, onto: 2)
        fixture.engine.setProjectionExclusions([fixture.tokens[2]], in: fixture.workspaceId)
        let home = fixture.column(2)
        XCTAssertEqual(fixture.storage(home), [fixture.tokens[2], fixture.tokens[3]])

        XCTAssertTrue(fixture.begin(3))
        XCTAssertEqual(fixture.engine.liveColumnMove?.inStack, false)
        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 1)), .changed)
        XCTAssertEqual(fixture.setStackMode(false, at: fixture.lowerHalf(of: 1)), .changed)

        XCTAssertTrue(fixture.window(3).parent === home)
        XCTAssertEqual(fixture.storage(home), [fixture.tokens[2], fixture.tokens[3]])
    }

    private func freeAreaHeight(_ fixture: Fixture, below windowHeight: CGFloat) -> CGFloat {
        fixture.frame.height - 3 * fixture.gap - windowHeight
    }

    private func assertStackedIntoTheFreeArea(
        _ fixture: Fixture,
        resizedFrame: CGRect?,
        columnCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let column = fixture.column(2)
        XCTAssertEqual(fixture.storage(column), [fixture.tokens[2], fixture.tokens[1]], file: file, line: line)
        XCTAssertEqual(fixture.columnOrder().count, columnCount - 1, file: file, line: line)
        let frames = fixture.frames()
        XCTAssertEqual(frames[fixture.tokens[2]]?.minY, resizedFrame?.minY, file: file, line: line)
        XCTAssertEqual(frames[fixture.tokens[2]]?.height, resizedFrame?.height, file: file, line: line)
        let dropped = frames[fixture.tokens[1]]
        XCTAssertEqual(
            dropped?.height ?? .nan,
            freeAreaHeight(fixture, below: 400),
            accuracy: 1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            dropped?.maxY ?? .nan,
            fixture.frame.maxY - fixture.gap,
            accuracy: 1,
            file: file,
            line: line
        )
    }

    func testAOneWindowTabbedTargetGainsItsRailWhileHoveredAndLosesItAfter() {
        var fixture = makeFixture()
        let column = fixture.makeTabbed(3, tabCount: 1, activeTab: 0)
        let shownFrame = fixture.frames()[fixture.tokens[3]]
        XCTAssertTrue(fixture.begin(1))

        XCTAssertEqual(fixture.setStackMode(true, at: fixture.point(inColumnOf: 3, y: 450)), .changed)
        XCTAssertEqual(column.windowNodes.count, 2)
        XCTAssertNotEqual(fixture.frames()[fixture.tokens[3]]?.minX, shownFrame?.minX)

        XCTAssertEqual(fixture.move(to: fixture.point(inColumnOf: 0, y: 450)), .changed)
        XCTAssertEqual(column.windowNodes.count, 1)
        XCTAssertEqual(fixture.frames()[fixture.tokens[3]]?.minX ?? .nan, shownFrame?.minX ?? .nan, accuracy: 0.5)
    }

    func testADraggedTabbedColumnIgnoresTheModifier() {
        var fixture = makeFixture()
        _ = fixture.makeTabbed(1)
        XCTAssertTrue(fixture.begin(1))

        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 2)), .unchanged)

        XCTAssertEqual(fixture.engine.liveColumnMove?.stackMode, false)
        XCTAssertEqual(fixture.column(2).windowNodes.count, 1)
    }

    func testTheEdgeScrollCheckSeesGapChangesButNoSwapsInStackMode() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 2)), .changed)

        XCTAssertFalse(fixture.engine.liveColumnMoveWouldChange(
            cursor: fixture.lowerHalf(of: 2),
            strip: fixture.strip(),
            context: fixture.context
        ))
        XCTAssertTrue(fixture.engine.liveColumnMoveWouldChange(
            cursor: fixture.lowerHalf(of: 3),
            strip: fixture.strip(),
            context: fixture.context
        ))
    }

    func testClosingTheDraggedWindowInATargetColumnLeavesNoEmptyColumn() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 2)), .changed)
        let dragged = fixture.window(1)

        fixture.engine.cancelInteractions(for: [dragged.id], in: fixture.workspaceId)
        fixture.engine.removeWindow(token: fixture.tokens[1], in: fixture.workspaceId)

        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.windowNodes.isEmpty })
        XCTAssertEqual(fixture.column(2).windowNodes.map(\.token), [fixture.tokens[2]])
    }

    func testCancellingAPendingStackDropRemovesTheHomeSpot() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 2)), .changed)
        XCTAssertTrue(fixture.endStacking())
        XCTAssertTrue(fixture.engine.columns(in: fixture.workspaceId).contains { $0.isLiveHomeSpot })

        fixture.engine.cancelInteractions(in: fixture.workspaceId)

        XCTAssertFalse(fixture.engine.isLiveStackDropPending(in: fixture.workspaceId))
        XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.windowNodes.isEmpty })
    }

    func testAStackedWindowMovesWithinItsStackAsThePointerReachesItsMates() {
        var fixture = makeFixture()
        fixture.stack(3, onto: 2)
        fixture.stack(4, onto: 3)
        let stack = fixture.column(2)
        let stripBefore = fixture.strip().map(\.minX)
        XCTAssertEqual(fixture.storage(stack), [2, 3, 4].map { fixture.tokens[$0] })
        XCTAssertTrue(fixture.begin(2))
        XCTAssertEqual(fixture.engine.liveColumnMove?.inStack, true)

        XCTAssertEqual(fixture.move(to: fixture.middle(of: 3)), .changed)
        XCTAssertEqual(fixture.storage(stack), [3, 2, 4].map { fixture.tokens[$0] })
        XCTAssertEqual(fixture.move(to: fixture.middle(of: 2)), .unchanged)
        XCTAssertEqual(fixture.move(to: fixture.middle(of: 4)), .changed)
        XCTAssertEqual(fixture.storage(stack), [3, 4, 2].map { fixture.tokens[$0] })
        XCTAssertEqual(fixture.strip().map(\.minX), stripBefore)

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertEqual(fixture.storage(stack), [3, 4, 2].map { fixture.tokens[$0] })
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 3)
        XCTAssertEqual(fixture.state.selectedNodeId, fixture.window(2).id)
    }

    func testLeavingAStackSidewaysOpensAHomeSpotBesideItOnThatSide() {
        for towardTrailing in [false, true] {
            var fixture = makeFixture()
            fixture.stack(3, onto: 2)
            let stack = fixture.column(2)
            let stackX = fixture.stripColumn(stack).minX
            let stackSpan = fixture.stripColumn(stack).maxX - fixture.stripColumn(stack).minX
            XCTAssertTrue(fixture.begin(3))
            let edge = towardTrailing ? fixture.stripColumn(stack).maxX + 20 : stackX - 20

            XCTAssertEqual(fixture.move(to: CGPoint(x: edge, y: fixture.middle(of: 3).y)), .changed)

            let expected = towardTrailing ? [[0], [1], [2], [3], [4]] : [[0], [1], [3], [2], [4]]
            XCTAssertEqual(fixture.columnOrder(), expected.map { $0.map { fixture.tokens[$0] } }, "\(towardTrailing)")
            XCTAssertEqual(fixture.stripColumn(stack).minX, stackX, accuracy: 0.5, "\(towardTrailing)")
            let home = fixture.column(3)
            XCTAssertEqual(
                fixture.stripColumn(home).maxX - fixture.stripColumn(home).minX,
                fixture.frame.width * 0.05,
                accuracy: 0.5,
                "\(towardTrailing)"
            )
            let placedHome = fixture.stripColumn(home)
            let stackNow = fixture.stripColumn(stack)
            XCTAssertEqual(
                towardTrailing ? placedHome.minX - stackNow.maxX : stackNow.minX - placedHome.maxX,
                fixture.gap,
                accuracy: 0.5,
                "\(towardTrailing)"
            )
            XCTAssertEqual(fixture.engine.liveColumnMove?.inStack, false)
            XCTAssertEqual(fixture.engine.liveColumnMove?.homeColumnId, home.id)
            let remaining = fixture.span(of: 2)
            XCTAssertEqual(remaining.maxY - remaining.minY, fixture.frame.height - 2 * fixture.gap, accuracy: 0.5)

            XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
            XCTAssertEqual(fixture.columnOrder(), expected.map { $0.map { fixture.tokens[$0] } }, "\(towardTrailing)")
            XCTAssertFalse(home.isLiveHomeSpot)
            XCTAssertEqual(
                fixture.stripColumn(home).maxX - fixture.stripColumn(home).minX,
                stackSpan,
                accuracy: 0.5,
                "\(towardTrailing)"
            )
        }
    }

    func testCancelAfterMovingWithinOrLeavingAStackRestoresIt() {
        for leaves in [false, true] {
            var fixture = makeFixture()
            fixture.stack(3, onto: 2)
            fixture.window(2).height = .auto(weight: 2)
            let order = fixture.columnOrder()
            let offset = fixture.state.viewOffset
            let stack = fixture.column(2)
            XCTAssertTrue(fixture.begin(2))
            XCTAssertEqual(fixture.move(to: fixture.middle(of: 3)), .changed)
            if leaves {
                XCTAssertEqual(
                    fixture.move(to: CGPoint(x: fixture.stripColumn(stack).maxX + 20, y: 450)),
                    .changed
                )
            }

            XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))

            XCTAssertEqual(fixture.columnOrder(), order, "\(leaves)")
            XCTAssertEqual(fixture.window(2).height, .auto(weight: 2), "\(leaves)")
            XCTAssertEqual(fixture.state.viewOffset, offset, accuracy: 0.5, "\(leaves)")
            XCTAssertFalse(fixture.engine.columns(in: fixture.workspaceId).contains { $0.windowNodes.isEmpty })
        }
    }

    func testStackMatesOfDifferentHeightsKeepTheirHeightsAndMoveOncePerReach() {
        var fixture = makeFixture()
        fixture.stack(3, onto: 2)
        fixture.window(2).height = .auto(weight: 3)
        let stack = fixture.column(2)
        XCTAssertTrue(fixture.begin(3))
        let lower = fixture.span(of: 2)
        let cursor = fixture.point(inColumnOf: 2, y: lower.maxY - 20)

        XCTAssertEqual(fixture.move(to: cursor), .changed)
        XCTAssertEqual(fixture.storage(stack), [3, 2].map { fixture.tokens[$0] })
        XCTAssertEqual(fixture.window(2).height, .auto(weight: 3))
        XCTAssertFalse(fixture.span(of: 3).contains(y: cursor.y))
        XCTAssertNotNil(fixture.engine.liveColumnMove?.stackSuppressPoint)

        XCTAssertEqual(fixture.move(to: CGPoint(x: cursor.x, y: cursor.y - 10)), .unchanged)
        XCTAssertEqual(fixture.storage(stack), [3, 2].map { fixture.tokens[$0] })
    }

    func testTheStackModifierLandsTheWindowAmongItsOwnStackMates() {
        var fixture = makeFixture()
        fixture.stack(3, onto: 2)
        fixture.stack(4, onto: 3)
        XCTAssertTrue(fixture.begin(4))

        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 2)), .changed)
        XCTAssertTrue(fixture.endStacking())
        _ = fixture.finishStackDrop()

        XCTAssertEqual(fixture.columnOrder(), [
            [fixture.tokens[0]],
            [fixture.tokens[1]],
            [4, 2, 3].map { fixture.tokens[$0] }
        ])
    }

    func testReleasingTheModifierReturnsAStackedWindowToItsSlot() {
        var fixture = makeFixture()
        fixture.stack(3, onto: 2)
        fixture.window(3).height = .auto(weight: 2)
        let stack = fixture.column(2)
        XCTAssertTrue(fixture.begin(3))
        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 4)), .changed)
        XCTAssertTrue(fixture.window(3).parent === fixture.column(4))

        let cursor = fixture.lowerHalf(of: 4)
        XCTAssertEqual(fixture.setStackMode(false, at: cursor), .changed)

        XCTAssertEqual(fixture.storage(stack), [2, 3].map { fixture.tokens[$0] })
        XCTAssertEqual(fixture.window(3).height, .auto(weight: 2))
        XCTAssertEqual(fixture.column(4).windowNodes.count, 1)
    }

    func testAWorkspaceWithASingleStackedColumnCanBeDragged() {
        var fixture = makeFixture(widths: [1.0 / 3.0, 1.0 / 3.0], activeIndex: 0)
        fixture.stack(1, onto: 0)
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 1)

        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.engine.liveColumnMove?.inStack, true)
    }

    func testPullingATabOutShowsTheNextTabAndOpensAHomeSpotBeside() {
        var fixture = makeFixture()
        let tabbed = fixture.makeTabbed(2)
        let pulled = tabbed.windowNodes[1]
        let next = tabbed.windowNodes[2]
        XCTAssertTrue(fixture.beginPull(pulled))
        XCTAssertEqual(fixture.engine.liveColumnMove?.inStack, true)
        XCTAssertFalse(fixture.engine.isLiveDraggedColumn(tabbed))

        XCTAssertEqual(fixture.move(to: fixture.point(inColumnOf: 2, y: 200)), .unchanged)
        XCTAssertEqual(tabbed.windowNodes.count, 3)

        let edge = fixture.stripColumn(tabbed).maxX + 20
        XCTAssertEqual(fixture.move(to: CGPoint(x: edge, y: 450)), .changed)

        XCTAssertEqual(tabbed.windowNodes.count, 2)
        XCTAssertTrue(tabbed.isTabbed)
        XCTAssertTrue(tabbed.windowNodes[tabbed.activeTileIdx] === next)
        XCTAssertFalse(next.isHiddenInTabbedMode)
        let home = fixture.engine.findColumn(containing: pulled, in: fixture.workspaceId)
        XCTAssertEqual(fixture.engine.columnIndex(of: home!, in: fixture.workspaceId), 3)
        XCTAssertFalse(pulled.isHiddenInTabbedMode)
    }

    func testPullingTheSecondToLastTabMakesTheColumnNormal() {
        var fixture = makeFixture()
        let tabbed = fixture.makeTabbed(2, tabCount: 2, activeTab: 1)
        let pulled = tabbed.windowNodes[1]
        XCTAssertTrue(fixture.beginPull(pulled))

        XCTAssertEqual(
            fixture.move(to: CGPoint(x: fixture.stripColumn(tabbed).maxX + 20, y: 450)),
            .changed
        )

        XCTAssertEqual(tabbed.displayMode, .normal)
        XCTAssertEqual(tabbed.windowNodes.count, 1)
        XCTAssertFalse(tabbed.windowNodes[0].isHiddenInTabbedMode)
    }

    func testCancellingATabPullRestoresTheTabsAndTheShownTab() {
        var fixture = makeFixture()
        let tabbed = fixture.makeTabbed(2, tabCount: 2, activeTab: 1)
        let tabs = fixture.storage(tabbed)
        let pulled = tabbed.windowNodes[1]
        let order = fixture.engine.columns(in: fixture.workspaceId).map(\.id)
        XCTAssertTrue(fixture.beginPull(pulled))
        XCTAssertEqual(
            fixture.move(to: CGPoint(x: fixture.stripColumn(tabbed).maxX + 20, y: 450)),
            .changed
        )

        XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))

        XCTAssertEqual(fixture.storage(tabbed), tabs)
        XCTAssertEqual(tabbed.displayMode, .tabbed)
        XCTAssertEqual(tabbed.activeTileIdx, 1)
        XCTAssertFalse(pulled.isHiddenInTabbedMode)
        XCTAssertTrue(tabbed.windowNodes[0].isHiddenInTabbedMode)
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).map(\.id), order)
    }

    func testAPulledTabHasAFloatingFrameOnlyWhileTheDragLasts() {
        var fixture = makeFixture()
        let tabbed = fixture.makeTabbed(2)
        let pulled = tabbed.windowNodes[1]
        XCTAssertTrue(fixture.beginPull(pulled))
        let frame = CGRect(x: 300, y: 200, width: 400, height: 500)

        fixture.engine.liveColumnMove?.floatingFrame = frame

        XCTAssertEqual(fixture.engine.liveFloatingFrame(for: pulled.token, in: fixture.workspaceId), frame)
        XCTAssertNil(fixture.engine.liveFloatingFrame(for: tabbed.windowNodes[0].token, in: fixture.workspaceId))
        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(context: fixture.context, state: &fixture.state))
        XCTAssertNil(fixture.engine.liveFloatingFrame(for: pulled.token, in: fixture.workspaceId))
        XCTAssertEqual(fixture.storage(tabbed).count, 3)
        XCTAssertTrue(tabbed.windowNodes[tabbed.activeTileIdx] === pulled)
    }

    func testPullingATabRequiresATabbedColumnAndATitleBarDragStillMovesItWhole() {
        var fixture = makeFixture()
        XCTAssertFalse(fixture.beginPull(fixture.window(2)))
        let tabbed = fixture.makeTabbed(3)
        XCTAssertTrue(fixture.begin(3))
        XCTAssertEqual(fixture.engine.liveColumnMove?.isWholeColumn, true)
        XCTAssertEqual(fixture.engine.liveColumnMove?.inStack, false)
        XCTAssertTrue(fixture.engine.isLiveDraggedColumn(tabbed))
    }

    func testAHeightSpringStartsAtTheOldHeightAndSettlesAtTheNewOne() {
        let window = NiriWindow(token: WindowToken(pid: 943, windowId: 1))
        window.animateHeightFrom(delta: 120, clock: nil, animated: true)
        let now = CACurrentMediaTime()

        XCTAssertEqual(window.renderHeightOffset(at: now), 120, accuracy: 1)
        XCTAssertTrue(window.hasMoveAnimationsRunning)
        XCTAssertEqual(window.renderHeightOffset(at: now + 10), 0, accuracy: 0.5)
        XCTAssertFalse(window.tickMoveAnimations(at: now + 10))
        XCTAssertNil(window.heightAnimation)

        window.animateHeightFrom(delta: 120, clock: nil, animated: false)
        XCTAssertNil(window.heightAnimation)
        XCTAssertEqual(window.renderHeightOffset(at: now), 0)
    }

    func testTheTargetColumnsWindowShrinksSmoothlyWhenTheGapOpens() {
        var fixture = makeFixture()
        fixture.motion = .enabled
        let fullHeight = fixture.frames()[fixture.tokens[2]]?.height ?? 0
        XCTAssertTrue(fixture.begin(1))

        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 2)), .changed)

        let now = CACurrentMediaTime()
        let start = fixture.frames(at: now)[fixture.tokens[2]]?.height ?? 0
        let settled = fixture.frames(at: now + 10)[fixture.tokens[2]]?.height ?? 0
        XCTAssertEqual(start, fullHeight, accuracy: 2)
        XCTAssertEqual(settled, fixture.span(of: 2).maxY - fixture.span(of: 2).minY, accuracy: 1)
        XCTAssertLessThan(settled, fullHeight - 100)
    }

    func testAWindowThatBecomesTiledGlidesFromWhereItWasIntoItsSlot() {
        var fixture = makeFixture(widths: [0.25], activeIndex: 0)
        fixture.motion = .enabled
        let token = WindowToken(pid: 941, windowId: 99)
        let stale = WindowToken(pid: 941, windowId: 98)
        let start = CGRect(x: 300, y: 200, width: 500, height: 400)
        let now = CACurrentMediaTime()
        fixture.engine.noteStripGlide(for: token, from: start, at: now)
        fixture.engine.noteStripGlide(for: stale, from: start, at: now - 5)
        for added in [token, stale] {
            _ = fixture.engine.addWindow(token: added, to: fixture.workspaceId, afterSelection: nil)
        }
        fixture.engine.resolvePrimaryContainerSpans(
            in: fixture.workspaceId,
            workingFrame: fixture.frame,
            gaps: fixture.gap,
            orientation: .horizontal
        )
        let landed = fixture.frames()[token]
        fixture.engine.glideIntoStrip([token, stale], context: fixture.context, state: fixture.state, at: now)

        let first = fixture.frames(at: now)[token]
        XCTAssertEqual(first?.minX ?? 0, start.minX, accuracy: 2)
        XCTAssertEqual(first?.minY ?? 0, start.minY, accuracy: 2)
        XCTAssertEqual(first?.height ?? 0, start.height, accuracy: 2)
        let settled = fixture.frames(at: now + 10)[token]
        XCTAssertEqual(settled?.minX ?? 0, landed?.minX ?? 1, accuracy: 1)
        XCTAssertEqual(settled?.minY ?? 0, landed?.minY ?? 1, accuracy: 1)
        XCTAssertFalse(fixture.engine.findNode(for: stale, in: fixture.workspaceId)?.hasMoveAnimationsRunning ?? true)
        XCTAssertTrue(fixture.engine.stripGlides.isEmpty)
    }

    func testWithAnimationsOffTheHeightChangesAtOnce() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))

        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 2)), .changed)

        XCTAssertNil(fixture.window(2).heightAnimation)
        XCTAssertEqual(
            fixture.frames(at: CACurrentMediaTime())[fixture.tokens[2]]?.height ?? 0,
            fixture.span(of: 2).maxY - fixture.span(of: 2).minY,
            accuracy: 1
        )
    }

    func testAWindowLeavingAStackLetsItsMateGrowSmoothly() {
        var fixture = makeFixture()
        fixture.motion = .enabled
        fixture.stack(3, onto: 2)
        let halfHeight = fixture.span(of: 2).maxY - fixture.span(of: 2).minY
        XCTAssertTrue(fixture.begin(3))

        let edge = fixture.stripColumn(fixture.column(2)).maxX + 20
        XCTAssertEqual(fixture.move(to: CGPoint(x: edge, y: 450)), .changed)

        let now = CACurrentMediaTime()
        XCTAssertEqual(fixture.frames(at: now)[fixture.tokens[2]]?.height ?? 0, halfHeight, accuracy: 2)
        XCTAssertGreaterThan(fixture.frames(at: now + 10)[fixture.tokens[2]]?.height ?? 0, halfHeight + 100)
    }

    func testAWindowDroppedOutOfAStackGrowsToItsFullHeightSmoothly() {
        var fixture = makeFixture()
        fixture.motion = .enabled
        fixture.stack(3, onto: 2)
        let stacked = fixture.span(of: 3)
        XCTAssertTrue(fixture.begin(3))
        let edge = fixture.stripColumn(fixture.column(2)).maxX + 20
        XCTAssertEqual(fixture.move(to: CGPoint(x: edge, y: 450)), .changed)
        let released = CGRect(x: edge, y: stacked.minY, width: 200, height: stacked.maxY - stacked.minY)

        XCTAssertTrue(fixture.engine.liveColumnMoveEnd(
            releasedFrame: released,
            context: fixture.context,
            state: &fixture.state
        ))

        let now = CACurrentMediaTime()
        XCTAssertEqual(fixture.frames(at: now)[fixture.tokens[3]]?.height ?? 0, released.height, accuracy: 2)
        XCTAssertEqual(
            fixture.frames(at: now + 10)[fixture.tokens[3]]?.height ?? 0,
            fixture.frame.height - 2 * fixture.gap,
            accuracy: 2
        )
    }

    func testATabPullDetachesTheTabAtOnceIntoANarrowHomeSpot() {
        var fixture = makeFixture()
        let tabbed = fixture.makeTabbed(2)
        let pulled = tabbed.windowNodes[1]
        let next = tabbed.windowNodes[2]
        let tabbedX = fixture.stripColumn(tabbed).minX
        XCTAssertTrue(fixture.beginPull(pulled))
        let cursor = CGPoint(x: fixture.stripColumn(tabbed).minX + 5, y: 450)

        XCTAssertTrue(fixture.engine.liveColumnMoveDetachTab(
            towardTrailingSide: false,
            cursor: cursor,
            context: fixture.context,
            state: &fixture.state
        ))

        XCTAssertEqual(tabbed.windowNodes.count, 2)
        XCTAssertTrue(tabbed.windowNodes[tabbed.activeTileIdx] === next)
        XCTAssertEqual(fixture.stripColumn(tabbed).minX, tabbedX, accuracy: 0.5)
        let home = fixture.engine.findColumn(containing: pulled, in: fixture.workspaceId)!
        XCTAssertEqual(fixture.engine.columnIndex(of: home, in: fixture.workspaceId), 2)
        XCTAssertEqual(
            fixture.stripColumn(home).maxX - fixture.stripColumn(home).minX,
            fixture.frame.width * 0.05,
            accuracy: 0.5
        )
        XCTAssertEqual(fixture.engine.liveColumnMove?.inStack, false)

        XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))
        XCTAssertEqual(tabbed.windowNodes.count, 3)
        XCTAssertTrue(tabbed.windowNodes[tabbed.activeTileIdx] === pulled)
    }

    func testReleasingTheModifierKeepsANarrowHomeSpotNarrow() {
        var fixture = makeFixture()
        fixture.stack(3, onto: 2)
        let stack = fixture.column(2)
        XCTAssertTrue(fixture.begin(3))
        XCTAssertEqual(fixture.move(to: CGPoint(x: fixture.stripColumn(stack).maxX + 20, y: 450)), .changed)
        let home = fixture.column(3)
        let narrow = fixture.stripColumn(home).maxX - fixture.stripColumn(home).minX

        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 4)), .changed)
        XCTAssertEqual(fixture.setStackMode(false, at: fixture.lowerHalf(of: 4)), .changed)

        XCTAssertTrue(fixture.window(3).parent === home)
        XCTAssertTrue(home.isLiveHomeSpot)
        XCTAssertEqual(fixture.stripColumn(home).maxX - fixture.stripColumn(home).minX, narrow, accuracy: 0.5)
    }

    func testAfterLeavingAStackTheWindowUnderThePointerDoesNotMoveTheGapUntilThePointerLeavesIt() {
        var fixture = makeFixture()
        fixture.stack(3, onto: 2)
        let stack = fixture.column(2)
        let neighbour = fixture.column(4)
        XCTAssertTrue(fixture.begin(3))
        let cursor = CGPoint(x: fixture.stripColumn(stack).maxX + 150, y: 450)

        XCTAssertEqual(fixture.move(to: cursor), .changed)
        let home = fixture.column(3)
        XCTAssertTrue(fixture.stripColumn(neighbour).contains(x: cursor.x))
        let expected = [[0], [1], [2], [3], [4]].map { $0.map { fixture.tokens[$0] } }

        XCTAssertEqual(fixture.move(to: cursor), .unchanged)
        XCTAssertEqual(fixture.move(to: CGPoint(x: cursor.x + 40, y: 300)), .unchanged)
        XCTAssertEqual(fixture.columnOrder(), expected)
        XCTAssertEqual(fixture.engine.columnIndex(of: home, in: fixture.workspaceId), 3)

        XCTAssertEqual(fixture.move(to: CGPoint(x: fixture.stripColumn(home).midX, y: 450)), .unchanged)
        XCTAssertEqual(fixture.move(to: cursor), .changed)
    }

    func testTheNearHalfOfANeighbourWithoutAGapOpensOne() {
        var fixture = makeFixture()
        let tabbed = fixture.makeTabbed(2)
        let pulled = tabbed.windowNodes[1]
        XCTAssertTrue(fixture.beginPull(pulled))
        XCTAssertTrue(fixture.engine.liveColumnMoveDetachTab(
            towardTrailingSide: true,
            cursor: CGPoint(x: fixture.stripColumn(tabbed).maxX - 20, y: 450),
            context: fixture.context,
            state: &fixture.state
        ))
        fixture.engine.liveColumnMoveSettled()
        let left = fixture.stripColumn(fixture.column(1))
        let facingTheTabbedColumn = CGPoint(x: left.maxX - (left.maxX - left.minX) / 4, y: 450)

        XCTAssertEqual(fixture.move(to: facingTheTabbedColumn), .changed)

        let columns = fixture.engine.columns(in: fixture.workspaceId)
        let homeIndex = columns.firstIndex { $0.windowNodes.contains { $0 === pulled } || $0.isLiveDropSpace }
        let leftIndex = columns.firstIndex { $0 === fixture.column(1) }
        XCTAssertEqual(homeIndex, leftIndex.map { $0 + 1 })
    }

    func testAfterPullingATabThePointerOverItsOldColumnDoesNotMoveTheGap() {
        var fixture = makeFixture()
        let tabbed = fixture.makeTabbed(2)
        let pulled = tabbed.windowNodes[1]
        XCTAssertTrue(fixture.beginPull(pulled))
        let cursor = CGPoint(x: fixture.stripColumn(tabbed).minX + 20, y: 450)
        XCTAssertTrue(fixture.engine.liveColumnMoveDetachTab(
            towardTrailingSide: true,
            cursor: cursor,
            context: fixture.context,
            state: &fixture.state
        ))
        fixture.engine.liveColumnMoveSettled()
        let home = fixture.engine.findColumn(containing: pulled, in: fixture.workspaceId)!
        XCTAssertEqual(fixture.engine.columnIndex(of: home, in: fixture.workspaceId), 3)

        XCTAssertEqual(fixture.move(to: cursor), .unchanged)
        XCTAssertEqual(fixture.move(to: CGPoint(x: cursor.x + 60, y: 300)), .unchanged)
        XCTAssertEqual(fixture.engine.columnIndex(of: home, in: fixture.workspaceId), 3)
        XCTAssertEqual(fixture.engine.columnIndex(of: tabbed, in: fixture.workspaceId), 2)
    }

    func testCancelRestoresTheActiveWindowOfAStackEvenWhenTheDraggedWindowEndsWhereItStarted() {
        var fixture = makeFixture()
        fixture.stack(3, onto: 2)
        fixture.stack(4, onto: 3)
        let stack = fixture.column(2)
        stack.setActiveTileIdx(2)
        XCTAssertTrue(fixture.begin(2))

        XCTAssertEqual(fixture.move(to: fixture.middle(of: 3)), .changed)
        XCTAssertEqual(fixture.move(to: fixture.middle(of: 3)), .changed)
        XCTAssertEqual(fixture.storage(stack), [2, 3, 4].map { fixture.tokens[$0] })
        XCTAssertNotEqual(stack.activeTileIdx, 2)

        XCTAssertTrue(fixture.engine.liveColumnMoveCancel(context: fixture.context, state: &fixture.state))

        XCTAssertEqual(fixture.storage(stack), [2, 3, 4].map { fixture.tokens[$0] })
        XCTAssertEqual(stack.activeTileIdx, 2)
    }

    func testTheStackProbeAnswersARepeatedEdgeScrollCheckAndClearsOnAnyChange() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.begin(1))
        XCTAssertEqual(fixture.setStackMode(true, at: fixture.lowerHalf(of: 2)), .changed)
        let elsewhere = fixture.lowerHalf(of: 3)

        XCTAssertTrue(fixture.engine.liveColumnMoveWouldChange(
            cursor: elsewhere, strip: fixture.strip(), context: fixture.context
        ))
        XCTAssertEqual(fixture.engine.liveStackProbe?.cursor, elsewhere)
        XCTAssertEqual(fixture.engine.liveStackProbe?.wouldChange, true)

        XCTAssertEqual(fixture.move(to: elsewhere), .changed)
        XCTAssertFalse(fixture.engine.liveColumnMoveWouldChange(
            cursor: elsewhere, strip: fixture.strip(), context: fixture.context
        ))
    }
}
